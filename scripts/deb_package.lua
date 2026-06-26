--[[
    deb_package.lua

    Buduje DWA pakiety .deb:

    1) hackeros-kernel-cybersecurity  -- samo jadro (vmlinuz + moduly)
       postinst: runtime hardening (sysctl + GRUB_CMDLINE), initramfs,
                 grub update, GRUB rollback backup, usuwanie starego jadra
       prerm:    ostrzezenie przy usuwaniu aktywnego jadra
       postrm:   czyszczenie /boot + modules + sysctl.d konfig

    2) hackeros-kernel-headers-cybersecurity  -- naglowki dla DKMS / out-of-tree
       postinst: tworzenie dowiazania /usr/src/linux-headers-<ver>/build
--]]

local Utils = require("scripts.utils")
local RH    = require("scripts.runtime_hardening")
local Signing = require("scripts.signing")

local DebPackage = {}

-- ---------------------------------------------------------------------------
-- Szablony skryptow maintainera
-- ---------------------------------------------------------------------------

local POSTINST_TEMPLATE = [=[#!/bin/sh
# postinst: %PACKAGE_NAME% (HackerOS Kernel - cybersecurity)
set -e

KERNEL_RELEASE="%KERNEL_RELEASE%"

echo "=================================================================="
echo " HackerOS Kernel (%EDITION%) - postinst"
echo " Wersja: ${KERNEL_RELEASE}"
echo "=================================================================="

# --- 0. ROLLBACK BACKUP: zachowaj biezacy wpis GRUB zanim cokolwiek zmienimy ---
if [ "%POSTINST_GRUB_UPDATE%" = "true" ] && [ -f /boot/grub/grub.cfg ]; then
    BACKUP_DIR="/var/lib/hackeros-kernel"
    mkdir -p "${BACKUP_DIR}"
    BACKUP_FILE="${BACKUP_DIR}/grub.cfg.pre-$(date +%Y%m%d%H%M%S)"
    cp /boot/grub/grub.cfg "${BACKUP_FILE}" 2>/dev/null || true
    echo "[hackeros-kernel] Backup grub.cfg -> ${BACKUP_FILE}"
    # Zachowujemy takze liste zainstalowanych jader przed usuniecia
    dpkg -l 'linux-image-*' 2>/dev/null > "${BACKUP_DIR}/kernels-before-install.txt" || true
fi

# --- 1. Sysctl hardening (runtime_hardening) ---
if [ -f /etc/sysctl.d/99-hackeros-cybersec.conf ]; then
    echo "[hackeros-kernel] Ladowanie ustawien sysctl cybersecurity..."
    sysctl -p /etc/sysctl.d/99-hackeros-cybersec.conf 2>/dev/null || \
        echo "[hackeros-kernel] Ostrzezenie: sysctl -p nie powiodlo sie (ok przy pierwszym starcie)."
fi

# --- 2. GRUB_CMDLINE hardening: dopisujemy nasze boot params ---
if [ -f /usr/share/hackeros-kernel/cmdline-fragment.txt ] && [ -f /etc/default/grub ]; then
    HACKEROS_PARAMS="$(cat /usr/share/hackeros-kernel/cmdline-fragment.txt | tr -d '\n')"
    if [ -n "${HACKEROS_PARAMS}" ]; then
        if ! grep -q "hackeros_cmdline_applied" /etc/default/grub 2>/dev/null; then
            echo "[hackeros-kernel] Dodawanie parametrow startowych jadra do GRUB..."
            # Robimy backup /etc/default/grub przed modyfikacja
            cp /etc/default/grub /etc/default/grub.pre-hackeros 2>/dev/null || true
            sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${HACKEROS_PARAMS}\"|" \
                /etc/default/grub || true
            echo "# hackeros_cmdline_applied" >> /etc/default/grub
            echo "[hackeros-kernel] Parametry dodane: ${HACKEROS_PARAMS}"
        else
            echo "[hackeros-kernel] Parametry startowe juz zaaplikowane, pomijam."
        fi
    fi
fi

# --- 3. Usuwanie starych jader Debiana ---
if [ "%REMOVE_OLD_KERNEL%" = "true" ]; then
    echo "[hackeros-kernel] Usuwanie istniejacych jader Debiana..."
    CURRENT_RUNNING="$(uname -r 2>/dev/null || true)"
    for pkg in $(dpkg -l 2>/dev/null | awk '/^ii\s+linux-image-[0-9]/{print $2}'); do
        if [ "${pkg}" = "linux-image-${KERNEL_RELEASE}" ]; then
            continue
        fi
        echo "[hackeros-kernel] Usuwam: ${pkg}"
        DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge "${pkg}" 2>/dev/null || \
            echo "[hackeros-kernel] Ostrzezenie: nie udalo sie usunac ${pkg}."
    done
    for meta in linux-image-amd64 linux-image-generic; do
        if dpkg -l "${meta}" 2>/dev/null | grep -q '^ii'; then
            DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge "${meta}" 2>/dev/null || true
        fi
    done
fi

# --- 4. initramfs ---
echo "[hackeros-kernel] Generowanie initramfs dla ${KERNEL_RELEASE}..."
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -c -k "${KERNEL_RELEASE}" 2>/dev/null || \
    update-initramfs -u -k "${KERNEL_RELEASE}" || \
        echo "[hackeros-kernel] Ostrzezenie: update-initramfs nie powiodlo sie."
fi

# --- 5. GRUB update i ustawienie jako domyslne ---
if [ "%POSTINST_GRUB_UPDATE%" = "true" ]; then
    echo "[hackeros-kernel] Aktualizacja GRUB..."
    if command -v update-grub >/dev/null 2>&1; then
        update-grub || echo "[hackeros-kernel] Ostrzezenie: update-grub nie powiodlo sie."
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg || true
    fi

    if [ "%SET_DEFAULT%" = "true" ] && [ -f /boot/grub/grub.cfg ]; then
        ENTRY_TITLE="$(awk -F\' '/menuentry .*%KERNEL_RELEASE%/{print $2; exit}' \
            /boot/grub/grub.cfg 2>/dev/null || true)"
        if [ -n "${ENTRY_TITLE}" ] && command -v grub-set-default >/dev/null 2>&1; then
            grub-set-default "${ENTRY_TITLE}" || true
            update-grub 2>/dev/null || true
            echo "[hackeros-kernel] HackerOS Kernel ustawiony jako domyslny w GRUB."
        else
            echo "[hackeros-kernel] Nie udalo sie automatycznie ustawic domyslnego wpisu GRUB."
            echo "[hackeros-kernel] Ustaw recznie GRUB_DEFAULT w /etc/default/grub."
        fi
    fi
fi

# --- 6. Xen dom0 info ---
if dpkg -l 2>/dev/null | grep -qi 'xen-hypervisor'; then
    echo "[hackeros-kernel] Wykryto Xen Hypervisor - jadro skompilowane z CONFIG_XEN_DOM0=y."
fi

# --- 7. MOK enrollment info (jesli moduly sa podpisane) ---
if [ -f /usr/share/hackeros-kernel/signing-key/module-signing.crt ]; then
    echo "[hackeros-kernel] UWAGA: jadro wymaga podpisanych modulow."
    echo "[hackeros-kernel] Klucz publiczny do UEFI Secure Boot MOK enrollment:"
    echo "[hackeros-kernel]   /usr/share/hackeros-kernel/signing-key/module-signing.crt"
    echo "[hackeros-kernel] Aby zaladowac moduly out-of-tree, uzyj:"
    echo "[hackeros-kernel]   /usr/share/hackeros-kernel/hackeros-sign-module.sh <plik.ko>"
fi

echo "=================================================================="
echo " HackerOS Kernel ${KERNEL_RELEASE} zainstalowany pomyslnie."
echo " Zrestartuj system, aby uruchomic nowe jadro."
echo " Backup grub.cfg: /var/lib/hackeros-kernel/grub.cfg.pre-*"
echo "=================================================================="
exit 0
]=]

