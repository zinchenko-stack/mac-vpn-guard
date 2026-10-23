#!/bin/zsh
# Тест kill switch Red Shield при ручном отключении VPN.
# Взводит автооткат, затем 4 минуты записывает, что доступно напрямую, а что нет.
# Запуск: sudo ./ks-probe.sh
[[ $EUID -eq 0 ]] || { echo "Запусти через sudo: sudo ./ks-probe.sh"; exit 1 }

DIR=${0:A:h}
LOG=/var/tmp/vpn-strict/probe.log
DURATION=240
ROLLBACK_AFTER=300

ks_count() { pfctl -a com.redshieldvpn/ks -s rules 2>/dev/null | wc -l | tr -d ' ' }
ld_count() { pfctl -a com.redshieldvpn/lockdown -s rules 2>/dev/null | wc -l | tr -d ' ' }

# Ждём до 2 минут, пока Red Shield заполнит ks (после переключения kill switch).
wait_end=$((SECONDS + 120))
while (( $(ks_count) == 0 )); do
  (( SECONDS < wait_end )) || { echo "Раздел ks так и не заполнился — тест не запущен, ничего не менялось"; exit 1 }
  echo "Раздел ks пуст: выключи и включи kill switch в Red Shield (жду...)"
  sleep 5
done
echo "kill switch активен: правил в ks: $(ks_count)"

$DIR/ks-test.sh arm $ROLLBACK_AFTER || exit 1

# 0 — соединение установлено, иначе — не прошло (за 2 с)
tcp() { nc -z -G 2 -w 2 $1 443 >/dev/null 2>&1 && echo ok || echo BLOCK }

: > $LOG
chmod a+r $LOG
echo "Запись $DURATION с. Через ~20 с отключи VPN в Red Shield, подожди минуту, открой ChatGPT, затем включи VPN."
end=$((SECONDS + DURATION))
while (( SECONDS < end )); do
  line="$(date +%T)"
  line+=" ks=$(ks_count) lockdown=$(ld_count)"
  line+=" route=$(route -n get 104.18.32.47 2>/dev/null | awk '/interface/{print $2}')"
  line+=" ru_ya=$(tcp 77.88.44.242)"            # ya.ru — российская сеть, должна работать всегда
  line+=" ru_gosuslugi=$(tcp 213.59.253.7)"     # Госуслуги
  line+=" chatgpt=$(tcp 104.18.32.47)"          # chatgpt.com (Cloudflare)
  line+=" foreign=$(tcp 140.82.112.3)"          # github.com — любой зарубежный адрес
  line+=" google_push=$(tcp 209.85.233.188)"    # уведомления, к которым ходит ChatGPT
  # IPv6 через тоннель Red Shield не ходит, поэтому с VPN тут BLOCK; важно, чтобы без VPN не стало ok
  line+=" ipv6=$(nc -6 -z -G 2 -w 2 2606:4700:4700::1111 443 >/dev/null 2>&1 && echo ok || echo BLOCK)"
  line+=" chatgpt_app=$(pgrep -qf '^/Applications/ChatGPT.app/Contents/MacOS/ChatGPT' && echo open || echo closed)"
  print -r -- "$line" | tee -a $LOG
  sleep 2
done

# VPN вернулся и через тоннель всё работает — снимаем автооткат, иначе пусть сработает.
if [[ $(route -n get 104.18.32.47 | awk '/interface/{print $2}') == utun* ]] \
   && nc -z -G 3 -w 3 104.18.32.47 443 >/dev/null 2>&1; then
  $DIR/ks-test.sh disarm
else
  echo "VPN не восстановлен — автооткат остаётся взведённым"
fi
echo "Готово. Лог: $LOG"
