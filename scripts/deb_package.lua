--[[
    deb_package.lua

    Buduje finalny pakiet .deb HackerOS Kernel:
      - tworzy strukture katalogow debian-build/DEBIAN, /boot, /lib/modules
      - generuje plik control, postinst, prerm, postrm
      - postinst: usuwa stare jadro Debiana, ustawia HackerOS Kernel jako
        domyslny (update-grub + grub-set-default / update-initramfs)
      - pakuje wszystko przy pomocy dpkg-deb
--]]

local Utils = require("scripts.utils")

local DebPackage = {}

local POSTINST_TEMPLATE = [[#!/bin/sh
# postinst skryptu pakietu %PACKAGE_NAME% (HackerOS Kernel - cybersecurity)
set -e

KERNEL_RELEASE="%KERNEL_RELEASE%"
KERNEL_SUFFIX="%KERNEL_SUFFIX%"

echo "=================================================================="
echo " HackerOS Kernel (branch: cybersecurity) - instalacja jadra"
echo " Wersja: ${KERNEL_RELEASE}"
echo "=================================================================="

# --- 1. Usuniecie aktualnego/domyslnego jadra Debiana (jesli obecne) ---
if [ "%REMOVE_OLD_KERNEL%" = "true" ]; then
    echo "[hackeros-kernel] Wykrywanie istniejacych jader Debiana do usuniecia..."
    CURRENT_RUNNING_KERNEL="$(uname -r || true)"

    for pkg in $(dpkg -l 2>/dev/null | awk '/^ii\s+linux-image-[0-9]/ {print $2}'); do
        if [ "${pkg}" != "linux-image-${KERNEL_RELEASE}" ]; then
            echo "[hackeros-kernel] Usuwam stary pakiet jadra: ${pkg}"
            DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge "${pkg}" || \
                echo "[hackeros-kernel] Ostrzezenie: nie udalo sie usunac ${pkg} (kontynuuje)."
        fi
    done

    for metapkg in linux-image-amd64 linux-image-generic; do
        if dpkg -l "${metapkg}" 2>/dev/null | grep -q '^ii'; then
            echo "[hackeros-kernel] Usuwam metapakiet: ${metapkg}"
            DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge "${metapkg}" || true
        fi
    done
fi

# --- 2. Rejestracja nowego jadra w initramfs ---
echo "[hackeros-kernel] Generowanie initramfs dla ${KERNEL_RELEASE}..."
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -c -k "${KERNEL_RELEASE}" || \
        update-initramfs -u -k "${KERNEL_RELEASE}"
else
    echo "[hackeros-kernel] Ostrzezenie: update-initramfs niedostepny."
fi

# --- 3. Aktualizacja GRUB i ustawienie HackerOS Kernel jako domyslnego ---
if [ "%POSTINST_GRUB_UPDATE%" = "true" ]; then
    echo "[hackeros-kernel] Aktualizacja konfiguracji GRUB..."
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        echo "[hackeros-kernel] Ostrzezenie: brak update-grub/grub-mkconfig - skonfiguruj bootloader recznie."
    fi

    if [ "%SET_DEFAULT%" = "true" ] && command -v grep >/dev/null 2>&1; then
        echo "[hackeros-kernel] Ustawianie HackerOS Kernel jako domyslnego wpisu GRUB..."
        ENTRY_TITLE="$(awk -F\' '/menuentry .*'"${KERNEL_RELEASE}"'/ {print $2; exit}' /boot/grub/grub.cfg 2>/dev/null || true)"
        if [ -n "${ENTRY_TITLE}" ] && command -v grub-set-default >/dev/null 2>&1; then
            grub-set-default "${ENTRY_TITLE}" || true
            update-grub || true
        else
            echo "[hackeros-kernel] Nie udalo sie automatycznie ustawic wpisu domyslnego - sprawdz GRUB_DEFAULT w /etc/default/grub."
        fi
    fi
fi

# --- 4. Informacja o Xen (jesli obecny w systemie, jak w HackerOS Cybersecurity Edition) ---
if dpkg -l 2>/dev/null | grep -qi 'xen-hypervisor'; then
    echo "[hackeros-kernel] Wykryto Xen Hypervisor w systemie."
    echo "[hackeros-kernel] HackerOS Kernel zostal skompilowany z CONFIG_XEN_DOM0=y - mozesz uzywac go jako dom0."
fi

echo "=================================================================="
echo " HackerOS Kernel ${KERNEL_RELEASE} zainstalowany i ustawiony jako domyslny."
echo " Zrestartuj system, aby uruchomic nowe jadro."
echo "=================================================================="

exit 0
]]

