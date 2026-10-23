#!/bin/zsh
# Страховка для теста блокировок Red Shield. Трогает только разделы ks, lockdown и
# ipv6_guard в com.redshieldvpn (в исходном снимке все три пустые); остальной файрвол
# (Red Shield bypass, системные правила Apple) не меняет.
#   sudo ./ks-test.sh rollback      — сразу очистить эти разделы (вернуть исходное состояние)
#   sudo ./ks-test.sh arm <секунд>  — взвести автоматический откат через N секунд
#   sudo ./ks-test.sh disarm        — снять взведённый откат
#   sudo ./ks-test.sh status        — что сейчас в разделах и взведён ли откат
#   sudo ./ks-test.sh verify        — сравнить правила с исходным снимком
[[ $EUID -eq 0 ]] || { echo "Запусти через sudo: sudo $0 $*"; exit 1 }

ANCHORS=(com.redshieldvpn/ks com.redshieldvpn/lockdown com.redshieldvpn/ipv6_guard)
PIDFILE=/var/run/ks-test.watchdog.pid
LOG=/var/tmp/vpn-strict/ks-test.log
ORIGINAL=/var/tmp/vpn-strict/backup-original
SELF=${0:A}

log() { print -r -- "$(date '+%F %T') $*" | tee -a $LOG }

rules() { pfctl -a $1 -s rules 2>/dev/null }

case $1 in
  rollback)
    for a in $ANCHORS; do
      pfctl -a $a -F rules 2>/dev/null
      log "откат: раздел $a очищен, правил осталось: $(rules $a | wc -l | tr -d ' ')"
    done
    ;;
  arm)
    secs=${2:-300}
    $SELF disarm >/dev/null 2>&1
    nohup zsh -c "sleep $secs; ${(q)SELF} rollback; rm -f $PIDFILE" >/dev/null 2>&1 &
    print $! > $PIDFILE
    log "автооткат взведён: через $secs с ($(date -v+${secs}S '+%T'))"
    ;;
  disarm)
    # Убиваем zsh-обёртку: оставшийся sleep доспит впустую, откат уже не запустится.
    if [[ -s $PIDFILE ]] && kill $(cat $PIDFILE) 2>/dev/null; then
      log "автооткат снят"
    else
      log "автооткат не был взведён"
    fi
    rm -f $PIDFILE
    ;;
  status)
    for a in $ANCHORS; do echo "правил в $a: $(rules $a | wc -l | tr -d ' ')"; done
    [[ -s $PIDFILE ]] && kill -0 $(cat $PIDFILE) 2>/dev/null \
      && echo "автооткат взведён (pid $(cat $PIDFILE))" || echo "автооткат не взведён"
    ;;
  verify)
    ok=1
    for a in "" com.apple com.redshieldvpn com.redshieldvpn/bypass com.redshieldvpn/ipv6_guard \
             com.redshieldvpn/ks com.redshieldvpn/lockdown; do
      f=$ORIGINAL/${a:+anchor-${a//\//__}.rules.txt}
      [[ -z $a ]] && f=$ORIGINAL/main-rules.txt
      if ! diff <(grep -v ALTQ $f) <(if [[ -z $a ]]; then pfctl -s rules 2>/dev/null; else rules $a; fi) >/dev/null; then
        echo "ОТЛИЧАЕТСЯ: ${a:-основной набор}"; ok=0
      fi
    done
    n=$(pfctl -a com.redshieldvpn/bypass -t excluded_ru_v4 -T show 2>/dev/null | wc -l | tr -d ' ')
    echo "российских сетей в bypass: $n (было 8630)"
    (( ok )) && echo "правила совпадают с исходным снимком" || exit 1
    ;;
  *) sed -n '2,9p' $SELF; exit 1 ;;
esac
