# HackerOS Kernel (branch: cybersecurity)

Build system do kompilacji zmodyfikowanego jadra Linux dla
**HackerOS Red Team Edition** — Debian-based dystrybucji Linuksa
stworzonej dla regularnych uzytkownikow, graczy i entuzjastow
cybersecurity ([HackerOS-Linux-System](https://github.com/HackerOS-Linux-System)).

Caly proces budowy — od pobrania zrodel jadra z kernel.org, przez
nalozenie 16-patchowego patchsetu HackerOS, generowanie kluczy
podpisywania modulow, konfiguracje hardeningowa (Kconfig + sysctl +
boot params), kompilacje, po zapakowanie do **dwoch** plikow `.deb`
(jadro + naglowki) — jest zautomatyzowany w skryptach **Lua**
uruchamianych przez `lua5.5` (lub nowsza wersje Lua).

---

## Czym jest HackerOS Kernel?

HackerOS Kernel to fork waniliowego jadra Linux (kernel.org), dostosowany
specjalnie do edycji **cybersecurity** HackerOS — dystrybucji, ktora
domyslnie zawiera narzedzia do pentestingu/forensics oraz hypervisor
**Xen** do izolowanego uruchamiania niebezpiecznych probek i srodowisk
testowych.

### Trzy warstwy hardeningu

To jadro nie jest "kosmetycznym" forkiem — kazda warstwa hardeningu
realizuje cos faktycznie wykonywalnego w runtime, nie tylko deklaracje:

**1. Kconfig (CONFIG_\* wkompilowane w binarke)** — generowane przez
`scripts/kconfig.lua` na podstawie `[hardening]`/`[xen]`/
`[cybersecurity_subsystems]` w `config.hk`: KASLR, `STACKPROTECTOR_STRONG`,
`FORTIFY_SOURCE`, `SLAB_FREELIST_HARDENED`, page table isolation,
retpoline, Lockdown LSM (`confidentiality`), `CONFIG_XEN_DOM0=y`,
`CONFIG_MODULE_SIG=y`, rozszerzone moduly eBPF/forensics/crypto.

**2. Runtime hardening (boot params + sysctl, ABI-stabilne)** —
generowane przez `scripts/runtime_hardening.lua` z sekcji
`[runtime_hardening]`: `randomize_kstack_offset=on`,
`usbcore.authorized_default=2` (blokada BadUSB), `init_on_alloc=1`,
`slab_nomerge` w GRUB_CMDLINE; `kernel.yama.ptrace_scope=2`,
`kernel.kptr_restrict=2`, `net.core.bpf_jit_harden=2`,
`kernel.unprivileged_bpf_disabled=1` i 12 innych w
`/etc/sysctl.d/99-hackeros-cybersec.conf`. Te ustawienia sa
**oficjalnymi, dokumentowanymi interfejsami ABI Linuksa** — stabilne
miedzy wersjami jadra, w odroznieniu od linii kodu w srodku plikow `.c`.

**3. Patchset HackerOS (35 patchy w `patches/`)** — realne, funkcjonalne
zmiany kodu C zweryfikowane (`patch --dry-run`) na aktualnym drzewie
`torvalds/linux`:

| # | Patch | Co robi |
|---|-------|---------|
| 1 | branding | `CONFIG_HACKEROS_KERNEL` Kconfig flag uzywana przez patche 2-16 |
| 2 | hardened-memory | Wymusza `HARDENED_USERCOPY` i zerowanie stosu |
| 3 | grsecurity-inspired | Domyslne `dmesg_restrict`, Yama ptrace_scope znaczniki |
| 4 | xen-dom0-tuning | Znacznik audytu zdarzen hypervisora dla dom0 |
| 5 | network-forensics | Punkt integracji dla eBPF forensics w stosie sieciowym |
| 6 | syscall-auditing | Eksportowana lista syscalli wysokiego priorytetu dla auditd |
| 7 | randomize-kstack | Komunikat diagnostyczny (realna wartosc wymuszana przez boot param) |
| 8 | disable-debug-ifaces | Znacznik wylaczenia `/dev/kmem` |
| **9** | **bpf-jit-harden** | **Zmienia domyslna wartosc `bpf_jit_harden` z 0 na 2** (constant blinding, ochrona przed JIT spraying) |
| **10** | **yama-ptrace-restricted** | **Zmienia domyslny `ptrace_scope` z 1 (RELATIONAL) na 2 (CAPABILITY)** |
| **11** | **tcp-md5-audit** | **Audit log kazdej zmiany klucza TCP-MD5** (ochrona sesji BGP) |
| **12** | **usb-audit** | **Audit log autoryzacji USB z VID:PID** (forensics BadUSB) |
| **13** | **module-sig-tamper-evident** | **Audit log kazdej odmowy wczytania niepodpisanego modulu** |
| **14** | **xen-domu-isolation** | **Audit log zdarzen "malicious frontend" w Xen netback** (DoS od domU) |
| **15** | **ebpf-audit-trail** | **Rozszerza wbudowany `AUDIT_BPF` o PID/comm inicjatora** |
| **16** | **lockdown-strict** | **Audit log kazdej proby zmiany poziomu lockdown przez securityfs** |

Patche 9-16 (pogrubione) to **funkcjonalne zmiany semantyki**, nie tylko
deklaracje — zmieniaja faktyczne wartosci startowe zmiennych jadra lub
dodaja realne hooki audytowe w miejscach krytycznych dla bezpieczenstwa.

### Podpisywanie modulow (prawdziwe, nie deklaratywne)

`scripts/signing.lua` generuje **wlasna, trwala pare kluczy X.509 RSA
4096** (zamiast jednorazowego klucza generowanego domyslnie przez sam
kernel przy kazdym buildzie) i wstrzykuje `CONFIG_MODULE_SIG_KEY` do
`.config`. Klucz jest:

- zweryfikowany end-to-end: skompilowany `scripts/sign-file` z
  rzeczywistych zrodel jadra **realnie podpisuje** plik testowy
  (`~Module signature appended~` magic string obecny w wyniku),
- dystrybuowany w pakiecie `.deb` (`/usr/share/hackeros-kernel/signing-key/`,
  klucz prywatny `chmod 0600`) wraz ze skryptem
  `hackeros-sign-module.sh <plik.ko>`, dzieki czemu **DKMS i moduly
  out-of-tree** (np. sterowniki WiFi do wstrzykiwania pakietow,
  rtl88xxau/rtl8812au) moga byc podpisane TYM SAMYM kluczem co jadro,
  zamiast zostac odrzucone przy `module_sig_force=true`,
- certyfikat publiczny gotowy do **UEFI Secure Boot MOK enrollment**
  (`mokutil --import`).

### Osobny pakiet naglowkow (DKMS-ready)

Build generuje **drugi pakiet `.deb`** —
`hackeros-kernel-headers-cybersecurity` — z naglowkami, `Module.symvers`
i binarka `scripts/sign-file`, niezbedny do budowania modulow
out-of-tree. Zawiera `Depends: gcc, make, binutils, libssl-dev, ...` i
`Recommends: dkms`, oraz tworzy symlink `/lib/modules/<ver>/build`
wymagany przez DKMS.

---

## Wymagania

### Do uruchomienia `build.lua`

- **Lua 5.5 lub nowsza** (skrypt sam to weryfikuje)
- Polaczenie z internetem (zrodla z `kernel.org`, patche testowane wzgledem `github.com/torvalds/linux`)
- System linuksowy z narzedziami:

  ```bash
  sudo apt-get install build-essential bc flex bison libssl-dev \
      libelf-dev dpkg-dev fakeroot xz-utils libncurses-dev \
      curl openssl lua5.5
  ```

### Do instalacji wygenerowanych `.deb`

- Debian (Testing/Stable) lub HackerOS, architektura `x86_64`/`amd64`
- `dpkg`, `apt`, `grub2`

---

## Szybki start

```bash
git clone <adres-tego-repozytorium> hackeros-kernel
cd hackeros-kernel

# Pelny build: zrodla + 35 patchy + klucze podpisywania + kompilacja + 2x .deb
lua5.5 build.lua
```

Wynik w `dist/`:

```
dist/hackeros-kernel-cybersecurity_7.1-hk1_amd64.deb
dist/hackeros-kernel-headers-cybersecurity_7.1-hk1_amd64.deb
build/keys/hackeros-signing-key.crt   <- do MOK enrollment jesli Secure Boot
```

Instalacja:

```bash
sudo dpkg -i dist/hackeros-kernel-cybersecurity_*.deb
sudo dpkg -i dist/hackeros-kernel-headers-cybersecurity_*.deb   # opcjonalnie, dla DKMS
sudo reboot
```

Jesli uzywasz UEFI Secure Boot:

```bash
sudo mokutil --import build/keys/hackeros-signing-key.crt
# nastepnie zrestartuj i potwierdz enrollment w MOK Manager (niebieski ekran UEFI)
```

**Co dzieje sie podczas instalacji `.deb`:**

1. **Backup** biezacego `grub.cfg` i `/etc/default/grub` do `/var/lib/hackeros-kernel/` (rollback safety net).
2. Wgrywa `/etc/sysctl.d/99-hackeros-cybersec.conf` (16 ustawien runtime hardening).
3. Dopisuje boot params (`randomize_kstack_offset=on`, `usbcore.authorized_default=2`, ...) do `GRUB_CMDLINE_LINUX_DEFAULT` — **bez nadpisywania** istniejacych parametrow.
4. Usuwa zainstalowane pakiety `linux-image-*` (stare jadro Debiana).
5. Generuje `initramfs`, aktualizuje GRUB, ustawia HackerOS Kernel jako **domyslny**.
6. Wykrywa Xen Hypervisor i informuje o gotowosci dom0.
7. Jesli moduly sa podpisane — wyswietla instrukcje MOK enrollment.

---

## Opcje `build.lua`

```text
lua5.5 build.lua [opcje]

  --version=X.Y    Wymusza konkretna wersje jadra Linux (np. 7.1, 7.2, 8.0)
  --no-download     Nie sciaga zrodel - wymaga, by byly juz w src/
  --skip-patches     Pomija patchset HackerOS (tryb debug/porownawczy)
  --jobs=N            Nadpisuje liczbe wątkow kompilacji
  --config=PATH       Inny plik .hk niz config.hk
  --keep-going        Kontynuuje mimo bledow niekrytycznych (patche/headers/signing)
  --no-sign            Pomija generowanie kluczy i podpisywanie modulow
  --no-headers          Nie buduje odrebnego pakietu naglowkow
  --ci-fast              Preset szybkiego smoke-buildu (config/ci-tiny.config,
                         bez Xen/signing/headers) - uzywane przez CI do
                         weryfikacji, ze patchset realnie sie KOMPILUJE
  --help, -h               Wyswietla pomoc
```

`--keep-going` jest realnie respektowane w 5 miejscach krytycznej
sciezki builda (patche, generowanie `.config`, klucze podpisywania,
naglowki, pakowanie headers) — przy bledzie niekrytycznym build
kontynuuje z ostrzezeniem zamiast przerywac caly proces.

### Wsparcie dla wersji Linuksa (7.1+)

Jesli `[source].auto_latest = true` (domyslnie), `build.lua` **sam
odpytuje `kernel.org/releases.json`** i wybiera najnowsza dostepna
wersje stabilna >= `min_version`. Patchset jest zaprojektowany
defensywnie (forward declarations, append-only gdzie mozliwe, anchor
na stabilnych liniach jak deklaracje zmiennych modulowych) wlasnie
dlatego, zeby przetrwac przyszle wydania bez edycji.

---

## CI: testy patchy + budowa .deb

```bash
# Testuje wszystkie 35 patchy wzgledem najnowszej stabilnej wersji z kernel.org
lua5.5 scripts/test_patches.lua --verbose

# Testuje wzgledem konkretnej wersji
lua5.5 scripts/test_patches.lua --version=7.2

# Testuje wzgledem lokalnie pobranych zrodel (offline)
lua5.5 scripts/test_patches.lua --local=./src/linux

# Smoke-build: realna kompilacja z PELNYM patchsetem na minimalnym .config
# (bez Xen/signing/headers) - weryfikuje, ze patche nie tylko sie NAKLADAJA,
# ale rowniez SIE KOMPILUJA. Kilka-kilkanascie minut.
lua5.5 build.lua --ci-fast
```

`.github/workflows/ci.yml` uruchamia automatycznie:

| Job | Kiedy | Co robi |
|-----|-------|---------|
| `lua-syntax` | kazdy push/PR | `luac -p` na wszystkich `.lua` + smoke test parsera `config.hk` |
| `patch-compat-latest` | codziennie + push/PR | `test_patches.lua` na najnowszej stabilnej wersji |
| `patch-compat-versions` | codziennie + push/PR | `test_patches.lua` na matrycy konkretnych wersji (`7.1`, ...) |
| `shell-check` | push/PR | Walidacja configu i przygotowania skryptow `.deb` |
| **`build-deb-smoke`** | **codziennie + push/PR** | **`build.lua --ci-fast`: realna kompilacja + pakiet `.deb`, upload jako artefakt** |
| **`build-deb-full`** | **co tydzien (niedziela) + recznie** | **Pelny produkcyjny build: Xen + signing + headers, 2x `.deb`** |
| `notify-on-failure` | przy niezgodnosci patcha | Auto-tworzy GitHub Issue z instrukcja naprawy |

**`build-deb-smoke`** zlapal realny blad podczas tworzenia tego projektu:
patch USB (0012) nakladal sie czysto (`patch --dry-run` = OK), ale nie
kompilowal sie na rzeczywistym tagu `v7.1` (`incompatible-pointer-types`,
bo forward declaration trafila przed `#include <linux/usb.h>`). Sam test
nakladania nigdy by tego nie wykryl — to jest powod, dla ktorego smoke-build
jest osobnym, rownie waznym etapem CI co testy patchy.

**Reczne wywolanie** (zakladka Actions → "Run workflow"):
- `build_mode: smoke` — szybki build na minimalnym configu (domyslny)
- `build_mode: full` — pelny produkcyjny build z Xen/signing/headers
- `kernel_version` — opcjonalnie wymusza konkretna wersje (np. `7.2`)

Wygenerowane pakiety `.deb` sa dostepne jako artefakty workflow (zakladka
"Summary" konkretnego przebiegu → "Artifacts"), przechowywane 14 dni
(smoke) lub 30 dni (full).

---

## Struktura projektu

```
.
├── build.lua                       # Glowny skrypt budujacy (8 krokow)
├── config.hk                       # Konfiguracja w formacie .hk
├── scripts/
│   ├── utils.lua                    # Logging, shell, wersjonowanie
│   ├── hk_parser.lua                 # Parser formatu .hk (z obsługa literal keys)
│   ├── source.lua                     # Pobieranie/auto-detekcja wersji jadra
│   ├── patches.lua                     # Nakladanie 16-patchowego patchsetu
│   ├── kconfig.lua                      # CONFIG_* z [hardening]/[xen]/[cybersecurity_subsystems]
│   ├── runtime_hardening.lua             # sysctl.d + GRUB_CMDLINE z [runtime_hardening]
│   ├── signing.lua                        # Generowanie kluczy X.509 + CONFIG_MODULE_SIG_KEY
│   ├── compile.lua                         # Kompilacja + DESTDIR (jadro) + HEADERS_DESTDIR
│   ├── deb_package.lua                      # 2x .deb: jadro + naglowki, rollback-aware postinst
│   └── test_patches.lua                      # CI: test kompatybilnosci patchy
├── patches/                         # 35 patchy (8 podstawowych + 8 funkcjonalnych)
├── config/
│   ├── base.config                  # Bazowy .config
│   └── fragments/                    # Opcjonalne dodatkowe fragmenty .config
├── debian/                          # Dokumentacja pakietowania
├── src/                             # Zrodla jadra (sciagane automatycznie)
├── .github/workflows/
│   └── ci.yml                          # CI: testy patchy + smoke/full build .deb
└── docs/
    └── ARCHITECTURE.md               # Architektura build systemu
```

---

## Format `.hk`

`config.hk` jest napisany w formacie **`.hk`** — natywnym formacie
konfiguracji ekosystemu HackerOS. Pelna specyfikacja:
<https://hackeros-linux-system.github.io/HackerOS-Website/tools-docs/hk.html>

Parser (`scripts/hk_parser.lua`) wspiera sekcje, zagniezdzanie
myslnikowe (`->`, `-->`, `--->`), klucze kropkowe, tablice, interpolacje
`${sekcja.klucz}` / `${env:VAR}`, oraz **literalne klucze w cudzyslowach**
(np. `"net.ipv4.tcp_syncookies" => 1`) — niezbedne do zapisania nazw
sysctl bez przypadkowego tworzenia zagniezdzenia `net.ipv4.tcp_syncookies`.

---

## Dostosowywanie builda

Wszystkie decyzje builda sa w **`config.hk`**:

- `[hardening]` / `[xen]` / `[cybersecurity_subsystems]` → CONFIG_* (kconfig.lua)
- `[runtime_hardening].boot_params` / `.sysctl` → GRUB_CMDLINE + sysctl.d (runtime_hardening.lua)
- `[signing]` → generowanie i instalacja kluczy podpisywania modulow
- `[headers_package]` → wlaczenie/wylaczenie pakietu naglowkow DKMS
- `[patches].apply_order` → lista i kolejnosc patchy

Dla zmian na poziomie samego jadra dodaj plik `*.config` do
`config/fragments/` — zostanie automatycznie scalony.

---

## Bezpieczenstwo i odpowiedzialnosc

To jadro jest przeznaczone do pracy badawczej, edukacyjnej i
profesjonalnej w cybersecurity. `module_sig_force=true` w polaczeniu z
`signing.sign_modules=true` daje pelna ochrone integralnosci modulow,
ale wymaga MOK enrollment na systemach z UEFI Secure Boot. Domyslnie
`module_sig_force=false`, zeby unikac blokady przy pierwszej instalacji.

---

## Licencja

Jadro Linux jest objete licencja **GPL-2.0**. Patche i build system
HackerOS Kernel sa dystrybuowane na tych samych zasadach.

---

## Autor / kontakt

**HackerOS Linux System** — <hackeros068@gmail.com>
<https://hackeros-linux-system.github.io/HackerOS-Website/>
