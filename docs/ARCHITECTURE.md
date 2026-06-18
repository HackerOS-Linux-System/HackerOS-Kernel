# Architektura build systemu HackerOS Kernel

Ten dokument opisuje przeplyw danych i kolejnosc dzialan w `build.lua`,
przydatny przy debugowaniu lub rozszerzaniu build systemu.

## Strategia patchowania: append-only na koncu plikow

Jadro Linux zmienia sie szybko miedzy wersjami — linie kodu w srodku
plikow takich jak `kernel/ptrace.c` czy `net/core/dev.c` przesuwaja sie
lub zmieniaja kontekst praktycznie przy kazdym wydaniu. Klasyczny patch
dopasowany do konkretnych linii w środku pliku (np. "wstaw kod po linii
80 w funkcji X") bardzo szybko traci zdolnosc czystej aplikacji.

Z tego powodu **wszystkie 8 patchy HackerOS sa pisane jako bloki kodu
dopisywane na koncu odpowiedniego pliku**, otoczone `#ifdef
CONFIG_HACKEROS_KERNEL` / `#endif`. Koniec pliku jest najbardziej
stabilnym mozliwym punktem zaczepienia w unified diff — niezaleznie od
tego, ile kodu zmieni sie w środku pliku miedzy wersjami 7.1 i np. 7.5,
ostatnia linia pliku (i tym samym kontekst potrzebny `patch(1)`) zwykle
pozostaje rozpoznawalna.

Kazdy patch w `patches/` zostal wygenerowany i zweryfikowany
(`patch -p1 --dry-run`) wzgledem aktualnego drzewa `torvalds/linux`
(branch `master`, stan w trakcie tworzenia tego build systemu), wiec
sa to **realne, dzialajace diffy**, a nie wylacznie ilustracyjne
przyklady skladni.

Kompromis tego podejscia: kod dodawany przez patche jest celowo
"addytywny" (nowe symbole, nowe staticzne zmienne, nowe initcalle) a
nie modyfikuje bezposrednio logiki istniejacych funkcji upstreamu —
co jest bezpieczniejsze dla utrzymania kompatybilnosci, ale oznacza, ze
faktyczne wymuszanie wartosci hardeningowych (np. realne ustawienie
`randomize_kstack_offset` w runtime) odbywa siê przede wszystkim przez
fragment `.config` generowany przez `kconfig.lua`, a patche C dostarczaja
glownie znaczniki/branding/komunikaty diagnostyczne uzupelniajace ten
mechanizm. Jesli potrzebujesz głebszej integracji (np. faktycznej zmiany
logiki istniejacej funkcji), zalecane jest dopisanie wlasnego patcha
dopasowanego recznie do konkretnej, uzywanej przez Ciebie wersji jadra.

## Przeplyw budowy (7 krokow)

```
┌─────────────────────────────────────────────────────────────────────┐
│ [1/7] Wczytanie config.hk                                            │
│   - hk_parser.lua: parse() + resolve_interpolations()                │
│   - walidacja obecnosci [metadata]/[source]/[package]                │
│   - nadpisania z CLI (--version, --jobs)                              │
└─────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ [2/7] Walidacja zaleznosci systemowych                                │
│   - sprawdzenie: make, gcc, bc, flex, bison, dpkg-deb, patch...       │
└─────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ [3/7] Przygotowanie zrodel jadra (source.lua)                         │
│   - jesli auto_latest: zapytanie kernel.org/releases.json             │
│   - pobranie tarballa (curl/wget) + weryfikacja sha256                │
│   - rozpakowanie do src/linux-X.Y/ + symlink src/linux                │
└─────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ [4/7] Nakladanie patchy (patches.lua)                                  │
│   - iteracja po [patches].apply_order z config.hk                      │
│   - dry-run kazdego patcha przed faktyczna aplikacja                   │
│   - marker .hackeros-patches-applied zapobiega duplikacji               │
└─────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ [5/7] Generowanie .config (kconfig.lua)                                │
│   - mapowanie [hardening]/[xen]/[cybersecurity_subsystems] -> CONFIG_* │
│   - merge_config.sh: base.config + fragments/*.config + auto fragment  │
│   - make olddefconfig (dopelnienie zaleznosci Kconfig)                  │
└─────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ [6/7] Kompilacja (compile.lua)                                          │
│   - make -jN bzImage modules (z opcjonalnym ccache)                     │
│   - make INSTALL_MOD_PATH=DESTDIR modules_install                        │
│   - kopiowanie bzImage/System.map/config do DESTDIR/boot                  │
└─────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ [7/7] Budowa pakietu .deb (deb_package.lua)                              │
│   - kopiowanie DESTDIR -> debian-build/                                   │
│   - generowanie DEBIAN/control, postinst, prerm, postrm                   │
│   - dpkg-deb --build                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

## Dlaczego osobne moduly Lua, a nie jeden duzy plik?

`build.lua` jest punktem wejscia (entry point) i orkiestratorem — caly
ciezar logiki jest w `scripts/*.lua`, kazdy modul odpowiada za jedna,
spójna odpowiedzialnosc (SRP). Dzieki temu:

- mozna testowac/uruchamiac kazdy modul niezaleznie (np. `lua5.5 -e
  "print(require('scripts.hk_parser').load_hk_file('config.hk'))"`),
- dodanie wsparcia dla nowego formatu pakietu (np. `.rpm`) wymaga
  dodania nowego modulu `rpm_package.lua` bez dotykania reszty kodu,
- `build.lua` pozostaje krotki i czytelny jako "spis tresci" calego
  procesu budowy.

## Mechanizm `auto_latest` (wsparcie dla Linux 7.1+)

`scripts/source.lua` implementuje detekcje najnowszej wersji stabilnej
poprzez zapytanie do `https://www.kernel.org/releases.json` i lekkie
parsowanie wzorcem `"moniker":"stable"` + sasiadujace pole `"version"`
(bez zewnetrznej biblioteki JSON — Lua 5.5 standardowo jej nie ma, a
dodawanie zaleznosci tylko do sparsowania jednego pola nie byloby
uzasadnione).

Logika wyboru wersji:

1. Jesli `--version=X.Y` podane w CLI → uzyj jej bezposrednio (auto_latest
   zostaje wylaczone na ten przebieg).
2. Inaczej, jesli `[source].auto_latest = true` → zapytaj kernel.org,
   porownaj wynik z `[source].min_version` (`Utils.compare_versions`).
   Jesli wynik jest nowszy lub rowny minimum, uzyj go.
3. Inaczej (lub jesli zapytanie sieciowe sie nie powiodlo) → uzyj
   `[source].base_version` z `config.hk`.
4. Niezaleznie od powyzszego, finalna wersja jest zawsze sprawdzana
   wzgledem `[source].min_version` — jesli jest nizsza, build sie
   przerywa z bledem. To gwarantuje, ze `build.lua` nigdy nie zbuduje
   jadra starszego niz deklarowane minimum (domyslnie 7.1), nawet jesli
   ktos recznie wpisze stara wersje w `config.hk`.

Dzieki temu mechanizmowi `build.lua` **nie wymaga modyfikacji kodu** przy
kazdym nowym wydaniu jadra Linux — automatycznie "rusza" wraz z nowymi
wersjami stabilnymi, o ile API `kernel.org/releases.json` pozostanie
stabilne.

## Idempotencja i ponowne uruchamianie

- Pobrane tarballe nie sa sciagane ponownie, jesli juz istnieja w
  `build/` (`Utils.file_exists`).
- Rozpakowane zrodla nie sa rozpakowywane ponownie, jesli katalog
  `src/linux-X.Y/Makefile` juz istnieje.
- Patche nie sa nakladane ponownie, jesli istnieje marker
  `.hackeros-patches-applied` w drzewie zrodel.
- Dzieki temu mozna bezpiecznie przerwac i ponownie wywolac
  `lua5.5 build.lua` bez koniecznosci czyszczenia wszystkiego od zera —
  a w razie potrzeby pelnego resetu wystarczy `rm -rf src/ build/ dist/
  debian-build*`.