local PRERM_TEMPLATE = [=[#!/bin/sh
# prerm: %PACKAGE_NAME%
set -e

KERNEL_RELEASE="%KERNEL_RELEASE%"
RUNNING="$(uname -r 2>/dev/null || true)"

if [ "${RUNNING}" = "${KERNEL_RELEASE}" ]; then
    echo "[hackeros-kernel] UWAGA: usuwasz aktualnie uruchomione jadro ${KERNEL_RELEASE}."
    echo "[hackeros-kernel] Upewnij sie, ze masz inne jadro przed restartem."
    echo "[hackeros-kernel] Backup grub.cfg dostepny w /var/lib/hackeros-kernel/"
fi
exit 0
]=]

local POSTRM_TEMPLATE = [=[#!/bin/sh
# postrm: %PACKAGE_NAME%
set -e

KERNEL_RELEASE="%KERNEL_RELEASE%"

case "$1" in
    remove|purge)
        rm -f "/boot/vmlinuz-${KERNEL_RELEASE}"
        rm -f "/boot/System.map-${KERNEL_RELEASE}"
        rm -f "/boot/config-${KERNEL_RELEASE}"
        rm -f "/boot/initrd.img-${KERNEL_RELEASE}"
        rm -rf "/lib/modules/${KERNEL_RELEASE}"
        # Cofamy zmiany sysctl
        rm -f /etc/sysctl.d/99-hackeros-cybersec.conf
        # Cofamy zmiany GRUB_CMDLINE jesli nasz marker istnieje
        if grep -q "hackeros_cmdline_applied" /etc/default/grub 2>/dev/null; then
            if [ -f /etc/default/grub.pre-hackeros ]; then
                cp /etc/default/grub.pre-hackeros /etc/default/grub
                echo "[hackeros-kernel] Przywrocono /etc/default/grub z backupu."
            else
                sed -i '/# hackeros_cmdline_applied/d' /etc/default/grub 2>/dev/null || true
            fi
        fi
        if command -v update-grub >/dev/null 2>&1; then
            update-grub 2>/dev/null || true
        fi
        ;;
esac
exit 0
]=]

