#!/bin/zsh
# Сторож ChatGPT и Claude: приложения работают, только когда их трафик идёт через тоннель Red Shield.
# Без VPN — адреса OpenAI и Anthropic заблокированы в /etc/hosts, а приложения закрываются.
# Это запасной слой: сетевую блокировку без VPN делает сам Red Shield («Интернет только через VPN»).

# IP-адреса chatgpt.com, api.openai.com (Cloudflare) и claude.ai/api.anthropic.com.
# Если маршрут ко всем идёт через utun*, значит Red Shield поднят и они не попали в список «напрямую».
PROBES=(104.18.32.47 172.64.155.209 162.159.140.245 160.79.104.10)

DOMAINS=(
  chatgpt.com www.chatgpt.com ab.chatgpt.com chat.chatgpt.com
  chatgpt.site chatgpt-team.site
  openai.com www.openai.com chat.openai.com api.openai.com auth.openai.com
  auth0.openai.com ios.chat.openai.com android.chat.openai.com platform.openai.com
  cdn.openai.com help.openai.com
  oaistatic.com cdn.oaistatic.com persistent.oaistatic.com
  oaiusercontent.com files.oaiusercontent.com sdmntprwestus.oaiusercontent.com
  chatgpt.livekit.cloud featuregates.org events.statsigapi.net
  claude.ai www.claude.ai claude.com www.claude.com code.claude.com
  anthropic.com www.anthropic.com api.anthropic.com console.anthropic.com
  statsig.anthropic.com mcp-proxy.anthropic.com
)

# Приложения, которые закрываем без VPN: «название|регулярка пути процесса».
# Claude Code в приложении Claude живёт в ~/Library/Application Support/Claude/claude-code.
APPS=(
  "ChatGPT|^/Applications/ChatGPT\.app/"
  "Claude|^/Applications/Claude\.app/"
  "Claude Code|^/Users/[^/]+/Library/Application Support/Claude/claude-code/"
)

HOSTS=/etc/hosts
BEGIN_MARK="# >>> chatgpt-vpn-guard"
END_MARK="# <<< chatgpt-vpn-guard"

# Домены, которые DNS Red Shield не находит (по одному в строке, # — комментарий).
# Для каждого кладём /etc/resolver/<домен>: macOS спрашивает про него и все его
# поддомены Яндекс-DNS. Дополнительно сам домен держим в /etc/hosts — на случай
# программ, которые /etc/resolver не читают; обновляем раз в 10 минут и в течение
# 10 секунд после правки списка. Если Яндекс не ответил — оставляем старый адрес.
DIRECT_LIST=/usr/local/etc/vpn-direct-domains.txt
DIRECT_DNS=77.88.8.8
RESOLVER_DIR=/etc/resolver
RESOLVER_MARK="# managed by chatgpt-vpn-guard"
DIRECT_BEGIN="# >>> vpn-direct-dns"
DIRECT_END="# <<< vpn-direct-dns"
DIRECT_EVERY=600           # секунд между обновлениями адресов
LIST_CHECK=10              # секунд: как часто с VPN проверять правила Red Shield и список доменов

log() { print -r -- "$(date '+%F %T') $*" }

vpn_up() {
  local ip iface
  for ip in $PROBES; do
    iface=$(route -n get $ip 2>/dev/null | awk '/interface:/{print $2}')
    [[ $iface == utun* ]] || return 1
  done
  return 0
}

is_blocked() { grep -qF "$BEGIN_MARK" $HOSTS }

flush_dns() {
  dscacheutil -flushcache
  killall -HUP mDNSResponder 2>/dev/null
}

block() {
  is_blocked && return
  {
    print -r -- "$BEGIN_MARK"
    for d in $DOMAINS; do
      print -r -- "0.0.0.0 $d"
      print -r -- ":: $d"
    done
    print -r -- "$END_MARK"
  } >> $HOSTS
  flush_dns
  log "VPN выключен — OpenAI и Anthropic заблокированы"
}

unblock() {
  is_blocked || return
  sed -i '' "/^$BEGIN_MARK\$/,/^$END_MARK\$/d" $HOSTS
  flush_dns
  log "VPN включён — блок снят"
}

notify() {
  local user uid
  user=$(stat -f %Su /dev/console)
  [[ -z $user || $user == root ]] && return
  uid=$(id -u $user)
  launchctl asuser $uid sudo -u $user osascript \
    -e "display notification \"Включи Red Shield VPN и открой снова\" with title \"$1 закрыт\" sound name \"Basso\"" &
}

