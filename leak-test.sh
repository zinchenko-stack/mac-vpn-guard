#!/bin/zsh
# Тест утечек в момент переключения VPN на уровне пакетов.
# Непрерывно шлёт тестовый трафик за границу (IPv4 и IPv6) и записывает всё, что реально
# ушло через физические интерфейсы (en*). Правила файрвола не меняет.
# Запуск: sudo ~/vpn-test/leak-test.sh          — отключение VPN и смена сети (240 с)
#         sudo ~/vpn-test/leak-test.sh sleep    — сон и пробуждение Mac (180 с)
# Подсказки, что и когда делать, печатаются по ходу. Запускать в Terminal.app, не внутри Claude.
[[ $EUID -eq 0 ]] || { echo "Запусти через sudo: sudo $0 $*"; exit 1 }
zmodload zsh/datetime
# Сторож закрывает Claude при отключении VPN, а с ним и терминал внутри Claude.
# Игнорируем обрыв терминала, чтобы запись дошла до конца; лучше запускать в Terminal.app.
trap '' HUP

DIR=${0:A:h}
MODE=${1:-vpn}
[[ $MODE == sleep ]] && DURATION=180 || DURATION=240
OUT=/var/tmp/vpn-strict/leak-$(date +%Y%m%d-%H%M%S)
mkdir -p $OUT

# Тестовые адреса: за границей, у каждого своя роль. Ни один не входит в российский список.
V4_PING=1.1.1.1                      # Cloudflare DNS, ICMP
V4_CHATGPT=104.18.32.47              # chatgpt.com
V4_CLAUDE=160.79.104.10              # claude.ai / api.anthropic.com
V6_PING=2606:4700:4700::1111         # Cloudflare DNS по IPv6
print -l $V4_PING $V4_CHATGPT $V4_CLAUDE $V6_PING > $OUT/targets.txt

# Что разрешено мимо тоннеля: российские сети Red Shield и его серверы VPN.
pfctl -a com.redshieldvpn/bypass -t excluded_ru_v4 -T show 2>/dev/null | tr -d ' ' > $OUT/ru.txt
pfctl -a com.redshieldvpn/ks -s rules 2>/dev/null | grep -oE 'to [0-9.]+ ' | awk '{print $2}' | sort -u > $OUT/vpn-servers.txt
pfctl -a com.redshieldvpn/lockdown -s rules 2>/dev/null | grep -oE 'to [0-9.]+ ' | awk '{print $2}' | sort -u >> $OUT/vpn-servers.txt

pids=()
cleanup() { kill $pids 2>/dev/null; wait 2>/dev/null }
trap cleanup EXIT INT TERM

# Запись на всех проводных и беспроводных интерфейсах (неактивные просто не запишутся).
for i in $(ifconfig -l | tr ' ' '\n' | grep -E '^en[0-9]+$'); do
  tcpdump -i $i -n -U -w $OUT/$i.pcap 2>/dev/null &
  pids+=($!)
done

# Журнал состояния каждые 0.25 с: куда идёт маршрут, сколько правил блокировки, MAC интерфейсов.
{
  while true; do
    r=$(route -n get $V4_PING 2>/dev/null | awk '/interface:/{print $2}')
    ks=$(pfctl -a com.redshieldvpn/ks -s rules 2>/dev/null | wc -l | tr -d ' ')
    ld=$(pfctl -a com.redshieldvpn/lockdown -s rules 2>/dev/null | wc -l | tr -d ' ')
    print -r -- "$EPOCHREALTIME route=$r ks=$ks lockdown=$ld"
    sleep 0.25
  done
} > $OUT/state.log &
pids+=($!)
{
  # Без конвейера: иначе $! указывает на последний процесс, и цикл переживает остановку.
  while true; do
    for i in $(ifconfig -l | tr ' ' '\n' | grep -E '^en[0-9]+$'); do
      m=$(ifconfig $i | awk '/ether/{print $2}')
      [[ -n $m ]] && ! grep -qx $m $OUT/macs.txt 2>/dev/null && print -r -- $m >> $OUT/macs.txt
    done
    sleep 1
  done
} &
pids+=($!)

# Тестовый трафик: ICMP каждые 50 мс по IPv4 и IPv6, TCP-подключения к ChatGPT и Claude каждые ~100 мс.
ping -n -i 0.05 $V4_PING > $OUT/ping4.log 2>&1 &
pids+=($!)
ping6 -n -i 0.05 $V6_PING > $OUT/ping6.log 2>&1 &
pids+=($!)
{
  while true; do
    for ip in $V4_CHATGPT $V4_CLAUDE; do nc -z -G 1 -w 1 $ip 443 >/dev/null 2>&1 & done
    sleep 0.1
  done
} &
pids+=($!)

say() { print -r -- "$(date +%T) $*" >> $OUT/steps.log; print -r -- "$(date +%T) $*" 2>/dev/null }
at() { while (( SECONDS < $1 )); do sleep 0.5; done }

SECONDS=0
say "Запись идёт $DURATION с. Пока ничего не трогай."
if [[ $MODE == sleep ]]; then
  # Отсчёт идёт по настенным часам: после пробуждения подсказки догонят время сна.
  at 20;  say ">>> УСЫПИ Mac: меню Apple → Режим сна. Через 30–60 секунд РАЗБУДИ и войди"
  at 40;  say ">>> Проснулся. Ничего не трогай, запись идёт дальше"
else
  at 20;  say ">>> ОТКЛЮЧИ VPN в Red Shield"
  at 60;  say ">>> ВКЛЮЧИ VPN"
  at 110; say ">>> ВЫКЛЮЧИ Wi-Fi (значок в меню), через 10 секунд ВКЛЮЧИ обратно"
  at 170; say ">>> Если VPN не переподключился сам — включи его. Дальше ничего не трогай"
fi
at $DURATION
say "Запись закончена, разбираю…"
cleanup
trap - EXIT

python3 -I $DIR/leak-analyze.py $OUT > $OUT/report.txt
chmod -R a+rX $OUT
cat $OUT/report.txt 2>/dev/null
echo "Готово. Отчёт: $OUT/report.txt" 2>/dev/null
