--[[
    signing.lua

    Realizuje punkty 2 i 3 z listy rozbudowy: generuje wlasna, trwala pare
    kluczy X.509 (RSA) uzywana do podpisywania modulow jadra, zamiast
    pozwolic kernelowi wygenerowac jednorazowy klucz "certs/signing_key.pem"
    przy kazdym buildzie (co jest domyslnym zachowaniem upstreamu gdy
    CONFIG_MODULE_SIG_KEY nie jest jawnie ustawiony na trwala sciezke).

    Dlaczego to ma znaczenie:
      - jesli klucz jest generowany na nowo przy kazdym buildzie, moduly
        out-of-tree (np. budowane recznie albo przez DKMS PO instalacji
        jadra) nie majq czym zostac podpisane zgodnie z kluczem juz
        zaszytym w jadrze -> przy module_sig_force=true odmowa wczytania.
      - eksportujac klucz publiczny i prywatny do stabilnej lokalizacji
        (config.hk: [signing].keys_dir), DKMS (lub administrator) moze
        uzyc tego samego klucza prywatnego do podpisania nowych modulow
        po fakcie, zgodnie z tym samym zaufanym keyringiem.

    Wymaga: openssl (sprawdzane w build.lua check_dependencies).
--]]

local Utils = require("scripts.utils")

local Signing = {}

--- Generuje (jesli jeszcze nie istnieje) pare kluczy X.509 RSA do
-- podpisywania modulow, w formacie wymaganym przez CONFIG_MODULE_SIG_KEY
-- (jeden plik PEM zawierajacy zarowno klucz prywatny jak i certyfikat).
-- @return path do pliku combined .pem, path do samego certyfikatu .der/.pem
function Signing.ensure_module_signing_key(cfg)
    local signing_cfg = cfg.signing
    local keys_dir = signing_cfg.keys_dir or "./build/keys"

    Utils.mkdir_p(keys_dir)

    local priv_key_path = keys_dir .. "/hackeros-signing-key.priv"
    local cert_path      = keys_dir .. "/hackeros-signing-key.crt"
    local combined_path  = keys_dir .. "/hackeros-signing-key.pem"

    if Utils.file_exists(combined_path) and Utils.file_exists(priv_key_path) then
        Utils.ok("Klucz podpisywania modulow juz istnieje: " .. combined_path)
        return combined_path, cert_path
    end

    Utils.log("Generowanie nowej pary kluczy X.509 do podpisywania modulow jadra...")

    local cn = signing_cfg.key_cn or "HackerOS Kernel Module Signing"
    local days = tostring(signing_cfg.key_days_valid or 3650)

    -- generujemy w jednym poleceniu klucz RSA 4096 + self-signed cert,
    -- zgodnie z oficjalnym przepisem z dokumentacji kernela
    -- (docs.kernel.org/admin-guide/module-signing.html) - uzywamy -addext
    -- zamiast osobnego pliku x509.genkey, zeby nie zalezec od configu
    -- openssl dostarczanego przez dystrybucje (moze nie istniec/byc inny).
    local subj = string.format("/CN=%s/O=HackerOS Linux System/OU=cybersecurity-branch", cn)

    local cmd = string.format(
        "openssl req -new -nodes -utf8 -sha512 -days %s -batch -x509 " ..
        "-subj '%s' " ..
        "-addext 'basicConstraints=critical,CA:FALSE' " ..
        "-addext 'keyUsage=digitalSignature' " ..
        "-addext 'extendedKeyUsage=codeSigning' " ..
        "-newkey rsa:4096 -keyout '%s' -out '%s' 2>&1",
        days, subj, priv_key_path, cert_path)

    local ok = Utils.run(cmd)
    if not ok then
        Utils.die("Nie udalo sie wygenerowac klucza podpisywania modulow (openssl).")
    end

    -- CONFIG_MODULE_SIG_KEY oczekuje jednego pliku z kluczem prywatnym
    -- i certyfikatem polaczonymi (tak jak certs/signing_key.pem w jadrze)
    local priv_content = Utils.read_file(priv_key_path)
    local cert_content  = Utils.read_file(cert_path)

    if not priv_content or not cert_content then
        Utils.die("Wygenerowano klucz, ale nie udalo sie odczytac plikow do polaczenia w PEM.")
    end

    Utils.write_file(combined_path, priv_content .. cert_content)
    Utils.run("chmod 0600 '" .. priv_key_path .. "' '" .. combined_path .. "'")
    Utils.run("chmod 0644 '" .. cert_path .. "'")

    Utils.ok("Wygenerowano klucz podpisywania modulow: " .. combined_path)
    Utils.info("Certyfikat publiczny (do dystrybucji/MOK enrollment): " .. cert_path)

    return combined_path, cert_path
end

