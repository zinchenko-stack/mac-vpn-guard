#!/bin/zsh
# Полный откат всего, что ставили мы: сторож, его записи в /etc/hosts, DNS-настройки
# /etc/resolver, список доменов, служба записи при загрузке, старое правило файрвола.
# Работает без интернета. Настройки самого Red Shield не трогает — см. README.txt.
# Запуск: sudo ~/vpn-test/uninstall.sh
[[ $EUID -eq 0 ]] || { echo "Запусти через sudo: sudo $0"; exit 1 }

MARK='# managed by chatgpt-vpn-guard'

# 1. Сторож
launchctl bootout system/local.chatgpt-vpn-guard 2>/dev/null
rm -f /Library/LaunchDaemons/local.chatgpt-vpn-guard.plist /usr/local/bin/chatgpt-vpn-guard

# 2. Служба записи при загрузке (если осталась после тестов)
launchctl bootout system/local.vpn-boot-capture 2>/dev/null
rm -f /Library/LaunchDaemons/local.vpn-boot-capture.plist /usr/local/bin/vpn-boot-capture \
      /usr/local/bin/vpn-leak-analyze.py /var/db/vpn-boot-capture.armed

# 3. Записи в /etc/hosts: блок OpenAI/Anthropic и адреса в обход DNS Red Shield
sed -i '' '/^# >>> chatgpt-vpn-guard$/,/^# <<< chatgpt-vpn-guard$/d' /etc/hosts
sed -i '' '/^# >>> vpn-direct-dns$/,/^# <<< vpn-direct-dns$/d' /etc/hosts

# 4. DNS через Яндекс для доменов из списка — только наши файлы, с меткой
for f in /etc/resolver/*(N); do
  grep -qF "$MARK" $f && rm -f $f
done
rm -f /usr/local/etc/vpn-direct-domains.txt

# 5. Старое правило файрвола из первых версий сторожа (только наш раздел)
pfctl -a com.apple/chatgpt-guard -F all 2>/dev/null
[[ -s /var/run/chatgpt-vpn-guard.pftoken ]] && pfctl -X $(cat /var/run/chatgpt-vpn-guard.pftoken) 2>/dev/null
rm -f /var/run/chatgpt-vpn-guard.pftoken

dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null

# Проверка: ничего нашего не осталось
left=()
[[ -e /Library/LaunchDaemons/local.chatgpt-vpn-guard.plist ]] && left+=("служба сторожа")
pgrep -qf /usr/local/bin/chatgpt-vpn-guard && left+=("процесс сторожа")
[[ -e /Library/LaunchDaemons/local.vpn-boot-capture.plist ]] && left+=("служба записи при загрузке")
grep -qE '^# >>> (chatgpt-vpn-guard|vpn-direct-dns)$' /etc/hosts && left+=("записи в /etc/hosts")
# (N) без файлов даёт пустой список, и grep ждал бы ввода с клавиатуры — поэтому /dev/null в конце
grep -lqF "$MARK" /etc/resolver/*(N) /dev/null 2>/dev/null && left+=("файлы в /etc/resolver")
[[ -e /usr/local/etc/vpn-direct-domains.txt ]] && left+=("список доменов")
if (( $#left )); then
  echo "НЕ ВСЁ УДАЛЕНО: ${(j:, :)left}"
  exit 1
fi
echo "Готово: сторож, записи в /etc/hosts, DNS-настройки и служебные файлы удалены."
echo "Блокировку без VPN делает Red Shield — её выключают в его настройках (см. README.txt)."