local PRERM_TEMPLATE = [[#!/bin/sh
# prerm skryptu pakietu %PACKAGE_NAME%
set -e

KERNEL_RELEASE="%KERNEL_RELEASE%"
RUNNING_KERNEL="$(uname -r || true)"

if [ "${RUNNING_KERNEL}" = "${KERNEL_RELEASE}" ]; then
    echo "[hackeros-kernel] UWAGA: usuwasz aktualnie dzialajace jadro (${KERNEL_RELEASE})."
    echo "[hackeros-kernel] Upewnij sie, ze masz zainstalowane inne dzialajace jadro przed restartem."
fi

exit 0
]]

local POSTRM_TEMPLATE = [[#!/bin/sh
# postrm skryptu pakietu %PACKAGE_NAME%
set -e

KERNEL_RELEASE="%KERNEL_RELEASE%"

case "$1" in
    remove|purge)
        rm -f "/boot/vmlinuz-${KERNEL_RELEASE}"
        rm -f "/boot/System.map-${KERNEL_RELEASE}"
        rm -f "/boot/config-${KERNEL_RELEASE}"
        rm -f "/boot/initrd.img-${KERNEL_RELEASE}"
        rm -rf "/lib/modules/${KERNEL_RELEASE}"
        if command -v update-grub >/dev/null 2>&1; then
            update-grub || true
        fi
        ;;
esac

exit 0
]]

local function render_template(tpl, vars)
    local result = tpl
    for k, v in pairs(vars) do
        result = result:gsub("%%" .. k .. "%%", tostring(v))
    end
    return result
end

--- Generuje plik DEBIAN/control
local function generate_control(cfg, kernel_release, installed_size_kb)
    local pkg = cfg.package
    local ver = cfg.versioning

    local function join_csv(list)
        if not list then return "" end
        return table.concat(list, ", ")
    end

    local lines = {
        "Package: " .. pkg.name,
        "Version: " .. ver.deb_version,
        "Section: " .. pkg.section,
        "Priority: " .. pkg.priority,
        "Architecture: " .. pkg.architecture,
        "Maintainer: " .. cfg.metadata.maintainer,
        "Installed-Size: " .. tostring(installed_size_kb or 0),
    }

    if pkg.depends and #pkg.depends > 0 then
        table.insert(lines, "Depends: " .. join_csv(pkg.depends))
    end
    if pkg.recommends and #pkg.recommends > 0 then
        table.insert(lines, "Recommends: " .. join_csv(pkg.recommends))
    end
    if pkg.conflicts and #pkg.conflicts > 0 then
        table.insert(lines, "Conflicts: " .. join_csv(pkg.conflicts))
    end
    if pkg.replaces and #pkg.replaces > 0 then
        table.insert(lines, "Replaces: " .. join_csv(pkg.replaces))
    end
    if pkg.provides and #pkg.provides > 0 then
        table.insert(lines, "Provides: " .. join_csv(pkg.provides))
    end

    table.insert(lines, "Homepage: " .. (cfg.metadata.homepage or ""))
    table.insert(lines, string.format(
        "Description: %s (%s)\n %s\n .\n This kernel is built specifically for the HackerOS Cybersecurity Edition,\n featuring hardened security defaults, Xen dom0 support, and extended\n forensics/monitoring subsystems.",
        cfg.metadata.name, cfg.metadata.branch, cfg.metadata.description))

    return table.concat(lines, "\n") .. "\n"
