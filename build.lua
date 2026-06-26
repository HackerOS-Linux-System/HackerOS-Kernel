#!/usr/bin/env lua
--[[
    ============================================================================
    build.lua  -  HackerOS Kernel (branch: cybersecurity) build system
    ============================================================================

    Uzycie:
      lua build.lua                   - pelny build
      lua build.lua --version=7.2     - wymusza konkretna wersje jadra
      lua build.lua --no-download     - uzywa juz pobranych/rozpakowanych zrodel
      lua build.lua --jobs=8          - nadpisuje liczbe watkow kompilacji
      lua build.lua --skip-patches    - pomija nakladanie patchy (debug)
      lua build.lua --keep-going      - kontynuuje mimo bledow niekrytycznych
      lua build.lua --config=PATH     - inny plik .hk
      lua build.lua --no-sign        - pomija podpisywanie modulow
      lua build.lua --no-headers     - pomija budowanie pakietu naglowkow
      lua build.lua --help
--]]

local script_path = arg and arg[0] or "build.lua"
local script_dir  = script_path:match("(.*/)") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path

local Utils   = require("scripts.utils")
local HK      = require("scripts.hk_parser")
local Source  = require("scripts.source")
local Patches = require("scripts.patches")
local Kconfig = require("scripts.kconfig")
local Compile = require("scripts.compile")
local DebPkg  = require("scripts.deb_package")
local RH      = require("scripts.runtime_hardening")

local MIN_LUA_MAJOR, MIN_LUA_MINOR = 5, 5

-- ---------------------------------------------------------------------------
-- Parsowanie argumentow CLI
-- ---------------------------------------------------------------------------

local function parse_args(argv)
    local opts = {
        version      = nil,
        no_download  = false,
        skip_patches = false,
        jobs         = nil,
        config_path  = "config.hk",
        help         = false,
        keep_going   = false,
        no_sign      = false,
        no_headers   = false,
        ci_fast      = false,
    }
    for _, a in ipairs(argv or {}) do
        if a == "--help" or a == "-h" then
            opts.help = true
        elseif a == "--no-download"  then opts.no_download  = true
        elseif a == "--skip-patches" then opts.skip_patches = true
        elseif a == "--keep-going"   then opts.keep_going   = true
        elseif a == "--no-sign"      then opts.no_sign      = true
        elseif a == "--no-headers"   then opts.no_headers   = true
        elseif a == "--ci-fast"      then opts.ci_fast      = true
        elseif a:match("^%-%-version=") then opts.version     = a:match("^%-%-version=(.+)$")
        elseif a:match("^%-%-jobs=")    then opts.jobs        = a:match("^%-%-jobs=(.+)$")
        elseif a:match("^%-%-config=")  then opts.config_path = a:match("^%-%-config=(.+)$")
        else Utils.warn("Nieznana opcja: " .. a)
        end
    end
    return opts
end

local function print_help()
    print([[
HackerOS Kernel build.lua - build system jadra cybersecurity dla HackerOS

Uzycie:
  lua build.lua [opcje]

Opcje:
  --version=X.Y      Wymusza konkretna wersje jadra (>= 7.1)
  --no-download       Nie sciaga zrodel (muszą byc juz w src/)
  --skip-patches       Pomija patchset (tryb debug/porownawczy)
  --jobs=N             Liczba watkow kompilacji (domyslnie: auto/nproc)
  --config=PATH        Inny plik .hk niz config.hk
  --keep-going         Kontynuuje mimo bledow niekrytycznych
  --no-sign             Pomija generowanie kluczy i podpisywanie modulow
  --no-headers          Nie buduje odrebnego pakietu naglowkow
  --ci-fast              Preset szybkiego smoke-buildu: config/ci-tiny.config
                         zamiast pelnego base_config, bez Xen/signing/headers.
                         Weryfikuje TYLKO ze patche sie kompiluja - NIE jest
                         to konfiguracja produkcyjna HackerOS Kernel.
  --help, -h              Wyswietla pomoc

Przyklady:
  lua build.lua
  lua build.lua --version=7.3 --jobs=16
  lua build.lua --no-download --skip-patches --keep-going
  lua build.lua --no-sign --no-headers   (szybszy build bez extra paczek)
  lua build.lua --ci-fast                (smoke-build do CI, kilka minut)
]])
end

-- ---------------------------------------------------------------------------
-- Zaleznosci systemowe
-- ---------------------------------------------------------------------------

local REQUIRED_TOOLS = {
    "make", "gcc", "bc", "flex", "bison",
    "dpkg-deb", "patch", "tar", "find", "openssl",
}

local function check_dependencies(opts)
    Utils.log("Sprawdzanie wymaganych narzedzi...")
    local missing = {}
    for _, tool in ipairs(REQUIRED_TOOLS) do
        if tool == "openssl" and (opts.no_sign or opts.ci_fast) then goto skip end
        if not Utils.run("command -v " .. tool .. " > /dev/null 2>&1", true) then
            table.insert(missing, tool)
        end
        ::skip::
    end

    if #missing > 0 then
        Utils.err("Brakujace narzedzia: " .. table.concat(missing, ", "))
        Utils.err("  sudo apt-get install build-essential bc flex bison " ..
                  "libssl-dev libelf-dev dpkg-dev fakeroot xz-utils openssl")
        os.exit(1)
    end
    Utils.ok("Wszystkie wymagane narzedzia sa dostepne.")