local HEADERS_POSTINST_TEMPLATE = [=[#!/bin/sh
# postinst: %HEADERS_PACKAGE_NAME%
set -e

KERNEL_RELEASE="%KERNEL_RELEASE%"
HDR_DIR="/usr/src/linux-headers-${KERNEL_RELEASE}"

if [ -d "${HDR_DIR}" ]; then
    echo "[hackeros-headers] Naglowki jadra ${KERNEL_RELEASE} zainstalowane w ${HDR_DIR}"
    # Tworzymy symlink /lib/modules/<ver>/build -> naglowki (wymagane przez DKMS)
    mkdir -p "/lib/modules/${KERNEL_RELEASE}"
    ln -sfn "${HDR_DIR}" "/lib/modules/${KERNEL_RELEASE}/build" || true
    echo "[hackeros-headers] Symlink: /lib/modules/${KERNEL_RELEASE}/build -> ${HDR_DIR}"
fi

# Konfiguracja DKMS (jesli zainstalowany)
if command -v dkms >/dev/null 2>&1; then
    echo "[hackeros-headers] Wykryto DKMS - moduly out-of-tree beda automatycznie"
    echo "[hackeros-headers] przebudowane dla jadra ${KERNEL_RELEASE}."
fi

echo "[hackeros-headers] Do podpisywania modulow out-of-tree uzywaj:"
echo "[hackeros-headers]   /usr/share/hackeros-kernel/hackeros-sign-module.sh <plik.ko>"
exit 0
]=]

-- ---------------------------------------------------------------------------
-- Pomocnicze: render szablonu
-- ---------------------------------------------------------------------------

local function render(tpl, vars)
    local result = tpl
    for k, v in pairs(vars) do
        result = result:gsub("%%" .. k .. "%%", tostring(v))
    end
    return result
end

-- ---------------------------------------------------------------------------
-- generate_control: plik DEBIAN/control
-- ---------------------------------------------------------------------------

local function join_csv(list)
    if not list then return "" end
    if type(list) == "string" then return list end
    return table.concat(list, ", ")
end

