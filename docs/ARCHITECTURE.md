# Architektura build systemu HackerOS Kernel

## Przeplyw budowy (8 krokow)

```
[1/8] Wczytanie config.hk (hk_parser: parse + resolve_interpolations)
[2/8] Walidacja zaleznosci systemowych (make, gcc, openssl, ...)
[3/8] Przygotowanie zrodel jadra (source.lua: auto_latest, sha256 check)
[4/8] Nakladanie 16-patchowego patchsetu (patches.lua: dry-run + marker)
[5/8] Generowanie .config (kconfig.lua) + klucze podpisywania (signing.lua)
[6/8] Kompilacja jadra + DESTDIR + HEADERS_DESTDIR (compile.lua)
[7/8] Budowa 2x .deb: jadro + naglowki (deb_package.lua + runtime_hardening.lua)
[8/8] Podsumowanie (output paths, instrukcje MOK enrollment)
```

Kazdy krok niekrytyczny (4, 5, klucze, naglowki, pakowanie headers) jest
opakowany w `pcall` + `soft_error(opts, msg)`, ktora respektuje
`--keep-going`: przy bledzie ostrzega i kontynuuje, zamiast przerywac
caly proces. Krok 6 (kompilacja) jest zawsze krytyczny — bez skompilowanego
jadra nic dalej nie ma sensu.

## Trzy warstwy hardeningu i dlaczego sa rozdzielone

### Warstwa 1: Kconfig (`kconfig.lua`)

CONFIG_* wkompilowane w binarke jadra. Zmiana wymaga przebudowy.
Najsilniejsza forma hardeningu (nie da sie obejsc w runtime bez
przeladowania jadra), ale najmniej elastyczna.

### Warstwa 2: Runtime hardening (`runtime_hardening.lua`)

Boot params (`GRUB_CMDLINE_LINUX_DEFAULT`) i sysctl
(`/etc/sysctl.d/99-hackeros-cybersec.conf`). To **oficjalne,
dokumentowane interfejsy ABI Linuksa** — stabilne miedzy wersjami jadra
w odroznieniu od linii kodu w srodku plikow `.c`. Administrator moze
je swiadomie nadpisac po instalacji, co jest pozadane (hardening
"z pudelka", nie "zabetonowany"). Zweryfikowano w dokumentacji kernela
(`Documentation/admin-guide/kernel-parameters.txt`) i kodzie zrodlowym
(np. `kernel/bpf/core.c`: `int bpf_jit_harden __read_mostly;` = sysctl
`net.core.bpf_jit_harden`).

### Warstwa 3: Patchset C (`patches/0001`-`0016`)

Realne zmiany kodu, podzielone na dwie kategorie:

- **Patche 1-8**: infrastruktura (branding `CONFIG_HACKEROS_KERNEL`) i
  znaczniki/komunikaty diagnostyczne uzywane przez pozostale patche i
  narzedzia HackerOS. Append-only na koncu plikow dla maksymalnej
  trwalosci miedzy wersjami.
- **Patche 9-16**: funkcjonalne zmiany semantyki - zmieniaja faktyczne
  wartosci startowe zmiennych jadra (`bpf_jit_harden`, `ptrace_scope`)
  lub dodaja audit hooki w realnych punktach decyzyjnych (TCP-MD5,
  USB authorize, module signing reject, Xen malicious frontend, eBPF
  load, lockdown change). Kazdy zweryfikowany `patch --dry-run` na
  aktualnym `torvalds/linux` (zobacz `scripts/test_patches.lua`).

**Dlaczego nie wszystko jako patch C?** Bo runtime hardening (warstwa 2)
jest bardziej stabilny miedzy wersjami niz patch zaczepiony o konkretne
linie kodu. `randomize_kstack_offset` jest realizowane jako boot param
(warstwa 2), NIE jako patch zmieniajacy `DEFINE_STATIC_KEY_FALSE` w
`kernel/entry/common.c` (co byloby krucha, bo ta linia historycznie sie
przenosila miedzy plikami). Decyzja "patch C vs runtime ABI" byla
podejmowana indywidualnie dla kazdego mechanizmu na podstawie tego, czy
istnieje stabilny, dokumentowany interfejs runtime.

## Strategia patchowania: anchory i forward declarations

Wszystkie patche 9-16 uzywaja wzorca:

1. **Forward declaration** funkcji audytu/hooka bezposrednio po ostatnim
   `#include` (stabilny anchor — sekcja includow rzadko się przegrupowuje
   drastycznie).
2. **Jednolinijkowe wywolanie** hooka w miejscu decyzyjnym (np. po
   `hlist_add_head_rcu(...)` w `__tcp_md5_do_add`) — minimalna powierzchnia
   konfliktu, bo to pojedyncza linia dodana, nie zmiana wielu linii.