end

-- ---------------------------------------------------------------------------
-- Pomocnicze: blad niekrytyczny respektujacy --keep-going
-- ---------------------------------------------------------------------------

local function soft_error(opts, msg)
    if opts.keep_going then
        Utils.warn(msg .. " (--keep-going: kontynuuje mimo to)")
    else
        Utils.die(msg)
    end
end

-- ---------------------------------------------------------------------------
-- MAIN - 8 krokow
-- ---------------------------------------------------------------------------

local TOTAL_STEPS = 8

local function main()
    local opts = parse_args(arg or {})

    if opts.help then print_help(); return end

    Utils.log("HackerOS Kernel build.lua v2 - start")
    Utils.info("Interpreter: " .. Utils.lua_version_string())
    Utils.check_lua_version(MIN_LUA_MAJOR, MIN_LUA_MINOR)

    -- [1/8] Konfiguracja --------------------------------------------------
    Utils.step(1, TOTAL_STEPS, "Wczytywanie konfiguracji: " .. opts.config_path)
    if not Utils.file_exists(opts.config_path) then
        Utils.die("Nie znaleziono pliku konfiguracyjnego: " .. opts.config_path)
    end
    local cfg = HK.load_file(opts.config_path)
    HK.resolve_interpolations(cfg)

    if not cfg.metadata or not cfg.source or not cfg.package then
        Utils.die("config.hk niekompletny (brak [metadata]/[source]/[package]).")
    end

    if opts.version then
        cfg.source.base_version = opts.version
        cfg.source.auto_latest  = false
        Utils.info("Wersja wymuszona: " .. opts.version)
    end
    if opts.jobs     then cfg.build.jobs = opts.jobs end
    if opts.no_sign  then cfg.signing.sign_modules = false end
    if opts.no_headers and cfg.headers_package then
        cfg.headers_package.enabled = false
    end

    if opts.ci_fast then
        Utils.warn("--ci-fast: preset smoke-buildu CI aktywny.")
        Utils.warn("To NIE jest konfiguracja produkcyjna HackerOS Kernel!")
        cfg.build.base_config = "config/ci-tiny.config"
        cfg.signing.sign_modules = false
        if cfg.headers_package then cfg.headers_package.enabled = false end
        -- Xen wymaga sporo zaleznosci (CONFIG_PARAVIRT i in.) ktorych
        -- ci-tiny.config nie ma - wylaczamy zeby kconfig.lua nie
        -- generowal fragmentu, ktorego olddefconfig nie da sie spelnic
        -- bez pelnego base_config.
        cfg.xen.enabled = false
        -- module_sig wymaga CONFIG_MODULE_SIG_KEY - bez signing.lua
        -- wywolanego w tym presecie zostawiamy domyslny klucz kernela,
        -- wiec wylaczamy force, zeby nie blokowac smoke-buildu.
        cfg.hardening.module_sig = false
        cfg.hardening.module_sig_force = false
    end

    Utils.ok("Konfiguracja: " .. cfg.metadata.name .. " (branch: " .. cfg.metadata.branch .. ")")
    Utils.info("Patchy w patchsecie: " .. #cfg.patches.apply_order)
    Utils.info("Runtime hardening: sysctl + GRUB_CMDLINE")
    Utils.info("Podpisywanie modulow: " .. (cfg.signing.sign_modules and "TAK" or "NIE"))
    Utils.info("Pakiet naglowkow: " .. ((cfg.headers_package and cfg.headers_package.enabled) and "TAK" or "NIE"))
    if opts.ci_fast then
        Utils.info("Tryb: CI-FAST SMOKE BUILD (config/ci-tiny.config, Xen wylaczony)")
    end

    -- [2/8] Zaleznosci ---------------------------------------------------
    Utils.step(2, TOTAL_STEPS, "Walidacja zaleznosci systemowych")
    check_dependencies(opts)

    -- [3/8] Zrodla jadra -------------------------------------------------
    Utils.step(3, TOTAL_STEPS, "Przygotowanie zrodel jadra Linux")
    local paths = {
        src_dir    = cfg.paths.src_dir,
        kernel_src = cfg.paths.kernel_src,
        build_dir  = cfg.build.build_dir,
    }
    local kernel_version
    if opts.no_download then
        if not Utils.dir_exists(paths.kernel_src) then
            Utils.die("--no-download podane, ale " .. paths.kernel_src .. " nie istnieje.")
        end
        kernel_version = cfg.source.base_version
        Utils.ok("Uzycie lokalnych zrodel: " .. paths.kernel_src)
    else
        kernel_version = Source.ensure_kernel_source(cfg, paths)
    end
    Utils.ok("Zrodla Linux " .. kernel_version .. " gotowe.")

    -- [4/8] Patche -------------------------------------------------------
    Utils.step(4, TOTAL_STEPS, "Nakladanie patchsetu HackerOS (" ..
        #cfg.patches.apply_order .. " patchy)")
    if opts.skip_patches then
        Utils.warn("--skip-patches: pomijam patchset (build nieoficjalny).")
    else
        local ok, err = pcall(Patches.apply_all, cfg, paths.kernel_src)
        if not ok then
            soft_error(opts, "Nakladanie patchy nie powiodlo sie: " .. tostring(err))
        end
    end

    -- [5/8] Konfiguracja .config -----------------------------------------
    Utils.step(5, TOTAL_STEPS, "Generowanie konfiguracji jadra (.config)")
    local ok, err = pcall(function()
        local frag = Kconfig.generate_fragment(cfg, cfg.build.fragments_dir)
        Kconfig.merge_and_finalize(cfg, paths.kernel_src, frag)
    end)
    if not ok then
        soft_error(opts, "Generowanie .config nie powiodlo sie: " .. tostring(err))
    end

    -- [5b] Przygotowanie kluczy podpisywania + inject do .config ----------
    local signing_key_path, signing_cert_path
    if cfg.signing and cfg.signing.sign_modules then
        local sok, skey, scert = pcall(Compile.prepare_signing, cfg, paths.kernel_src)
        if sok then
            signing_key_path  = skey
            signing_cert_path = scert
        else
            soft_error(opts, "Przygotowanie kluczy podpisywania nie powiodlo sie: " ..
                tostring(skey))
        end
    end

    -- [6/8] Kompilacja ---------------------------------------------------
    Utils.step(6, TOTAL_STEPS, "Kompilacja jadra i modulow")
    local comp_ok, comp_err = pcall(Compile.build_kernel, cfg, paths.kernel_src)
    if not comp_ok then
        Utils.die("Kompilacja jadra nie powiodla sie: " .. tostring(comp_err))
    end

    local destdir = cfg.paths.deb_workdir .. "-destdir"
    Utils.rm_rf(destdir)
    Utils.mkdir_p(destdir)
    local kernel_release = Compile.install_to_destdir(cfg, paths.kernel_src, destdir)

    -- [6b] Instalacja naglowkow (dla pakietu headers) --------------------
    local headers_destdir = cfg.paths.deb_workdir .. "-headers-destdir"
    local headers_built = false
    if cfg.headers_package and cfg.headers_package.enabled then
        Utils.rm_rf(headers_destdir)
        Utils.mkdir_p(headers_destdir)
        local hok, herr = pcall(Compile.install_headers_to_destdir,
            cfg, paths.kernel_src, headers_destdir, kernel_release)
        if hok then
            headers_built = herr  -- install_headers_to_destdir zwraca bool
        else
            soft_error(opts, "Instalacja naglowkow nie powiodla sie: " .. tostring(herr))
        end
    end

    -- [7/8] Pakowanie .deb -----------------------------------------------
    Utils.step(7, TOTAL_STEPS, "Budowanie pakietow .deb")
    local output_deb = DebPkg.build(cfg, destdir, kernel_release,
        signing_key_path, signing_cert_path)

    local output_headers_deb = nil
    if headers_built then
        local hhok, hherr = pcall(DebPkg.build_headers, cfg, headers_destdir, kernel_release)
        if hhok then
            output_headers_deb = hherr
        else
            soft_error(opts, "Pakowanie naglowkow nie powiodlo sie: " .. tostring(hherr))
        end
    end

    -- sprzatanie DESTDIR
    Utils.rm_rf(destdir)
    if headers_built then Utils.rm_rf(headers_destdir) end

    -- [8/8] Podsumowanie -------------------------------------------------
    Utils.step(8, TOTAL_STEPS, "Build zakonczony")
    print("")
    Utils.ok("====================================================")
    Utils.ok(" HackerOS Kernel - build zakonczony pomyslnie")
    Utils.ok(" Jadro:        " .. cfg.metadata.name)
    Utils.ok(" Branch:       " .. cfg.metadata.branch)
    Utils.ok(" Linux:        " .. kernel_version)
    Utils.ok(" Release:      " .. kernel_release)
    Utils.ok(" Patchy:       " .. #cfg.patches.apply_order)
    Utils.ok(" Pakiet .deb:  " .. output_deb)
    if output_headers_deb then
        Utils.ok(" Headers .deb: " .. output_headers_deb)
    end
    if signing_key_path then
        Utils.ok(" Klucz MOK:    " .. (cfg.signing.keys_dir) .. "/hackeros-signing-key.crt")
    end
    Utils.ok("====================================================")
    print("")
    print("Instalacja:")
    print("  sudo dpkg -i " .. output_deb)
    if output_headers_deb then
        print("  sudo dpkg -i " .. output_headers_deb)
    end
    if signing_key_path then
        print("")
        print("Jesli uzywasz UEFI Secure Boot, zarejestruj klucz MOK:")
        print("  sudo mokutil --import " .. cfg.signing.keys_dir ..
              "/hackeros-signing-key.crt")
    end
    print("")
end

local ok, err = pcall(main)
if not ok then
    Utils.err("Build przerwany: " .. tostring(err))
    os.exit(1)
end