local function generate_control(cfg, kernel_release, installed_size_kb, is_headers)
    local pkg   = is_headers and cfg.headers_package or cfg.package
    local ver   = cfg.versioning
    local meta  = cfg.metadata

    local lines = {
        "Package: " .. pkg.name,
        "Version: " .. ver.deb_version,
        "Section: " .. (pkg.section or "kernel"),
        "Priority: " .. (pkg.priority or "optional"),
        "Architecture: " .. (cfg.package.architecture or "amd64"),
        "Maintainer: " .. meta.maintainer,
        "Installed-Size: " .. tostring(installed_size_kb or 0),
    }

    if pkg.depends and #pkg.depends > 0 then
        table.insert(lines, "Depends: " .. join_csv(pkg.depends))
    end
    if pkg.recommends and #pkg.recommends > 0 then
        table.insert(lines, "Recommends: " .. join_csv(pkg.recommends))
    end
    if not is_headers then
        if cfg.package.conflicts and #cfg.package.conflicts > 0 then
            table.insert(lines, "Conflicts: " .. join_csv(cfg.package.conflicts))
        end
        if cfg.package.replaces and #cfg.package.replaces > 0 then
            table.insert(lines, "Replaces: " .. join_csv(cfg.package.replaces))
        end
        if cfg.package.provides and #cfg.package.provides > 0 then
            table.insert(lines, "Provides: " .. join_csv(cfg.package.provides))
        end
    else
        -- headers package Provides/Replaces konwencja Debiana
        table.insert(lines, string.format(
            "Provides: linux-headers-%s", kernel_release))
    end

    table.insert(lines, "Homepage: " .. (meta.homepage or ""))
    local patch_count = cfg.patches and #cfg.patches.apply_order or 0
    local edition = (cfg.metadata and cfg.metadata.edition) or meta.branch
    local desc = is_headers
        and string.format("Naglowki jadra HackerOS Kernel %s (%s)\n"
            .. " Naglowki jadra dla %s.\n .\n Wymagane do budowania modulow"
            .. " out-of-tree (DKMS) dla HackerOS Kernel %s.",
            kernel_release, edition, kernel_release, edition)
        or string.format("%s (%s)\n %s\n .\n Jadro zoptymalizowane dla"
            .. " HackerOS %s Edition. Zawiera %d-patchowy"
            .. " patchset (cybersecurity + red team + ostree),"
            .. " wsparcie Xen dom0/domU, WiFi injection, USB HID emulation,"
            .. " Bluetooth HCI monitor, NFQUEUE MITM, OSTree/composefs"
            .. " oraz pelny hardening runtime (sysctl + GRUB_CMDLINE).",
            meta.name, meta.branch, meta.description, edition, patch_count)
    table.insert(lines, "Description: " .. desc)
    return table.concat(lines, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
-- build: glowny pakiet jadra
-- ---------------------------------------------------------------------------

function DebPackage.build(cfg, destdir, kernel_release, signing_key_path, signing_cert_path)
    local deb_root   = cfg.paths.deb_workdir
    local debian_dir = deb_root .. "/DEBIAN"

    Utils.log("Przygotowanie pakietu .deb: " .. cfg.package.name)
    Utils.rm_rf(deb_root)
    Utils.mkdir_p(debian_dir)

    Utils.run_or_die(
        string.format("cp -a '%s'/. '%s'/", destdir, deb_root))
    Utils.run("rm -rf '" .. debian_dir .. "'")
    Utils.mkdir_p(debian_dir)

    -- runtime hardening artefakty: sysctl.d conf + cmdline fragment
    RH.write_to_deb_root(cfg, deb_root)

    -- klucz podpisywania modulow (dla DKMS)
    if signing_key_path and signing_cert_path then
        Signing.install_for_dkms(cfg, deb_root, signing_key_path, signing_cert_path)
    end

    local size_kb = tonumber(
        Utils.capture(string.format("du -sk '%s' 2>/dev/null | cut -f1", deb_root))) or 0

    Utils.write_file(debian_dir .. "/control",
        generate_control(cfg, kernel_release, size_kb, false))

    local tpl_vars = {
        PACKAGE_NAME          = cfg.package.name,
        KERNEL_RELEASE        = kernel_release,
        REMOVE_OLD_KERNEL     = tostring(cfg.package.remove_old_kernel),
        POSTINST_GRUB_UPDATE  = tostring(cfg.package.postinst_grub_update),
        SET_DEFAULT           = tostring(cfg.package.set_default),
        EDITION               = (cfg.metadata and cfg.metadata.edition) or cfg.metadata.branch,
    }

    Utils.write_file(debian_dir .. "/postinst", render(POSTINST_TEMPLATE, tpl_vars))
    Utils.write_file(debian_dir .. "/prerm",    render(PRERM_TEMPLATE,    tpl_vars))
    Utils.write_file(debian_dir .. "/postrm",   render(POSTRM_TEMPLATE,   tpl_vars))
    for _, s in ipairs({"postinst", "prerm", "postrm"}) do
        Utils.run("chmod 0755 '" .. debian_dir .. "/" .. s .. "'")
    end

    Utils.run("find '" .. deb_root .. "' -not -path '" .. debian_dir .. "/*'" ..
              " -not -name '*.sh' -type f -exec chmod 0644 {} +")
    Utils.run("find '" .. deb_root .. "' -type d -exec chmod 0755 {} +")
    Utils.run("chmod 0755 '" .. debian_dir .. "/postinst' '" ..
              debian_dir .. "/prerm' '" .. debian_dir .. "/postrm'")

    -- uprawnienia klucza prywatnego - musi byc 0600 (nie nadpisywac)
    local sign_pem = deb_root .. "/usr/share/hackeros-kernel/signing-key/module-signing.pem"
    if Utils.file_exists(sign_pem) then
        Utils.run("chmod 0600 '" .. sign_pem .. "'")
    end

    Utils.mkdir_p(cfg.build.output)
    local output_path = cfg.paths.output_deb
    Utils.log("Pakowanie .deb -> " .. output_path)
    Utils.run_or_die(
        string.format("dpkg-deb --root-owner-group --build '%s' '%s'",
            deb_root, output_path))
    Utils.ok("Pakiet jadra: " .. output_path)

    if cfg.signing.sign_package and cfg.signing.gpg_key_id ~= "" then
        Utils.run(string.format("dpkg-sig -k '%s' --sign builder '%s'",
            cfg.signing.gpg_key_id, output_path))
    end

    return output_path
end

-- ---------------------------------------------------------------------------
-- build_headers: odrebny pakiet naglowkow
-- ---------------------------------------------------------------------------

function DebPackage.build_headers(cfg, headers_destdir, kernel_release)
    if not (cfg.headers_package and cfg.headers_package.enabled) then
        Utils.info("Pakiet naglowkow wylaczony w config.hk.")
        return nil
    end

    local deb_root   = cfg.paths.headers_deb_workdir or (cfg.paths.deb_workdir .. "-headers")
    local debian_dir = deb_root .. "/DEBIAN"

    Utils.log("Przygotowanie pakietu naglowkow: " .. cfg.headers_package.name)
    Utils.rm_rf(deb_root)
    Utils.mkdir_p(debian_dir)

    Utils.run_or_die(
        string.format("cp -a '%s'/. '%s'/", headers_destdir, deb_root))
    Utils.run("rm -rf '" .. debian_dir .. "'")
    Utils.mkdir_p(debian_dir)

    local size_kb = tonumber(
        Utils.capture(string.format("du -sk '%s' 2>/dev/null | cut -f1", deb_root))) or 0

    Utils.write_file(debian_dir .. "/control",
        generate_control(cfg, kernel_release, size_kb, true))

    local hdr_vars = {
        HEADERS_PACKAGE_NAME = cfg.headers_package.name,
        KERNEL_RELEASE       = kernel_release,
    }
    Utils.write_file(debian_dir .. "/postinst",
        render(HEADERS_POSTINST_TEMPLATE, hdr_vars))
    Utils.run("chmod 0755 '" .. debian_dir .. "/postinst'")

    Utils.mkdir_p(cfg.build.output)
    local output_path = cfg.paths.output_headers_deb
    Utils.log("Pakowanie headers .deb -> " .. output_path)
    Utils.run_or_die(
        string.format("dpkg-deb --root-owner-group --build '%s' '%s'",
            deb_root, output_path))
    Utils.ok("Pakiet naglowkow: " .. output_path)

    return output_path
end

return DebPackage
