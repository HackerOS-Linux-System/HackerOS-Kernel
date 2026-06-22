--[[
    kconfig.lua

    Tlumaczy wysokopoziomowe flagi z config.hk (sekcje [hardening], [xen],
    [cybersecurity_subsystems]) na fragmenty pliku .config jadra Linux
    (CONFIG_* = y/n), a nastepnie scala je z base_config przy pomocy
    "scripts/kconfig/merge_config.sh" dostarczanego przez same zrodla jadra.
--]]

local Utils = require("scripts.utils")

local Kconfig = {}

-- mapowanie: klucz w [hardening] -> {CONFIG_NAZWA, "y"/"n", komentarz}
-- wartosc boolean z config.hk decyduje czy ustawiamy "y" (true) czy "n" (false)
local HARDENING_MAP = {
    kaslr                   = { "CONFIG_RANDOMIZE_BASE" },
    stack_protector_strong  = { "CONFIG_STACKPROTECTOR_STRONG" },
    fortify_source           = { "CONFIG_FORTIFY_SOURCE" },
    randomize_kstack_offset  = { "CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT" },
    slab_freelist_hardened   = { "CONFIG_SLAB_FREELIST_HARDENED" },
    page_table_isolation     = { "CONFIG_PAGE_TABLE_ISOLATION" },
    retpoline                 = { "CONFIG_RETPOLINE" },
    module_sig                = { "CONFIG_MODULE_SIG" },
    module_sig_force          = { "CONFIG_MODULE_SIG_FORCE" },
    bpf_jit_hardening         = { "CONFIG_BPF_JIT_ALWAYS_ON" },
    debug_fs                  = { "CONFIG_DEBUG_FS" },
    dev_mem                   = { "CONFIG_DEVMEM" },
    kexec                     = { "CONFIG_KEXEC" },
    seccomp                   = { "CONFIG_SECCOMP" },
    selinux                   = { "CONFIG_SECURITY_SELINUX" },
    apparmor                  = { "CONFIG_SECURITY_APPARMOR" },
    audit                     = { "CONFIG_AUDIT" },
    integrity_appraisal       = { "CONFIG_INTEGRITY" },
}

local XEN_MAP = {
    enabled         = { "CONFIG_XEN" },
    dom0_support    = { "CONFIG_XEN_DOM0" },
    domu_support    = { "CONFIG_XEN_GUEST" },
    pv_support      = { "CONFIG_XEN_PV" },
    hvm_support     = { "CONFIG_XEN_PVHVM" },
    pci_passthrough = { "CONFIG_XEN_PCIDEV_FRONTEND" },
    blkback         = { "CONFIG_XEN_BLKDEV_BACKEND" },
    netback         = { "CONFIG_XEN_NETDEV_BACKEND" },
}

local CYBERSEC_MAP = {
    netfilter_full       = { "CONFIG_NETFILTER" },
    nf_tables             = { "CONFIG_NF_TABLES" },
    packet_socket         = { "CONFIG_PACKET" },
    usb_monitor           = { "CONFIG_USB_MON" },
    tcp_md5               = { "CONFIG_TCP_MD5SIG" },
    wireless_injection    = { "CONFIG_CFG80211_WEXT" },
    bluetooth_monitor      = { "CONFIG_BT_HCIBTUSB" },
    ebpf_tracing           = { "CONFIG_BPF_SYSCALL" },
    kprobes                = { "CONFIG_KPROBES" },
    ftrace                 = { "CONFIG_FUNCTION_TRACER" },
    crypto_user_api        = { "CONFIG_CRYPTO_USER_API" },
    dm_crypt               = { "CONFIG_DM_CRYPT" },
    dm_verity              = { "CONFIG_DM_VERITY" },
    tpm_support             = { "CONFIG_TCG_TPM" },
    ima_evm                 = { "CONFIG_IMA" },
}

local function bool_to_config_value(b)
    return b and "y" or "n"
end

local function append_entries(lines, map, section_table)
    if not section_table then return end
    for key, mapping in pairs(map) do
        local value = section_table[key]
        if value ~= nil then
            local config_name = mapping[1]
            if value == true or value == false then
                table.insert(lines, string.format("%s=%s", config_name, bool_to_config_value(value)))
            else
                -- np. lockdown_mode = "confidentiality" -> traktowane osobno gdzie indziej
                table.insert(lines, string.format("# %s -> wartosc niestandardowa: %s", config_name, tostring(value)))
            end
        end
    end
end

