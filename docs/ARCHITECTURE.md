# HackerOS Kernel - Red Team Edition - Architektura

## Przeglad

HackerOS Kernel Red Team Edition to zmodyfikowane jadro Linux 7.1+ dostosowane
do dystrybucji HackerOS skierowanej pod cybersecurity red team engagement.
Jadro jest czesc immutable OS stack opartego na OSTree/debian-ostree.

## Patchset (35 patchy)

### Warstwa 1: Cybersecurity foundation (0001-0016)
Podstawowe hardening i forensics (oryginalny patchset cybersecurity edition).

### Warstwa 2: Red Team extensions (0017-0030)
Ofensywne mozliwosci dla autoryzowanych penetration testerow:

| Patch | Opis |
|-------|------|
| 0017 | CONFIG_HACKEROS_REDTEAM branding |
| 0018 | Raw socket capability hooks |
| 0019 | WiFi monitor mode + packet injection (mac80211) |
| 0020 | AF_PACKET MMAP ring buffer (high-perf capture) |
| 0021 | Netfilter MITM hooks (bettercap, mitmproxy) |
| 0022 | USB HID emulation (Rubber Ducky, Bash Bunny) |
| 0023 | ptrace forensics bez YAMA (memory analysis) |
| 0024 | kprobes/uprobes extended (frida, bpftrace) |
| 0025 | TUN/TAP multi-queue C2 tunneling |
| 0026 | Crypto User API extended (hashcat, JtR) |
| 0027 | Red Team Namespace (RTN) isolation |
| 0028 | Bluetooth HCI monitor + BLE sniffing |
| 0029 | NFQUEUE MITM extensions (SSL intercept) |
| 0030 | perf events side-channel (Spectre research) |

### Warstwa 3: OSTree/immutable integration (0031-0035)
Integracja z debian-ostree package managerem:

| Patch | Opis |
|-------|------|
| 0031 | dm-verity OSTree format (composefs) |
| 0032 | overlayfs OSTree deployment model |
| 0033 | IMA + OSTree boot verification |
| 0034 | /sys/kernel/hackeros/ostree/ API |
| 0035 | Marker pelnego buildu red team |

## OSTree/debian-ostree integracja

HackerOS Immutable Edition uzywa debian-ostree (odpowiednik rpm-ostree
dla Debiana) jako package manager. System jest immutable - system bazowy
jest read-only, zmiany sa atomowe przez OSTree commits.

Jadro dostarcza:
- dm-verity z OSTree hash tree format (patch 0031)
- composefs-compatible overlayfs (patch 0032)
- IMA weryfikacja OSTree commits (patch 0033)
- sysfs API dla debian-ostree (patch 0034)

## Wersja jadra

Wersja jadra jest konfigurowana w `config.hk` sekcja `[source]`:
```
[source]
-> base_version => 7.1
-> auto_latest  => false
```

Aby przestawic na nowsza wersje, zmien `base_version` i rebuild.