3. **Definicja funkcji append-only** na koncu pliku — zero ryzyka
   konfliktu z dalszymi zmianami w pliku.

Przyklad (patch 11, TCP-MD5 audit):
```c
// 1. forward declaration (po #include <trace/events/tcp.h>)
#ifdef CONFIG_HACKEROS_KERNEL
static void hackeros_tcp_md5_audit_log(const struct sock *sk, int family, u8 keylen);
#endif

// 2. wywolanie w __tcp_md5_do_add (po hlist_add_head_rcu)
#ifdef CONFIG_HACKEROS_KERNEL
hackeros_tcp_md5_audit_log(sk, family, newkeylen);
#endif

// 3. definicja na koncu pliku
#ifdef CONFIG_HACKEROS_KERNEL
static void hackeros_tcp_md5_audit_log(...) { pr_info(...); }
#endif
```

Niektore patche (9, 10) sa jeszcze prostsze - zmieniaja tylko wartosc
inicjalizacji zmiennej modulowej (`int bpf_jit_harden __read_mostly = 2;`)
bez zadnego wywolania funkcji, co jest najmniejsza mozliwa powierzchnia
zmiany.

## Podpisywanie modulow (`signing.lua`)

```
ensure_module_signing_key(cfg)
  -> openssl req -new -nodes -x509 -addext basicConstraints=critical,CA:FALSE
                 -addext keyUsage=digitalSignature
                 -addext extendedKeyUsage=codeSigning
                 -newkey rsa:4096 -keyout priv.key -out cert.crt
  -> combined.pem = priv.key + cert.crt (format wymagany przez CONFIG_MODULE_SIG_KEY)

inject_into_kernel_config(cfg, kernel_src, combined.pem)
  -> .config: CONFIG_MODULE_SIG_KEY="/abs/path/combined.pem"

install_for_dkms(cfg, deb_root, combined.pem, cert.crt)
  -> deb_root/usr/share/hackeros-kernel/signing-key/module-signing.pem (chmod 0600)
  -> deb_root/usr/share/hackeros-kernel/signing-key/module-signing.crt (chmod 0644)
  -> deb_root/usr/share/hackeros-kernel/hackeros-sign-module.sh
```

Klucz jest generowany **raz** i zachowywany w `signing.keys_dir`
(domyslnie `./build/keys`) — kolejne wywolania `build.lua` reuzywaja
ten sam klucz (`ensure_*` sprawdza obecnosc przed generowaniem), co
gwarantuje, ze moduly podpisane przy poprzednim buildzie wciaz sa
zaufane przez nowe jadro (o ile uzywasz tej samej instalacji build
systemu).

## Idempotencja i ponowne uruchamianie

- Tarballe/zrodla/patche: jak w poprzedniej wersji (markery, sprawdzanie istnienia).
- **Klucze podpisywania**: generowane tylko jesli `combined.pem` i `priv.key`
  jeszcze nie istnieja w `keys_dir`.
- **GRUB_CMDLINE w postinst**: marker `# hackeros_cmdline_applied` w
  `/etc/default/grub` zapobiega wielokrotnemu dopisywaniu tych samych
  parametrow przy reinstalacji/upgrade pakietu.
- **Rollback safety net**: `postinst` tworzy backup `grub.cfg` i
  `/etc/default/grub` PRZED jakakolwiek modyfikacja
  (`/var/lib/hackeros-kernel/grub.cfg.pre-<timestamp>`), a `postrm`
  przywraca `/etc/default/grub` z backupu przy `purge`.

## CI: `scripts/test_patches.lua` + GitHub Actions

`test_patches.lua` pobiera **tylko pliki dotykane przez patche** (lista
`PATCH_TOUCHED_FILES`, 17 plikow) z `raw.githubusercontent.com/torvalds/linux`,
testuje `patch --dry-run` sekwencyjnie (z faktyczna aplikacja miedzy
krokami, zeby kolejne patche widzialy poprawny kontekst), i generuje
raport z exit code 0/1. `.github/workflows/ci.yml` uruchamia
to codziennie + przy zmianach w `patches/`/`config.hk`, na najnowszej
wersji stabilnej oraz matrycy konkretnych wersji, i automatycznie
otwiera GitHub Issue przy wykryciu niezgodnosci.

Ten sam workflow zawiera rowniez `build-deb-smoke` (codziennie +
push/PR, `build.lua --ci-fast`) i `build-deb-full` (co tydzien/recznie,
pelny produkcyjny build) - oba publikuja wygenerowany `.deb` jako
artefakt workflow. `build-deb-smoke` wykrywa bledy kompilacji, ktorych
sam `patch --dry-run` nie jest w stanie zlapac (np. forward declaration
typu wstrzykniete przed jego pelna definicja w naglowku - tak wlasnie
zostal znaleziony i naprawiony blad w patchu 0012 podczas tworzenia
tego projektu).
