#!/bin/zsh
# Запись сети при загрузке Mac: служба стартует при включении, 5 минут пишет все пакеты
# на физических интерфейсах и состояние файрвола, потом сама разбирает запись.
# Срабатывает ОДИН раз — на ближайшей загрузке после arm; правила файрвола не меняет.
#   sudo ~/vpn-test/boot-capture.sh arm      — установить службу и взвести на следующую загрузку
#   sudo ~/vpn-test/boot-capture.sh disarm   — удалить службу и всё, что она поставила
#   sudo ~/vpn-test/boot-capture.sh status   — взведена ли и где последний отчёт
#   (run вызывает сама служба при загрузке)
[[ $EUID -eq 0 ]] || { echo "Запусти через sudo: sudo $0 $*"; exit 1 }
zmodload zsh/datetime

LABEL=local.vpn-boot-capture
BIN=/usr/local/bin/vpn-boot-capture
ANALYZE=/usr/local/bin/vpn-leak-analyze.py
PLIST=/Library/LaunchDaemons/$LABEL.plist
FLAG=/var/db/vpn-boot-capture.armed
DURATION=${BOOT_CAPTURE_SECONDS:-300}   # короче — только для пробного запуска

case $1 in
  arm)
    DIR=${0:A:h}
    mkdir -p /usr/local/bin
    install -m 755 -o root -g wheel ${0:A} $BIN
    install -m 644 -o root -g wheel $DIR/leak-analyze.py $ANALYZE
    cat > $PLIST <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
    chown root:wheel $PLIST
    chmod 644 $PLIST
    touch $FLAG
    # Службу не запускаем сейчас: macOS сама загрузит её при следующем включении.
    echo "Взведено. Перезагрузи Mac; запись пойдёт сама, отчёт будет через ~5 минут после старта."
    ;;
  disarm)
    launchctl bootout system/$LABEL 2>/dev/null
    rm -f $PLIST $BIN $ANALYZE $FLAG
    echo "Служба записи при загрузке удалена. Записи остались в /var/tmp/vpn-strict/boot-*"
    ;;
  status)
    [[ -e $FLAG ]] && echo "Взведено на следующую загрузку" || echo "Не взведено"
    [[ -e $PLIST ]] && echo "Служба установлена: $PLIST"
    last=(/var/tmp/vpn-strict/boot-*(N/om[1]))
    if (( $#last )); then
      echo "Последняя запись: $last"
      tail -3 $last/report.txt 2>/dev/null
    fi
    ;;
  run)
    [[ -e $FLAG ]] || exit 0
    rm -f $FLAG                          # один раз
    OUT=/var/tmp/vpn-strict/boot-$(date +%Y%m%d-%H%M%S)
    mkdir -p $OUT
    sysctl -n kern.boottime > $OUT/boottime.txt
    print -r -- "$EPOCHREALTIME служба записи стартовала" > $OUT/steps.log
    print -l 1.1.1.1 104.18.32.47 160.79.104.10 2606:4700:4700::1111 > $OUT/targets.txt

    pids=()
    # tcpdump на каждом en* — по мере появления интерфейсов.
    {
      started=()
      while true; do
        for i in $(ifconfig -l | tr ' ' '\n' | grep -E '^en[0-9]+$'); do
          (( ${started[(Ie)$i]} )) && continue
          tcpdump -i $i -n -U -w $OUT/$i.pcap 2>>$OUT/tcpdump.err &
          started+=($i)
          print -r -- "$EPOCHREALTIME запись $i" >> $OUT/steps.log
        done
        sleep 0.5
      done
    } &
    pids+=($!)
    # Состояние каждые 0.25 с: включён ли pf, подключён ли набор Red Shield, правила блокировки,
    # маршрут, адрес Wi-Fi, работает ли служба Red Shield.
    {
      while true; do
        pf=$(pfctl -s info 2>/dev/null | awk '/^Status:/{print $2}')
        main=$(pfctl -s rules 2>/dev/null | grep -c 'com.redshieldvpn')
        ks=$(pfctl -a com.redshieldvpn/ks -s rules 2>/dev/null | wc -l | tr -d ' ')
        ld=$(pfctl -a com.redshieldvpn/lockdown -s rules 2>/dev/null | wc -l | tr -d ' ')
        r=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
        ip=$(ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}')
        rs=$(pgrep -x rsvd >/dev/null && echo up || echo down)
        print -r -- "$EPOCHREALTIME pf=${pf:-?} rs-main=$main ks=$ks lockdown=$ld route=${r:-none} en0=${ip:-none} rsvd=$rs"
        sleep 0.25
      done
    } > $OUT/state.log &
    pids+=($!)
    {
      while true; do
        for i in $(ifconfig -l | tr ' ' '\n' | grep -E '^en[0-9]+$'); do
          m=$(ifconfig $i | awk '/ether/{print $2}')
          [[ -n $m ]] && ! grep -qx $m $OUT/macs.txt 2>/dev/null && print -r -- $m >> $OUT/macs.txt
        done
        sleep 1
      done
    } &
    pids+=($!)
    # Тестовый трафик за границу с самого старта: если есть окно без защиты, он туда попадёт.
    { while true; do ping -n -i 0.1 1.1.1.1; sleep 1; done } > $OUT/ping4.log 2>&1 &
    pids+=($!)
    { while true; do ping6 -n -i 0.1 2606:4700:4700::1111; sleep 1; done } > $OUT/ping6.log 2>&1 &
    pids+=($!)

    sleep $DURATION
    kill $pids 2>/dev/null
    pkill -f "^tcpdump -i en[0-9]+ -n -U -w $OUT/" 2>/dev/null
    pkill -f '^ping6? -n -i 0.1 ' 2>/dev/null
    sleep 1

    # Разрешённое мимо тоннеля берём в конце, когда Red Shield уже загрузил свои списки.
    pfctl -a com.redshieldvpn/bypass -t excluded_ru_v4 -T show 2>/dev/null | tr -d ' ' > $OUT/ru.txt
    pfctl -a com.redshieldvpn/ks -s rules 2>/dev/null | grep -oE 'to [0-9.]+ ' | awk '{print $2}' | sort -u > $OUT/vpn-servers.txt
    pfctl -a com.redshieldvpn/lockdown -s rules 2>/dev/null | grep -oE 'to [0-9.]+ ' | awk '{print $2}' | sort -u >> $OUT/vpn-servers.txt
    python3 -I $ANALYZE $OUT > $OUT/report.txt 2>&1
    chmod -R a+rX $OUT
    ;;
  *) sed -n '2,8p' ${0:A}; exit 1 ;;
esac
