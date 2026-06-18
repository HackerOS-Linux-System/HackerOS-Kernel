#!/usr/bin/env lua5.5
--[[
    ============================================================================
    build.lua  -  HackerOS Kernel (branch: cybersecurity) build system
    ============================================================================

    Buduje od zera (ze zrodel kernel.org) zmodyfikowane jadro Linux dla
    HackerOS Cybersecurity Edition i pakuje je do pliku .deb.

    Po zainstalowaniu wygenerowanego pakietu na Debianie:
      - usuwa aktualnie zainstalowane jadro(a) Debiana
      - instaluje HackerOS Kernel
      - ustawia je jako domyslne w GRUB

    Wymagania:
      - lua 5.5 lub nowsza (lua5.5 build.lua)
      - dostep do internetu (sciaganie zrodel z kernel.org)
      - typowe narzedzia budowania jadra: gcc, make, bc, flex, bison,
        libssl-dev, libelf-dev, dpkg-dev, fakeroot, xz-utils

    Uzycie:
      lua5.5 build.lua                 - pelny build z config.hk
      lua5.5 build.lua --version=7.2   - wymusza konkretna wersje jadra
      lua5.5 build.lua --no-download   - uzywa juz pobranych/rozpakowanych zrodel
      lua5.5 build.lua --jobs=8        - nadpisuje liczbe wątkow kompilacji
      lua5.5 build.lua --skip-patches  - pomija nakladanie patchy (debug)
      lua5.5 build.lua --config=PATH   - uzywa innego pliku .hk niz config.hk
      lua5.5 build.lua --help

    Struktura projektu (oczekiwana wzgledem build.lua):
      build.lua
      config.hk
      scripts/{utils,hk_parser,source,patches,kconfig,compile,deb_package}.lua
      src/            <- tu trafiaja zrodla jadra (linux-X.Y/) + symlink "linux"
      patches/        <- patche HackerOS Cybersecurity nakladane na jadro
      config/base.config, config/fragments/  <- bazowy .config i fragmenty
    ============================================================================
--]]

-- Pozwala "require" znajdowac moduly wzgledem katalogu, w ktorym jest build.lua,
-- niezalenie skad skrypt zostal wywolany.
local script_path = arg and arg[0] or "build.lua"
local script_dir = script_path:match("(.*/)") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path

local Utils    = require("scripts.utils")
local HK       = require("scripts.hk_parser")
local Source   = require("scripts.source")
local Patches  = require("scripts.patches")
local Kconfig  = require("scripts.kconfig")
local Compile  = require("scripts.compile")
local DebPkg   = require("scripts.deb_package")

local MIN_LUA_MAJOR, MIN_LUA_MINOR = 5, 5

-- ----------------------------------------------------------------------------
-- Parsowanie argumentow CLI
-- ----------------------------------------------------------------------------

local function parse_args(argv)
    local opts = {
        version       = nil,
        no_download   = false,
        skip_patches  = false,
        jobs          = nil,
        config_path   = "config.hk",
        help          = false,
        keep_going    = false,
    }

    for _, a in ipairs(argv) do
        if a == "--help" or a == "-h" then
            opts.help = true
        elseif a == "--no-download" then
            opts.no_download = true
        elseif a == "--skip-patches" then
            opts.skip_patches = true
        elseif a == "--keep-going" then
            opts.keep_going = true
        elseif a:match("^%-%-version=") then
            opts.version = a:match("^%-%-version=(.+)$")
        elseif a:match("^%-%-jobs=") then
            opts.jobs = a:match("^%-%-jobs=(.+)$")
        elseif a:match("^%-%-config=") then
            opts.config_path = a:match("^%-%-config=(.+)$")
        else
            Utils.warn("Nieznana opcja: " .. a .. " (ignoruje)")
        end
    end

    return opts
end

local function print_help()
    print([[
HackerOS Kernel build.lua - build system jadra cybersecurity dla HackerOS

Uzycie:
  lua5.5 build.lua [opcje]

Opcje:
  --version=X.Y       Wymusza konkretna wersje jadra Linux (np. 7.1, 7.2)
                       Musi byc >= min_version z config.hk (domyslnie 7.1).
  --no-download        Nie sciaga zrodel - wymaga, by byly juz w src/
  --skip-patches        Pomija nakladanie patchy HackerOS (tryb debug)
  --jobs=N              Nadpisuje liczbe wątkow kompilacji (domyslnie: auto/nproc)
  --config=PATH         Uzywa innego pliku konfiguracyjnego .hk niz config.hk
  --keep-going          Nie przerywa przy bledach niekrytycznych (np. brak fragmentu)
  --help, -h             Wyswietla te pomoc

Przyklady:
  lua5.5 build.lua
  lua5.5 build.lua --version=7.3 --jobs=16
  lua5.5 build.lua --no-download --skip-patches
]])
end

-- ----------------------------------------------------------------------------
-- Sprawdzanie zaleznosci systemowych potrzebnych do budowy jadra + .deb
-- ----------------------------------------------------------------------------

local REQUIRED_TOOLS = {
    "make", "gcc", "bc", "flex", "bison", "dpkg-deb", "patch", "tar", "find",
}

local function check_dependencies()
    Utils.log("Sprawdzanie wymaganych narzedzi systemowych...")
    local missing = {}

    for _, tool in ipairs(REQUIRED_TOOLS) do
        if not Utils.run("command -v " .. tool .. " > /dev/null 2>&1", true) then
            table.insert(missing, tool)
        end
    end

    if #missing > 0 then
        Utils.err("Brakujace narzedzia: " .. table.concat(missing, ", "))
        Utils.err("Na Debianie zainstaluj je przez:")
        Utils.err("  sudo apt-get install build-essential bc flex bison libssl-dev \\")
        Utils.err("       libelf-dev dpkg-dev fakeroot xz-utils libncurses-dev")
        os.exit(1)
    end

    Utils.ok("Wszystkie wymagane narzedzia sa obecne.")