--- Wstrzykuje CONFIG_MODULE_SIG_KEY do .config wewnatrz drzewa zrodel,
-- wskazujac na wygenerowany klucz (sciezka absolutna, zeby dzialalo
-- niezaleznie od katalogu roboczego w czasie make).
function Signing.inject_into_kernel_config(cfg, kernel_src_path, combined_key_path)
    if not cfg.hardening.module_sig then
        Utils.info("hardening.module_sig=false - pomijam wstrzykiwanie CONFIG_MODULE_SIG_KEY.")
        return
    end

    local abs_path = Utils.capture("readlink -f '" .. combined_key_path .. "'") or combined_key_path
    local config_path = kernel_src_path .. "/.config"

    if not Utils.file_exists(config_path) then
        Utils.warn(".config jeszcze nie istnieje w drzewie zrodel - CONFIG_MODULE_SIG_KEY zostanie ustawiony po merge_config.")
        return
    end

    -- usuwamy ewentualny istniejacy wpis i dodajemy nasz, zeby uniknac duplikatow
    local content = Utils.read_file(config_path) or ""
    content = content:gsub("CONFIG_MODULE_SIG_KEY=.-\n", "")
    content = content .. string.format('CONFIG_MODULE_SIG_KEY="%s"\n', abs_path)
    content = content .. 'CONFIG_MODULE_SIG_KEY_TYPE_RSA=y\n'

    Utils.write_file(config_path, content)
    Utils.ok("Wstrzykniety CONFIG_MODULE_SIG_KEY=" .. abs_path)
end

--- Kopiuje klucz prywatny + certyfikat + skrypt pomocniczy do struktury
-- pakietu .deb, tak aby po instalacji administrator (lub DKMS) mogl
-- podpisywac nowe moduly out-of-tree tym samym kluczem.
-- Trafia do /usr/share/hackeros-kernel/signing-key/ (tylko root ma odczyt
-- klucza prywatnego - krytyczne, bo wyciek klucza pozwala podpisac
-- zlosliwy modul jako "zaufany" przez ten kernel).
function Signing.install_for_dkms(cfg, deb_root, combined_key_path, cert_path)
    if not cfg.signing.install_key_for_dkms then
        return
    end
    if not cfg.hardening.module_sig then
        return
    end

    local dest_dir = deb_root .. "/usr/share/hackeros-kernel/signing-key"
    Utils.mkdir_p(dest_dir)

    Utils.run(string.format("cp '%s' '%s/module-signing.pem'", combined_key_path, dest_dir))
    Utils.run(string.format("cp '%s' '%s/module-signing.crt'", cert_path, dest_dir))

    -- skrypt pomocniczy wywolywany przez DKMS post-build hook (kernel.conf)
    local sign_helper = [[#!/bin/sh
# Podpisuje modul jadra (.ko) kluczem HackerOS Kernel Module Signing.
# Uzycie: hackeros-sign-module.sh /sciezka/do/modulu.ko
set -e

KEY="/usr/share/hackeros-kernel/signing-key/module-signing.pem"
MODULE="$1"

if [ -z "${MODULE}" ]; then
    echo "Uzycie: $0 <plik.ko>" >&2
    exit 1
fi

if [ ! -r "${KEY}" ]; then
    echo "hackeros-sign-module: brak klucza podpisywania w ${KEY}" >&2
    exit 1
fi

SIGN_FILE="/usr/src/linux-headers-$(uname -r)/scripts/sign-file"
if [ ! -x "${SIGN_FILE}" ]; then
    # fallback - czesc dystrybucji trzyma sign-file w innym katalogu
    SIGN_FILE="$(find /usr/src -maxdepth 3 -name sign-file -type f 2>/dev/null | head -n1)"
fi

if [ -z "${SIGN_FILE}" ] || [ ! -x "${SIGN_FILE}" ]; then
    echo "hackeros-sign-module: nie znaleziono scripts/sign-file w naglowkach jadra" >&2
    echo "Zainstaluj pakiet hackeros-kernel-headers-cybersecurity." >&2
    exit 1
fi

"${SIGN_FILE}" sha512 "${KEY}" "${KEY}" "${MODULE}"
echo "hackeros-sign-module: podpisano ${MODULE}"
]]

    Utils.write_file(dest_dir .. "/../hackeros-sign-module.sh", sign_helper)
    Utils.run("chmod 0755 '" .. dest_dir .. "/../hackeros-sign-module.sh'")

    -- klucz prywatny - dostepny tylko dla root (DKMS dziala jako root przy buildzie)
    Utils.run("chmod 0600 '" .. dest_dir .. "/module-signing.pem'")
    Utils.run("chmod 0644 '" .. dest_dir .. "/module-signing.crt'")

    Utils.ok("Klucz podpisywania i skrypt hackeros-sign-module.sh dodane do pakietu (dla DKMS/out-of-tree).")
end

return Signing
