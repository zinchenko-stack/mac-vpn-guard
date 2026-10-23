#!/bin/zsh
# Установка сторожа ChatGPT как системной службы. Запуск: sudo ./install.sh
set -e
[[ $EUID -eq 0 ]] || { echo "Запусти через sudo: sudo ./install.sh"; exit 1 }

DIR=${0:A:h}
LABEL=local.chatgpt-vpn-guard
BIN=/usr/local/bin/chatgpt-vpn-guard
PLIST=/Library/LaunchDaemons/$LABEL.plist

mkdir -p /usr/local/bin
install -m 755 -o root -g wheel $DIR/chatgpt-vpn-guard.sh $BIN

# Список доменов в обход DNS Red Shield — создаём один раз, дальше правится вручную.
LIST=/usr/local/etc/vpn-direct-domains.txt
if [[ ! -e $LIST ]]; then
  mkdir -p /usr/local/etc
  cat > $LIST <<'EOF'
# Домены, которые DNS Red Shield не находит. По одному в строке.
# Сторож сам найдёт их адреса через Яндекс-DNS и пропишет в /etc/hosts.
# Пример (поддомены подхватятся сами):
# example.ru
EOF
  chmod 644 $LIST
fi

cat > $PLIST <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/chatgpt-vpn-guard.log</string>
  <key>StandardErrorPath</key><string>/var/log/chatgpt-vpn-guard.log</string>
</dict>
</plist>
EOF
chown root:wheel $PLIST
chmod 644 $PLIST

launchctl bootout system/$LABEL 2>/dev/null || true

# Прежние версии загружали правило ядра в com.apple/chatgpt-guard — ядро его не проверяло
# (основной набор правил принадлежит Red Shield). Убираем его; правила Red Shield не трогаем.
pfctl -a com.apple/chatgpt-guard -F all 2>/dev/null || true
[[ -s /var/run/chatgpt-vpn-guard.pftoken ]] && pfctl -X $(cat /var/run/chatgpt-vpn-guard.pftoken) 2>/dev/null || true
rm -f /var/run/chatgpt-vpn-guard.pftoken

launchctl bootstrap system $PLIST
echo "Сторож установлен и запущен. Лог: /var/log/chatgpt-vpn-guard.log"