kill_apps() {
  local entry name re
  for entry in $APPS; do
    name=${entry%%|*} re=${entry#*|}
    pgrep -f "$re" >/dev/null || continue
    pkill -9 -f "$re"
    log "$name закрыт: VPN выключен"
    notify $name
  done
}

direct_domains() {
  [[ -r $DIRECT_LIST ]] && sed 's/#.*//; s/[[:space:]]//g; /^$/d' $DIRECT_LIST
}

# Файлы /etc/resolver для доменов из списка; чужие файлы (без нашей метки) не трогаем.
resolver_sync() {
  local d f want changed=0 domains=(${(f)"$(direct_domains)"})
  want="$RESOLVER_MARK"$'\n'"nameserver $DIRECT_DNS"$'\n'"nameserver 77.88.8.1"
  mkdir -p $RESOLVER_DIR
  for d in $domains; do
    f=$RESOLVER_DIR/$d
    [[ -e $f ]] && ! grep -qF "$RESOLVER_MARK" $f && continue
    [[ "$(cat $f 2>/dev/null)" == $want ]] && continue
    print -r -- $want > $f
    chmod 644 $f
    changed=1
  done
  for f in $RESOLVER_DIR/*(N); do
    grep -qF "$RESOLVER_MARK" $f || continue
    (( ${domains[(Ie)${f:t}]} )) && continue
    rm -f $f
    changed=1
  done
  (( changed )) && { flush_dns; log "DNS в обход Red Shield: ${domains[*]:-нет} (с поддоменами)" }
}

direct_refresh() {
  resolver_sync
  [[ -r $DIRECT_LIST ]] || return
  local d ip old lines=()
  for d in ${(f)"$(direct_domains)"}; do
    [[ -z $d ]] && continue
    ip=$(dig +short +time=3 +tries=1 A $d @$DIRECT_DNS 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)
    if [[ -z $ip ]]; then
      # Яндекс не ответил — берём прежний адрес из hosts, если он был.
      old=$(sed -n "/^$DIRECT_BEGIN\$/,/^$DIRECT_END\$/p" $HOSTS | awk -v d=$d '$2==d{print $1; exit}')
      [[ -n $old ]] && ip=$old || { log "не удалось найти адрес $d"; continue }
    fi
    lines+=("$ip $d")
  done
  local block=""
  (( $#lines )) && block=$(print -l -- $DIRECT_BEGIN $lines $DIRECT_END)
  local current=$(sed -n "/^$DIRECT_BEGIN\$/,/^$DIRECT_END\$/p" $HOSTS)
  [[ $block == $current ]] && return
  sed -i '' "/^$DIRECT_BEGIN\$/,/^$DIRECT_END\$/d" $HOSTS
  [[ -n $block ]] && print -r -- $block >> $HOSTS
  flush_dns
  log "адреса в обход DNS Red Shield обновлены: ${lines[*]:-нет}"
}

list_mtime() { stat -f %m $DIRECT_LIST 2>/dev/null || echo 0 }

# Основная защита — правила Red Shield в файрволе ядра. Проверяем, что она на месте:
# pf включён, набор Red Shield подключён к основному, Kill Switch блокирует всё мимо тоннеля,
# а «Интернет только через VPN» поставил свой раздел lockdown. Результат держим 3 с,
# чтобы частые проверки без VPN не гоняли pfctl.
RS_ANCHOR=com.redshieldvpn
prot_at=0 prot_why=""
# Пишет причину в prot_why (пусто — всё в порядке). Без $(…): кэш должен жить в этом процессе.
protection_check() {
  (( EPOCHREALTIME - prot_at < 3 )) && return
  prot_at=$EPOCHREALTIME
  if ! pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
    prot_why="файрвол pf выключен"
  elif ! pfctl -s rules 2>/dev/null | grep -q "anchor \"$RS_ANCHOR\""; then
    prot_why="правила Red Shield не подключены к файрволу"
  elif ! pfctl -a $RS_ANCHOR/ks -s rules 2>/dev/null | grep -q '^block drop all'; then
    prot_why="Kill Switch Red Shield не блокирует трафик"
  elif [[ -z $(pfctl -a $RS_ANCHOR/lockdown -s rules 2>/dev/null) ]]; then
    prot_why="режим «Интернет только через VPN» выключен"
  else
    prot_why=""
  fi
}

notify_protection() {
  local user uid
  user=$(stat -f %Su /dev/console)
  [[ -z $user || $user == root ]] && return
  uid=$(id -u $user)
  launchctl asuser $uid sudo -u $user osascript \
    -e "display notification \"$1. ChatGPT и Claude закрыты, пока защита не вернётся\" with title \"Защита Red Shield не активна\" sound name \"Basso\"" &
}

last_problem=""
apply() {
  local problem=""
  if vpn_up; then
    protection_check
    problem=$prot_why
    if [[ -z $problem ]]; then
      [[ -n $last_problem ]] && log "защита Red Shield снова активна"
      last_problem=""
      unblock
      return
    fi
    if [[ $problem != $last_problem ]]; then
      log "VPN включён, но $problem — блокирую ChatGPT и Claude"
      notify_protection $problem
    fi
  fi
  last_problem=$problem
  block
  kill_apps
}

# На выходе (остановка или удаление сторожа) блок оставляем: без сторожа безопаснее с ним.
zmodload zsh/datetime

# Поток событий об изменении маршрутов: macOS шлёт его сам, ожидание не тратит процессор.
# RTM_GET — это ответы на наши же «route get» (и чужие запросы), их отбрасываем,
# иначе каждая проверка будила бы сторожа снова.
start_monitor() {
  coproc { route -n monitor 2>/dev/null | grep --line-buffered -E '^RTM_(ADD|DELETE|CHANGE|NEWADDR|DELADDR|IFINFO)' }
  MON_PID=$!
}

log "сторож запущен"
direct_refresh
list_seen=$(list_mtime)
next_refresh=$((EPOCHSECONDS + DIRECT_EVERY))
start_monitor
while true; do
  apply
  m=$(list_mtime)
  if [[ $m != $list_seen ]] || (( EPOCHSECONDS >= next_refresh )); then
    list_seen=$m
    next_refresh=$((EPOCHSECONDS + DIRECT_EVERY))
    direct_refresh
  fi
  # С VPN спим до события маршрутов (обрыв VPN будит сразу) или до проверки списка доменов.
  # Без VPN проверяем каждые 0.3 с, чтобы быстро закрыть запущенный ChatGPT или Claude.
  is_blocked && wait_for=0.3 || wait_for=$LIST_CHECK
  if read -t $wait_for -p _; then
    while read -t 0 -p _; do :; done     # пачку событий обрабатываем за один раз
  elif ! kill -0 $MON_PID 2>/dev/null; then
    log "поток событий маршрутов прервался — перезапускаю"
    start_monitor
    sleep 1
  fi
done
