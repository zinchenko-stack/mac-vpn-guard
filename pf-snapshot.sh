#!/bin/zsh
# Снимок состояния файрвола pf и сетевых настроек. Только чтение, ничего не меняет.
# Запуск: sudo ./pf-snapshot.sh [папка]   (по умолчанию /var/tmp/vpn-strict/backup-<время>)
[[ $EUID -eq 0 ]] || { echo "Запусти через sudo: sudo ./pf-snapshot.sh"; exit 1 }

OUT=${1:-/var/tmp/vpn-strict/backup-$(date +%Y%m%d-%H%M%S)}
mkdir -p $OUT

pfctl -s info            > $OUT/info.txt 2>&1
pfctl -s rules           > $OUT/main-rules.txt 2>&1
pfctl -s nat             > $OUT/main-nat.txt 2>&1
pfctl -s Tables          > $OUT/main-tables.txt 2>&1
pfctl -s Anchors -v      > $OUT/anchors.txt 2>/dev/null
pfctl -s states 2>/dev/null | wc -l > $OUT/states-count.txt

# Правила, трансляции и таблицы каждого анкера.
while read -r a; do
  [[ -z $a ]] && continue
  f=$OUT/anchor-${a//\//__}
  pfctl -a $a -s rules  > $f.rules.txt 2>&1
  pfctl -a $a -s nat    > $f.nat.txt 2>&1
  pfctl -a $a -s Tables > $f.tables.txt 2>&1
  for t in $(pfctl -a $a -s Tables 2>/dev/null); do
    pfctl -a $a -t $t -T show 2>/dev/null | wc -l | xargs echo "$t:" >> $f.tables-count.txt
  done
done < <(sed 's/^ *//' $OUT/anchors.txt)

cp /etc/pf.conf $OUT/pf.conf
cp /etc/hosts $OUT/hosts
netstat -rn > $OUT/routes.txt
ifconfig > $OUT/ifconfig.txt

chmod -R a+rX $OUT
echo $OUT
