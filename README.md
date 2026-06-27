# src/

Ten katalog jest miejscem docelowym dla zrodel jadra Linux pobieranych
automatycznie przez `build.lua` (modul `scripts/source.lua`).

Podczas builda powstanie tutaj struktura w stylu:

```
src/
  linux-7.1/        <- rozpakowane zrodla konkretnej wersji
  linux -> linux-7.1   <- symlink uzywany przez reszte build systemu
```

Symlink `linux` jest zawsze aktualizowany tak, by wskazywal na wersje
faktycznie uzyta w ostatnim biegu `build.lua` (zgodnie z `auto_latest`
i `min_version` z `config.hk`, lub wartoscia wymuszona przez `--version=`).

Ten katalog jest celowo pusty w repozytorium/archiwum dystrybucyjnym -
zrodla jadra (setki MB) nie sa dystrybuowane wraz z build systemem,
tylko sciagane on-demand z kernel.org.

Jesli chcesz dostarczyc wlasne, juz pobrane zrodla (np. offline),
umiesc je tutaj jako `linux-X.Y/` i uruchom:

```
lua5.5 build.lua --no-download
```

**HackerOS Linux System** — <hackeros068@gmail.com>
<https://hackeros-linux-system.github.io/HackerOS-Website/>
