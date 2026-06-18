# debian/

`build.lua` generuje docelowa strukture pakietu `.deb` dynamicznie w
katalogu `debian-build/` (sciezka konfigurowalna przez `[paths].deb_workdir`
w `config.hk`), na podstawie szablonow zdefiniowanych w
`scripts/deb_package.lua` (sekcja `POSTINST_TEMPLATE`, `PRERM_TEMPLATE`,
`POSTRM_TEMPLATE` oraz funkcja `generate_control`).

Ten katalog (`debian/`) sluzy jako miejsce na:

- `changelog.template` - szablon wpisu changeloga Debiana dla nowych wydan
  jadra (do recznego uzupelnienia przy wydaniach release, nie jest
  uzywany automatycznie przez `build.lua`)
- dokumentacje zasad pakietowania specyficznych dla HackerOS Kernel

Jesli chcesz na trwale zmienic zawartosc `postinst`/`prerm`/`control`,
edytuj szablony w `scripts/deb_package.lua` - tam jest jedyne miejsce
prawdy uzywane przez build system.
