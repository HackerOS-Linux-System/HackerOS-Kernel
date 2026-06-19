--[[
    runtime_hardening.lua

    Generuje artefakty "runtime hardeningu" - czyli ustawien ktore NIE sa
    CONFIG_* wkompilowane w jadro, a parametrami przekazywanymi przez
    bootloader (GRUB_CMDLINE_LINUX_DEFAULT) i regulami sysctl wgrywanymi
    do /etc/sysctl.d/. To jest celowo odrebna warstwa od patches.lua/kconfig.lua:

      - sysctl i boot param sa OFICJALNYMI, DOKUMENTOWANYMI interfejsami ABI
        Linuksa, ktore nie zmieniaja sie miedzy wersjami tak jak linie kodu
        w srodku plikow .c - dlatego sa duzo bardziej odpowiednim miejscem
        do wymuszania "miekkich" wartosci domyslnych niz patche C.
      - W przeciwienstwie do patchy, te ustawienia moga zostac swiadomie
        nadpisane przez administratora po instalacji (np. zmieniajac
        /etc/sysctl.d/99-hackeros-cybersec.conf), co jest pozadanym
        zachowaniem - hardening "z pudelka", ale nie "zabetonowany".

    Wyjsciowe pliki generowane sa do katalogu deb_root podczas budowy
    pakietu .deb (wywolywane z deb_package.lua), tak by trafily do
    odpowiednich miejsc w systemie plikow po dpkg -i.
--]]

local Utils = require("scripts.utils")

local RuntimeHardening = {}

--- Generuje pojedynczy string z GRUB_CMDLINE_LINUX_DEFAULT na podstawie
-- [runtime_hardening].boot_params z config.hk.
-- Bool "true"/"false" w configu sa traktowane jako "wlacz/wylacz flage
-- bez wartosci" (np. slab_nomerge), inne typy sa renderowane jako klucz=wartosc.
function RuntimeHardening.render_cmdline_params(cfg)
    local boot_params = cfg.runtime_hardening and cfg.runtime_hardening.boot_params
    if not boot_params then
        return ""
    end

    -- sortujemy klucze, zeby wyjscie bylo deterministyczne (latwiejsze do
    -- code review i diffowania miedzy buildami)
    local keys = {}
    for k in pairs(boot_params) do table.insert(keys, k) end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        local value = boot_params[key]
        if value == true then
            table.insert(parts, key)
        elseif value == false then
            -- false = flaga jawnie wylaczona, pomijamy w cmdline
        else
            table.insert(parts, key .. "=" .. tostring(value))
        end
    end

    return table.concat(parts, " ")
end

--- Generuje zawartosc pliku /etc/sysctl.d/99-hackeros-cybersec.conf na
-- podstawie [runtime_hardening].sysctl z config.hk.
function RuntimeHardening.render_sysctl_conf(cfg)
    local sysctl = cfg.runtime_hardening and cfg.runtime_hardening.sysctl
    if not sysctl then
        return nil
    end

    local keys = {}
    for k in pairs(sysctl) do table.insert(keys, k) end
    table.sort(keys)

    local lines = {
        "# =========================================================",
        "# /etc/sysctl.d/99-hackeros-cybersec.conf",
        "# Auto-generowany przez HackerOS Kernel build.lua",
        "# (scripts/runtime_hardening.lua na podstawie config.hk)",
        "#",
        "# To sa wartosci domyslne dla HackerOS Cybersecurity Edition.",
        "# Mozesz je bezpiecznie nadpisac wlasnym plikiem w /etc/sysctl.d/",
        "# z wyzszym numerem (np. 99-local-overrides.conf), ktory zaladuje",
        "# sie po tym pliku.",
        "# =========================================================",
        "",
    }

    for _, key in ipairs(keys) do
        table.insert(lines, string.format("%s = %s", key, tostring(sysctl[key])))
    end

    table.insert(lines, "")
    return table.concat(lines, "\n")
end

--- Zapisuje wygenerowane artefakty do struktury pakietu .deb (deb_root).
-- Tworzy:
--   etc/sysctl.d/99-hackeros-cybersec.conf
--   usr/share/hackeros-kernel/cmdline-fragment.txt  (uzywane przez postinst
--     do dopisania do GRUB_CMDLINE_LINUX_DEFAULT bez nadpisywania reszty)
function RuntimeHardening.write_to_deb_root(cfg, deb_root)
    local sysctl_content = RuntimeHardening.render_sysctl_conf(cfg)
    if sysctl_content then
        Utils.mkdir_p(deb_root .. "/etc/sysctl.d")
        Utils.write_file(deb_root .. "/etc/sysctl.d/99-hackeros-cybersec.conf", sysctl_content)
        Utils.ok("Wygenerowano /etc/sysctl.d/99-hackeros-cybersec.conf")
    end

    local cmdline_fragment = RuntimeHardening.render_cmdline_params(cfg)
    if cmdline_fragment ~= "" then
        Utils.mkdir_p(deb_root .. "/usr/share/hackeros-kernel")
        Utils.write_file(deb_root .. "/usr/share/hackeros-kernel/cmdline-fragment.txt",
            cmdline_fragment .. "\n")
        Utils.ok("Wygenerowano fragment GRUB_CMDLINE: " .. cmdline_fragment)
    end

    return cmdline_fragment, sysctl_content
end

return RuntimeHardening