--- Generuje plik fragmentu .config na podstawie sekcji config.hk
-- @return path do wygenerowanego pliku fragmentu
function Kconfig.generate_fragment(cfg, fragments_dir)
    Utils.mkdir_p(fragments_dir)
    local frag_path = fragments_dir .. "/hackeros-cybersecurity.config"

    local lines = {
        "# =========================================================",
        "# Auto-generowany fragment .config - HackerOS Kernel",
        "# Branch: cybersecurity",
        "# Wygenerowano przez kconfig.lua na podstawie config.hk",
        "# =========================================================",
        "",
        "# --- Hardening / cybersecurity core ---",
    }

    append_entries(lines, HARDENING_MAP, cfg.hardening)

    if cfg.hardening and cfg.hardening.lockdown_mode then
        table.insert(lines, "CONFIG_SECURITY_LOCKDOWN_LSM=y")
        if cfg.hardening.lockdown_mode == "confidentiality" then
            table.insert(lines, "CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y")
            table.insert(lines, "CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y")
        elseif cfg.hardening.lockdown_mode == "integrity" then
            table.insert(lines, "CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y")
        end
    end

    table.insert(lines, "")
    table.insert(lines, "# --- Xen hypervisor support ---")
    append_entries(lines, XEN_MAP, cfg.xen)

    table.insert(lines, "")
    table.insert(lines, "# --- Podsystemy cybersecurity (pentest/forensics/monitoring) ---")
    append_entries(lines, CYBERSEC_MAP, cfg.cybersecurity_subsystems)

    table.insert(lines, "")
    table.insert(lines, "# --- Branding HackerOS ---")
    if cfg.versioning and cfg.versioning.uname_suffix then
        table.insert(lines, string.format(
            'CONFIG_LOCALVERSION="%s"', cfg.versioning.uname_suffix))
    end

    Utils.write_file(frag_path, table.concat(lines, "\n") .. "\n")
    Utils.ok("Wygenerowano fragment konfiguracji: " .. frag_path)
    return frag_path
end

--- Scala base_config + wszystkie fragmenty (wlasny + ewentualne dodatkowe
-- z config/fragments/) w finalny .config wewnatrz drzewa zrodel jadra,
-- a nastepnie odpala 'make olddefconfig' aby dopelnic reszte opcji.
function Kconfig.merge_and_finalize(cfg, kernel_src_path, generated_fragment_path)
    local build_cfg = cfg.build
    local base_config = build_cfg.base_config

    if not Utils.file_exists(base_config) then
        Utils.warn("Brak base_config (" .. base_config .. ") - uzywam domyslnego defconfig jadra.")
        Utils.run_or_die(
            string.format("make -C '%s' defconfig", kernel_src_path),
            "Nie udalo sie wygenerowac domyslnej konfiguracji (defconfig).")
    else
        Utils.run_or_die(
            string.format("cp '%s' '%s/.config'", base_config, kernel_src_path),
            "Nie udalo sie skopiowac base_config do drzewa zrodel.")
    end

    -- zbieramy wszystkie fragmenty: wlasny wygenerowany + katalog fragments_dir
    local fragment_paths = { generated_fragment_path }

    if build_cfg.fragments_dir and Utils.dir_exists(build_cfg.fragments_dir) then
        local listing = Utils.capture(
            string.format("find '%s' -maxdepth 1 -name '*.config' -type f 2>/dev/null",
                build_cfg.fragments_dir))
        if listing then
            for line in listing:gmatch("[^\n]+") do
                if line ~= generated_fragment_path then
                    table.insert(fragment_paths, line)
                end
            end
        end
    end

    local merge_script = kernel_src_path .. "/scripts/kconfig/merge_config.sh"

    if Utils.file_exists(merge_script) then
        -- merge_config.sh jest wolane po 'cd kernel_src_path', wiec
        -- wzgledne sciezki fragmentow (np. config/fragments/x.config,
        -- relatywne do CWD procesu build.lua) trzeba najpierw zamienic
        -- na absolutne - inaczej merge_config.sh szuka ich wewnatrz
        -- drzewa zrodel jadra, gdzie nie istnieja, i pada z bledem
        -- "does not exist".
        local abs_fragment_paths = {}
        for _, fp in ipairs(fragment_paths) do
            local abs = Utils.capture("readlink -f '" .. fp .. "' 2>/dev/null")
            table.insert(abs_fragment_paths, (abs and abs ~= "") and abs or fp)
        end

        local frags_str = table.concat(abs_fragment_paths, " ")
        Utils.run_or_die(
            string.format("cd '%s' && ./scripts/kconfig/merge_config.sh -m .config %s",
                kernel_src_path, frags_str),
            "Nie udalo sie scalic fragmentow .config (merge_config.sh).")
    else
        -- fallback: prosty append + olddefconfig
        Utils.warn("merge_config.sh nie znaleziony - uzywam prostego appendu fragmentow.")
        for _, fp in ipairs(fragment_paths) do
            local content = Utils.read_file(fp)
            if content then
                Utils.append_file(kernel_src_path .. "/.config", "\n" .. content .. "\n")
            end
        end
    end

    Utils.log("Uruchamiam 'make olddefconfig' aby dopelnic zaleznosci konfiguracji...")
    Utils.run_or_die(
        string.format("make -C '%s' olddefconfig", kernel_src_path),
        "make olddefconfig nie powiodlo sie.")

    Utils.ok("Finalna konfiguracja .config gotowa.")
end

return Kconfig