end

--- Glowna funkcja budujaca .deb. destdir to katalog gdzie compile.lua
-- juz wczesniej zainstalowal /boot i /lib/modules.
function DebPackage.build(cfg, destdir, kernel_release)
    local deb_root = cfg.paths.deb_workdir
    local debian_dir = deb_root .. "/DEBIAN"

    Utils.log("Przygotowywanie struktury pakietu .deb w " .. deb_root .. " ...")

    -- czysty start
    Utils.rm_rf(deb_root)
    Utils.mkdir_p(debian_dir)

    -- kopiujemy zawartosc destdir (boot/, lib/modules/) do korzenia pakietu
    Utils.run_or_die(
        string.format("cp -a '%s'/. '%s'/", destdir, deb_root),
        "Nie udalo sie skopiowac plikow jadra do struktury pakietu .deb.")

    -- usuwamy ewentualny DEBIAN skopiowany przypadkiem (nie powinien istniec, ale na wszelki wypadek)
    Utils.run("rm -rf '" .. debian_dir .. "'")
    Utils.mkdir_p(debian_dir)

    local size_output = Utils.capture(string.format("du -sk '%s' 2>/dev/null | cut -f1", deb_root))
    local installed_size = tonumber(size_output) or 0

    -- control
    local control_content = generate_control(cfg, kernel_release, installed_size)
    Utils.write_file(debian_dir .. "/control", control_content)

    local template_vars = {
        PACKAGE_NAME         = cfg.package.name,
        KERNEL_RELEASE        = kernel_release,
        KERNEL_SUFFIX         = cfg.versioning.kernel_suffix,
        REMOVE_OLD_KERNEL     = tostring(cfg.package.remove_old_kernel),
        POSTINST_GRUB_UPDATE  = tostring(cfg.package.postinst_grub_update),
        SET_DEFAULT           = tostring(cfg.package.set_default),
    }

    -- postinst / prerm / postrm
    Utils.write_file(debian_dir .. "/postinst", render_template(POSTINST_TEMPLATE, template_vars))
    Utils.write_file(debian_dir .. "/prerm", render_template(PRERM_TEMPLATE, template_vars))
    Utils.write_file(debian_dir .. "/postrm", render_template(POSTRM_TEMPLATE, template_vars))

    Utils.run_or_die("chmod 0755 '" .. debian_dir .. "/postinst'")
    Utils.run_or_die("chmod 0755 '" .. debian_dir .. "/prerm'")
    Utils.run_or_die("chmod 0755 '" .. debian_dir .. "/postrm'")

    -- finalne uprawnienia plikow pakietu
    Utils.run("find '" .. deb_root .. "' -path '" .. debian_dir .. "' -prune -o -type f -print0 | xargs -0 -r chmod 0644")
    Utils.run("find '" .. deb_root .. "' -path '" .. debian_dir .. "' -prune -o -type d -print0 | xargs -0 -r chmod 0755")

    Utils.mkdir_p(cfg.build.output)
    local output_path = cfg.paths.output_deb

    Utils.log("Pakowanie pakietu .deb (dpkg-deb)...")
    Utils.run_or_die(
        string.format("dpkg-deb --root-owner-group --build '%s' '%s'", deb_root, output_path),
        "dpkg-deb nie powiodlo sie - sprawdz uprawnienia i strukture pakietu.")

    Utils.ok("Pakiet .deb wygenerowany: " .. output_path)

    if cfg.signing and cfg.signing.sign_package and cfg.signing.gpg_key_id ~= "" then
        Utils.info("Podpisywanie pakietu GPG kluczem: " .. cfg.signing.gpg_key_id)
        Utils.run(string.format("dpkg-sig -k '%s' --sign builder '%s'",
            cfg.signing.gpg_key_id, output_path))
    end

    return output_path
end

return DebPackage