end

-- ----------------------------------------------------------------------------
-- Glowny przebieg builda
-- ----------------------------------------------------------------------------

local TOTAL_STEPS = 7

local function main()
    local opts = parse_args(arg or {})

    if opts.help then
        print_help()
        return
    end

    Utils.log("HackerOS Kernel build.lua - start")
    Utils.info("Interpreter: " .. Utils.lua_version_string())
    Utils.check_lua_version(MIN_LUA_MAJOR, MIN_LUA_MINOR)

    -- ---- [1/7] Wczytanie config.hk -----------------------------------------
    Utils.step(1, TOTAL_STEPS, "Wczytywanie konfiguracji z " .. opts.config_path)

    if not Utils.file_exists(opts.config_path) then
        Utils.die("Nie znaleziono pliku konfiguracyjnego: " .. opts.config_path)
    end

    local cfg = HK.load_file(opts.config_path)
    HK.resolve_interpolations(cfg)

    if not cfg.metadata or not cfg.source or not cfg.package then
        Utils.die("Plik " .. opts.config_path .. " jest niekompletny (brakuje [metadata]/[source]/[package]).")
    end

    Utils.ok(string.format("Konfiguracja wczytana: %s (branch: %s)",
        cfg.metadata.name, cfg.metadata.branch))

    -- nadpisania z CLI
    if opts.version then
        cfg.source.base_version = opts.version
        cfg.source.auto_latest = false
        Utils.info("Wersja jadra wymuszona przez --version: " .. opts.version)
    end

    if opts.jobs then
        cfg.build.jobs = opts.jobs
    end

    if cfg.target.arch ~= "x86_64" then
        Utils.warn("config.hk deklaruje arch=" .. tostring(cfg.target.arch) ..
                   ", ale ten build.lua jest zoptymalizowany pod x86_64.")
    end

    -- ---- [2/7] Walidacja zaleznosci -----------------------------------------
    Utils.step(2, TOTAL_STEPS, "Walidacja zaleznosci systemowych")
    check_dependencies()

    -- ---- [3/7] Zrodla jadra --------------------------------------------------
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
        Utils.ok("Uzywam istniejacych zrodel w " .. paths.kernel_src .. " (bez sciagania).")
    else
        kernel_version = Source.ensure_kernel_source(cfg, paths)
    end

    Utils.ok(string.format("Zrodla jadra Linux %s gotowe w %s", kernel_version, paths.kernel_src))

    -- ---- [4/7] Patche HackerOS Cybersecurity ---------------------------------
    Utils.step(4, TOTAL_STEPS, "Nakladanie patchy HackerOS (branch: cybersecurity)")

    if opts.skip_patches then
        Utils.warn("--skip-patches podane - pomijam caly patchset (build NIE jest oficjalny HackerOS Kernel).")
    else
        Patches.apply_all(cfg, paths.kernel_src)
    end

    -- ---- [5/7] Konfiguracja .config (hardening, Xen, cybersecurity) ---------
    Utils.step(5, TOTAL_STEPS, "Generowanie konfiguracji jadra (.config)")

    local fragment_path = Kconfig.generate_fragment(cfg, cfg.build.fragments_dir)
    Kconfig.merge_and_finalize(cfg, paths.kernel_src, fragment_path)

    -- ---- [6/7] Kompilacja + instalacja do DESTDIR ----------------------------
    Utils.step(6, TOTAL_STEPS, "Kompilacja jadra i modulow")

    Compile.build_kernel(cfg, paths.kernel_src)

    local destdir = cfg.paths.deb_workdir .. "-destdir"
    Utils.rm_rf(destdir)
    Utils.mkdir_p(destdir)

    local kernel_release = Compile.install_to_destdir(cfg, paths.kernel_src, destdir)

    -- ---- [7/7] Budowa pakietu .deb -------------------------------------------
    Utils.step(7, TOTAL_STEPS, "Budowanie pakietu .deb")

    local output_deb = DebPkg.build(cfg, destdir, kernel_release)

    Utils.rm_rf(destdir)

    -- ---- Podsumowanie ---------------------------------------------------------
    print("")
    Utils.ok("============================================================")
    Utils.ok(" Build zakonczony sukcesem!")
    Utils.ok(" Jadro:        " .. cfg.metadata.name .. " (branch: " .. cfg.metadata.branch .. ")")
    Utils.ok(" Wersja Linux: " .. kernel_version)
    Utils.ok(" Release:      " .. kernel_release)
    Utils.ok(" Pakiet .deb:  " .. output_deb)
    Utils.ok("============================================================")
    print("")
    print("Instalacja na Debianie:")
    print("  sudo dpkg -i " .. output_deb)
    print("")
    print("Pakiet automatycznie usunie biezace jadro Debiana, zainstaluje")
    print("HackerOS Kernel i ustawi je jako domyslne w GRUB. Po instalacji")
    print("zrestartuj system, aby uruchomic nowe jadro.")
end

-- ----------------------------------------------------------------------------
-- Obsluga bledow na najwyzszym poziomie
-- ----------------------------------------------------------------------------

local ok, err = pcall(main)
if not ok then
    Utils.err("Build przerwany niespodziewanym bledem:")
    Utils.err(tostring(err))
    os.exit(1)
end
