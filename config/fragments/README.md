# config/fragments/

Ten katalog moze zawierac dodatkowe fragmenty `.config` (pliki `*.config`)
ktore zostana automatycznie scalone przez `build.lua` z konfiguracja bazowa
(`config/base.config`) oraz z fragmentem auto-generowanym z `config.hk`
(hardening / Xen / cybersecurity_subsystems).

Pliki sa scalane w kolejnosci alfabetycznej, **po** fragmencie
`hackeros-cybersecurity.config` generowanym automatycznie, wiec mozesz
tutaj nadpisac wybrane opcje dla swojego sprzetu (np. konkretny sterownik
WiFi do wstrzykiwania pakietow, dodatkowy modul TPM, etc.).

Przykladowy fragment (`my-wifi-card.config`):

```
CONFIG_RTL8812AU=m
CONFIG_RT2800USB=y
```

Pliki w tym katalogu nie sa wersjonowane w glownym `config.hk` - sa
czysto opcjonalnym mechanizmem rozszerzania konfiguracji bez modyfikacji
`config/base.config`.
