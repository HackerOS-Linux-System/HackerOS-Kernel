# HackerOS Kernel (branch: cybersecurity)

Build system do kompilacji zmodyfikowanego jadra Linux dla
**HackerOS Cybersecurity Edition** — Debian-based dystrybucji Linuksa
stworzonej dla regularnych uzytkownikow, graczy i entuzjastow
cybersecurity ([HackerOS-Linux-System](https://github.com/HackerOS-Linux-System)).

Caly proces budowy — od pobrania zrodel jadra z kernel.org, przez
nalozenie patchy HackerOS, konfiguracje hardeningowa, kompilacje,
po zapakowanie do gotowego pliku `.deb` — jest zautomatyzowany w
skryptach **Lua** uruchamianych przez `lua5.5` (lub nowsza wersje Lua).

---

## Czym jest HackerOS Kernel?

HackerOS Kernel to fork waniliowego jadra Linux (kernel.org), dostosowany
specjalnie do edycji **cybersecurity** HackerOS — dystrybucji, ktora
domyslnie zawiera narzedzia do pentestingu/forensics oraz hypervisor
**Xen** do izolowanego uruchamiania niebezpiecznych probek i srodowisk
testowych. Standardowo HackerOS uzywa jadra Debiana lub XanMod/Liquorix —
ten projekt dostarcza **wlasny, dedykowany fork** zoptymalizowany pod
bezpieczenstwo, audyt i wirtualizacje, zamiast jadra Debiana.

Najwazniejsze cechy tego jadra:

- **Hardening domyslny**: KASLR, `STACKPROTECTOR_STRONG`, `FORTIFY_SOURCE`,
  domyslnie wlaczone `randomize_kstack_offset` (w przeciwienstwie do
  upstreamu, gdzie jest wylaczone), `SLAB_FREELIST_HARDENED`, page table
  isolation, retpoline, Lockdown LSM w trybie `confidentiality`.
- **Xen dom0/domU**: pelne wsparcie dla Xen jako hypervisora — HackerOS
  Cybersecurity Edition uzywa Xen do izolacji srodowisk testowych, a to
  jadro jest skompilowane z `CONFIG_XEN_DOM0=y` i powiazanymi opcjami.
- **Podsystemy cybersecurity**: rozszerzony `nf_tables`/netfilter, packet
  socket, USB monitor, wstrzykiwanie pakietow WiFi, monitoring Bluetooth,
  eBPF tracing, kprobes, ftrace, `dm-crypt`/`dm-verity`, TPM, IMA/EVM.
- **Patchset HackerOS** (8 patchy w `patches/`): branding jadra,
  dodatkowy hardening pamieci, restrykcje inspirowane grsecurity
  (dmesg restrict, Yama ptrace_scope), tuning Xen dom0, hooki forensics
  w stosie sieciowym, rozszerzony audyt syscalli, wylaczone przestarzale
  interfejsy debugowe (`/dev/kmem`). Wszystkie patche zostaly
  wygenerowane i zweryfikowane (`patch -p1 --dry-run`) wzgledem
  aktualnego drzewa `torvalds/linux` (branch `master`) i nakladaja sie
  jako samodzielne bloki `#ifdef CONFIG_HACKEROS_KERNEL` dopisywane na
  koncu odpowiednich plikow — co maksymalizuje szanse czystej aplikacji
  takze na przyszlych wersjach jadra (7.2, 7.3, 8.0...), bez koniecznosci
  trafiania w konkretne, zmienne miedzy wersjami linie kodu w srodku
  pliku.
- **Format `.deb`**: gotowy do instalacji na Debianie (i HackerOS, ktory
  jest oparty na Debian Testing) jednym `dpkg -i`.

---

## Wymagania

### Do uruchomienia `build.lua`

- **Lua 5.5 lub nowsza** (skrypt sam to weryfikuje i przerywa dzialanie,
  jesli wykryje za stara wersje)
- Polaczenie z internetem (sciaganie zrodel z `kernel.org`)
- System linuksowy (testowane na Debianie/HackerOS) z narzedziami:

  ```bash
  sudo apt-get install build-essential bc flex bison libssl-dev \
      libelf-dev dpkg-dev fakeroot xz-utils libncurses-dev \
      curl lua5.5
  ```

  Jesli `lua5.5` nie jest dostepne w repozytoriach Twojej dystrybucji,
  zainstaluj je ze zrodel (https://www.lua.org/download.html) lub uzyj
  najnowszej dostepnej wersji `lua5.x` — `build.lua` wymaga **minimum 5.5**.

### Do instalacji wygenerowanego `.deb`

- Debian (Testing/Stable) lub HackerOS
- Architektura `x86_64` (`amd64`)
- `dpkg`, `apt`, `grub2` (lub `grub-pc`/`grub-efi-amd64`)

---

## Szybki start

```bash
git clone <adres-tego-repozytorium> hackeros-kernel
cd hackeros-kernel

# Pelny build: pobiera zrodla, naklada patche, kompiluje, pakuje .deb
lua5.5 build.lua
```

Po zakonczeniu builda w katalogu `dist/` znajdziesz plik w stylu:

```
dist/hackeros-kernel-cybersecurity_7.1-hk1_amd64.deb
```

Instalacja na Debianie/HackerOS:

```bash
sudo dpkg -i dist/hackeros-kernel-cybersecurity_*.deb
sudo reboot
```

**Co dzieje sie podczas instalacji pakietu `.deb`:**

1. Skrypt `postinst` wykrywa i usuwa zainstalowane pakiety
   `linux-image-*` (aktualne jadro Debiana).
2. Generuje `initramfs` dla nowego jadra HackerOS.
3. Aktualizuje konfiguracje GRUB (`update-grub`) i ustawia HackerOS Kernel
   jako **domyslny** wpis startowy.
4. Jesli w systemie wykryty zostanie Xen Hypervisor, wyswietla informacje,
   ze jadro jest gotowe do pracy jako `dom0`.

Po restarcie systemu `uname -r` powinno zwrocic wersje z sufiksem
`-hackeros-cybersec`.

---

## Opcje `build.lua`

```text
lua5.5 build.lua [opcje]

  --version=X.Y       Wymusza konkretna wersje jadra Linux (np. 7.1, 7.2, 8.0).
                       Musi byc >= min_version z config.hk (domyslnie 7.1).
  --no-download         Nie sciaga zrodel - wymaga, by byly juz w src/
  --skip-patches         Pomija nakladanie patchy HackerOS (tryb debug)
  --jobs=N               Nadpisuje liczbe wątkow kompilacji (domyslnie: auto/nproc)
  --config=PATH           Uzywa innego pliku konfiguracyjnego .hk niz config.hk
  --keep-going           Nie przerywa przy bledach niekrytycznych
  --help, -h              Wyswietla pomoc
```

### Wsparcie dla wersji Linuksa

`build.lua` jest napisany tak, by **automatycznie wspieral kazda wersje
Linuksa od 7.1 wzwyz**, rowniez te jeszcze nieopublikowane w momencie
pisania tego kodu:

- Jesli `[source].auto_latest` w `config.hk` jest ustawione na `true`
  (domyslnie tak), skrypt **sam odpytuje `kernel.org/releases.json`**
  i wybiera najnowsza dostepna wersje stabilna, o ile jest `>= min_version`.
- Mozesz nadpisac to recznie flaga `--version=X.Y` (np. `--version=7.4`),
  niezaleznie od tego, czy taka wersja istniala w momencie napisania
  tego build systemu.
- `[source].min_version` (domyslnie `7.1`) jest twardym dolnym limitem —
  build odmowi dzialania na starszych wersjach.

Innymi slowy: **nie trzeba aktualizowac `build.lua` przy kazdym nowym
wydaniu jadra** — wystarczy, ze kernel.org opublikuje nowa wersje stabilna,
a skrypt sam ja wykryje przy kolejnym uruchomieniu.

---

## Struktura projektu

```
.
├── build.lua                  # Glowny skrypt budujacy (entry point)
├── config.hk                  # Konfiguracja builda w formacie .hk
├── scripts/
│   ├── utils.lua               # Logging, shell, wersjonowanie, pliki
│   ├── hk_parser.lua            # Parser formatu .hk (uzywany do config.hk)
│   ├── source.lua                # Pobieranie/wykrywanie wersji zrodel jadra
│   ├── patches.lua                # Nakladanie patchy HackerOS
│   ├── kconfig.lua                # Generowanie fragmentow .config z config.hk
│   ├── compile.lua                 # Kompilacja jadra + instalacja do DESTDIR
│   └── deb_package.lua             # Budowa finalnego pakietu .deb
├── patches/                    # Patchset HackerOS Cybersecurity (8 patchy)
│   ├── 0001-hackeros-branding.patch
│   ├── 0002-hardened-memory-protections.patch
│   ├── 0003-grsecurity-inspired-restrictions.patch
│   ├── 0004-xen-dom0-cybersec-tuning.patch
│   ├── 0005-network-forensics-hooks.patch
│   ├── 0006-syscall-auditing-extended.patch
│   ├── 0007-randomize-kstack-default-on.patch
│   └── 0008-disable-legacy-debug-interfaces.patch
├── config/
│   ├── base.config              # Bazowy punkt startowy .config
│   └── fragments/                # Opcjonalne dodatkowe fragmenty .config
├── debian/                     # Dokumentacja/szablony pakietowania
├── src/                        # Tu trafiaja sciagniete zrodla jadra (linux-X.Y/)
└── docs/
    └── ARCHITECTURE.md          # Szczegolowy opis architektury build systemu
```

---

## Format `.hk`

`config.hk` jest napisany w formacie **`.hk`** — natywnym formacie
konfiguracji ekosystemu HackerOS (zamiennik YAML uzywany m.in. przez
menedzer pakietow `hpm`). Pelna specyfikacja:
<https://hackeros-linux-system.github.io/HackerOS-Website/tools-docs/hk.html>

Skrocony przyklad skladni:

```hk
[hardening]
-> kaslr                  => true
-> stack_protector_strong  => true
-> lockdown_mode            => confidentiality

[xen]
-> enabled       => true
-> dom0_support  => true
```

Parser tego formatu (`scripts/hk_parser.lua`) zostal napisany od zera w
Lua specjalnie dla tego projektu i wspiera sekcje, zagniezdzanie
myslnikowe (`->`, `-->`, `--->`), klucze kropkowe, tablice oraz
interpolacje `${sekcja.klucz}` / `${env:VAR}`.

---

## Dostosowywanie builda

Wszystkie najwazniejsze decyzje buildu sa w **`config.hk`** — nie trzeba
edytowac kodu Lua, aby np.:

- zmienic minimalna/bazowa wersje jadra (`[source].base_version`,
  `[source].min_version`),
- wylaczyc/wlaczyc konkretny mechanizm hardeningu (`[hardening]`),
- wylaczyc wsparcie Xen, jesli Twoja instalacja HackerOS go nie uzywa
  (`[xen].enabled => false`),
- dodac/usunac patch z listy `[patches].apply_order`,
- zmienic zaleznosci pakietu `.deb` (`[package].depends`,
  `[package].recommends`).

Dla zmian na poziomie samego jadra (dodatkowe sterowniki, opcje
specyficzne dla Twojego sprzetu) dodaj wlasny plik `*.config` do
`config/fragments/` — zostanie automatycznie scalony przy kazdym buildzie.

---

## Bezpieczenstwo i odpowiedzialnosc

To jadro jest przeznaczone do pracy badawczej, edukacyjnej i
profesjonalnej w obszarze cybersecurity (pentesting, forensics, analiza
malware w izolowanych domU pod Xen). Wylaczanie mechanizmow takich jak
`MODULE_SIG_FORCE` czy uzywanie trybu `lockdown=confidentiality` ma swoje
konsekwencje dla kompatybilnosci z niektorymi sterownikami binarnymi —
sprawdz `config.hk` i dostosuj sekcje `[hardening]` do swoich potrzeb
przed buildem produkcyjnym.

---

## Licencja

Jadro Linux jest objete licencja **GPL-2.0**. Patche i build system
HackerOS Kernel (ten projekt) sa dystrybuowane na tych samych zasadach,
zgodnie z `[metadata].license` w `config.hk`.

---

## Autor / kontakt

**HackerOS Linux System** — <hackeros068@gmail.com>
<https://hackeros-linux-system.github.io/HackerOS-Website/>
