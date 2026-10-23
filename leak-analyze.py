#!/usr/bin/env python3
"""Разбор записи leak-test.sh: какие пакеты ушли через физический интерфейс мимо тоннеля.

Исходящий пакет = отправлен с MAC-адреса этого Mac. Разрешённым считаем: локальную сеть,
служебные адреса (multicast, link-local), серверы VPN и российские сети Red Shield.
Всё остальное — утечка; отдельно помечаем тестовые адреса.
Запуск: python3 leak-analyze.py <папка записи>
"""
import ipaddress
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

out = Path(sys.argv[1])


def read_lines(name):
    p = out / name
    return [l.strip() for l in p.read_text().splitlines() if l.strip()] if p.exists() else []


macs = set(read_lines("macs.txt"))
targets = set(read_lines("targets.txt"))
vpn_servers = {ipaddress.ip_address(a) for a in read_lines("vpn-servers.txt")}
ru_nets = []
for line in read_lines("ru.txt"):
    try:
        ru_nets.append(ipaddress.ip_network(line, strict=False))
    except ValueError:
        pass
ru_nets.sort(key=lambda n: int(n.network_address))
ru_starts = [int(n.network_address) for n in ru_nets]

LOCAL = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4",
    "255.255.255.255/32", "0.0.0.0/8", "100.64.0.0/10",
    "fe80::/10", "ff00::/8", "fc00::/7", "::/128",
)]


def in_ru(ip):
    if ip.version != 4 or not ru_nets:
        return False
    from bisect import bisect_right
    i = bisect_right(ru_starts, int(ip)) - 1
    return i >= 0 and ip in ru_nets[i]


# Внутренние адреса Red Shield (его DNS): должны ходить только по тоннелю. На физическом
# интерфейсе это открытые DNS-запросы мимо VPN — не «локальная сеть».
VPN_INTERNAL = ipaddress.ip_network("10.254.254.0/24")


def allowed(ip):
    if ip in VPN_INTERNAL:
        return None
    if any(ip in n for n in LOCAL):
        return "local"
    if ip in vpn_servers:
        return "vpn-server"
    if in_ru(ip):
        return "ru-direct"
    return None


def strip_port(tok, v6):
    tok = tok.rstrip(":,")
    if v6:
        return tok.rsplit(".", 1)[0] if "." in tok else tok
    parts = tok.split(".")
    return ".".join(parts[:4])


LINE = re.compile(
    r"^(\S+ \S+) (\S+) > (\S+), ethertype (IPv4|IPv6) \(0x[0-9a-f]+\), length \d+: (\S+) > (\S+?)[:,]? ")

# Состояние VPN по времени, чтобы утечку можно было соотнести с переключением.
states = []
for l in read_lines("state.log"):
    t, *kv = l.split()
    states.append((float(t), " ".join(kv)))


def state_at(ts):
    s = None
    for t, kv in states:
        if t > ts:
            break
        s = kv
    return s or "?"


leaks = defaultdict(list)
counts = defaultdict(int)
total = 0
for pcap in sorted(out.glob("en*.pcap")):
    if pcap.stat().st_size <= 24:
        continue
    txt = subprocess.run(["tcpdump", "-r", str(pcap), "-n", "-e", "-tttt"],
                         capture_output=True, text=True).stdout
    for line in txt.splitlines():
        m = LINE.match(line)
        if not m:
            continue
        when, smac, _dmac, fam, src, dst = m.groups()
        if smac not in macs:
            continue                      # входящий пакет
        total += 1
        v6 = fam == "IPv6"
        try:
            ip = ipaddress.ip_address(strip_port(dst, v6))
        except ValueError:
            continue
        kind = allowed(ip)
        counts[kind or "LEAK"] += 1
        if not kind:
            leaks[(pcap.stem, fam, str(ip))].append(when)

print(f"Запись: {out}")
print(f"Исходящих пакетов на физических интерфейсах: {total}")
for k in ("local", "vpn-server", "ru-direct", "LEAK"):
    print(f"  {k:11} {counts.get(k, 0)}")
print(f"Российских сетей в списке: {len(ru_nets)}, серверов VPN: {len(vpn_servers)}")

if not leaks:
    print("\nУТЕЧЕК НЕ НАЙДЕНО: ни один пакет за границу не ушёл мимо тоннеля.")
    sys.exit(0)

print("\nУТЕЧКИ (пакеты за границу мимо тоннеля):")
for (iface, fam, ip), times in sorted(leaks.items(), key=lambda kv: kv[1][0]):
    mark = "  <-- ТЕСТОВЫЙ АДРЕС" if ip in targets else ""
    first, last = times[0], times[-1]
    try:
        ts = datetime.strptime(first, "%Y-%m-%d %H:%M:%S.%f").timestamp()
        st = state_at(ts)
    except ValueError:
        st = "?"
    print(f"  {iface} {fam} {ip}: {len(times)} пак., {first} … {last}  [{st}]{mark}")
sys.exit(2)
