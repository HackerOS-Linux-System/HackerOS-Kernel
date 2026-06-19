#!/usr/bin/env lua5.5
--[[
    test_patches.lua  -  HackerOS Kernel patch compatibility tester

    Sprawdza czy wszystkie patche z patchsetu HackerOS Cybersecurity
    nadal aplikuja sie czysto na aktualnej stabilnej wersji jadra Linux.

    Uzycie:
      lua5.5 scripts/test_patches.lua               -- testuje aktualna wersje z kernel.org
      lua5.5 scripts/test_patches.lua --version=7.2 -- testuje konkretna wersje
      lua5.5 scripts/test_patches.lua --local=./src/linux  -- testuje lokalne zrodla

    Idealnie wywolywane w CI (GitHub Actions, GitLab CI) jako cron job
    po kazdym nowym wydaniu stabilnym Linuksa (kernel.org/releases.json),
    zeby wykryc "zgnilosci" patchy zanim uzytkownik probuje zbudowac jadro.

    Exit code:
      0  -- wszystkie patche OK
      1  -- co najmniej jeden patch nie aplikuje sie / blad pobierania
--]]

local script_dir = (arg and arg[0] or "scripts/test_patches.lua"):match("(.*/)") or "./"
local root_dir = script_dir == "./" and "./" or (script_dir .. "../")
package.path = root_dir .. "?.lua;" .. root_dir .. "?/init.lua;" .. package.path

local Utils  = require("scripts.utils")
local HK     = require("scripts.hk_parser")
local Source = require("scripts.source")

-- ---------------------------------------------------------------------------
-- Parsowanie argumentow
-- ---------------------------------------------------------------------------
local function parse_args(argv)
    local opts = { version = nil, local_src = nil, verbose = false }
    for _, a in ipairs(argv or {}) do
        if a:match("^%-%-version=") then
            opts.version = a:match("^%-%-version=(.+)$")
        elseif a:match("^%-%-local=") then
            opts.local_src = a:match("^%-%-local=(.+)$")
        elseif a == "--verbose" or a == "-v" then
            opts.verbose = true
        end
    end
    return opts
end

-- ---------------------------------------------------------------------------
-- Pobieranie minimalnego drzewa plikow (tylko pliki dotykane przez patche)
-- ---------------------------------------------------------------------------

local PATCH_TOUCHED_FILES = {
    "init/Kconfig",
    "security/Kconfig.hardening",
    "kernel/printk/printk.c",
    "kernel/ptrace.c",
    "arch/x86/xen/enlighten_pv.c",
    "net/core/dev.c",
    "kernel/auditsc.c",
    "kernel/entry/common.c",
    "drivers/char/mem.c",
    "kernel/bpf/core.c",
    "security/yama/yama_lsm.c",
    "net/ipv4/tcp_ipv4.c",
    "drivers/usb/core/hub.c",
    "kernel/module/signing.c",
    "drivers/net/xen-netback/netback.c",
    "kernel/bpf/syscall.c",
    "security/lockdown/lockdown.c",
}

local function fetch_kernel_files(version, work_dir, opts)
    local major = version:match("^(%d+)")
    local base_url = string.format(
        "https://raw.githubusercontent.com/torvalds/linux/v%s/", version)
    -- fallback na master jesli tag nie istnieje
    local master_url = "https://raw.githubusercontent.com/torvalds/linux/master/"
    local downloader = Utils.capture("command -v curl 2>/dev/null") and "curl"
               or (Utils.capture("command -v wget 2>/dev/null") and "wget")
               or nil

    if not downloader then
        Utils.die("Brak curl/wget do pobrania plikow zrodlowych jadra.")
    end

    Utils.log(string.format("Pobieranie %d plikow dla Linux %s...",
        #PATCH_TOUCHED_FILES, version))

    local fetched, failed = 0, 0
    for _, relpath in ipairs(PATCH_TOUCHED_FILES) do
        local destdir = work_dir .. "/" .. relpath:match("(.*/)") or work_dir
        Utils.mkdir_p(work_dir .. "/" .. (relpath:match("(.*/)") or ""))
        local dest = work_dir .. "/" .. relpath

        local url = base_url .. relpath
        local ok
        if downloader == "curl" then
            ok = Utils.run(string.format(
                "curl -fs --max-time 30 -o '%s' '%s' 2>/dev/null", dest, url), true)
            if not ok then
                -- fallback na master
                ok = Utils.run(string.format(
                    "curl -fs --max-time 30 -o '%s' '%s' 2>/dev/null",
                    dest, master_url .. relpath), true)
            end
        else
            ok = Utils.run(string.format(
                "wget -qO '%s' '%s' 2>/dev/null", dest, url), true)
            if not ok then
                ok = Utils.run(string.format(
                    "wget -qO '%s' '%s' 2>/dev/null",
                    dest, master_url .. relpath), true)
            end
        end

        if ok and Utils.file_exists(dest) then
            fetched = fetched + 1
            if opts.verbose then
                Utils.ok("  OK: " .. relpath)
            end
        else
            Utils.warn("  BRAK: " .. relpath .. " (patch moze byc niepotrzebny lub plik przeniesiony)")
            failed = failed + 1
        end
    end

    Utils.info(string.format("Pobrano %d/%d plikow (%d niedostepnych).",
        fetched, #PATCH_TOUCHED_FILES, failed))
    return fetched > 0
end

local function use_local_src(local_src, work_dir)
    Utils.log("Kopiowanie plikow z lokalnego drzewa: " .. local_src)
    local copied = 0
    for _, relpath in ipairs(PATCH_TOUCHED_FILES) do
        local src = local_src .. "/" .. relpath
        if Utils.file_exists(src) then
            local dest_dir = work_dir .. "/" .. (relpath:match("(.*/)") or "")
            Utils.mkdir_p(dest_dir)
            Utils.run(string.format("cp '%s' '%s/%s'", src, work_dir, relpath))
            copied = copied + 1
        end
    end
    Utils.info(string.format("Skopiowano %d plikow z lokalnego drzewa.", copied))
    return copied > 0
end

-- ---------------------------------------------------------------------------
-- Test patchy (dry-run)
-- ---------------------------------------------------------------------------

local function test_all_patches(patches_dir, apply_order, work_dir, opts)
    local results = {}
    local pass, fail, skip = 0, 0, 0

    for i, patch_name in ipairs(apply_order) do
        local patch_path = patches_dir .. "/" .. patch_name
        if not Utils.file_exists(patch_path) then
            Utils.warn(string.format("[%2d/%d] BRAK PLIKU: %s", i, #apply_order, patch_name))
            table.insert(results, { name = patch_name, status = "MISSING" })
            fail = fail + 1
            goto continue
        end

        -- dry-run
        local dry_result = Utils.capture(string.format(
            "patch -p1 --dry-run -d '%s' < '%s' 2>&1", work_dir, patch_path))
        local dry_ok = Utils.run(string.format(
            "patch -p1 --dry-run -d '%s' < '%s' > /dev/null 2>&1",
            work_dir, patch_path), true)

        if dry_ok then
            -- faktycznie aplikujemy (zeby kolejne patche mialy dobry kontekst)
            Utils.run(string.format(
                "patch -p1 -d '%s' < '%s' > /dev/null 2>&1", work_dir, patch_path), true)
            Utils.ok(string.format("[%2d/%d] OK   %s", i, #apply_order, patch_name))
            table.insert(results, { name = patch_name, status = "OK" })
            pass = pass + 1
        else
            local short_err = (dry_result or ""):match("^(.-)%s*$") or ""
            Utils.err(string.format("[%2d/%d] FAIL %s", i, #apply_order, patch_name))
            if opts.verbose then
                Utils.err("       " .. short_err:gsub("\n", "\n       "))
            end
            table.insert(results, { name = patch_name, status = "FAIL", err = short_err })
            fail = fail + 1
        end

        ::continue::
    end

    return results, pass, fail
end

-- ---------------------------------------------------------------------------
-- Raport wynikow
-- ---------------------------------------------------------------------------

local function print_report(results, pass, fail, version)
    print("")
    print(string.rep("=", 65))
    print(string.format(" HackerOS Kernel Patch Compatibility Report"))
    print(string.format(" Testowana wersja Linux: %s", version))
    print(string.rep("=", 65))
    print(string.format(" Wynik: %d/%d OK, %d FAIL",
        pass, pass + fail, fail))
    print(string.rep("-", 65))
    for _, r in ipairs(results) do
        local mark = r.status == "OK" and "[OK  ]"
               or r.status == "MISSING" and "[MISS]"
               or "[FAIL]"
        print(string.format(" %s %s", mark, r.name))
        if r.err and r.err ~= "" then
            print("        " .. r.err:gsub("\n", "\n        "):sub(1, 120))
        end
    end
    print(string.rep("=", 65))
    if fail > 0 then
        print(" AKCJA WYMAGANA: zaktualizuj nieaplikowalne patche!")
        print(" Wskazowka: patch nie pasuje bo linijki kontekstu przesunely sie")
        print(" miedzy wersjami. Sprawdz diff i zaktualizuj anchor.")
    else
        print(" Wszystkie patche kompatybilne z Linux " .. version .. " !")
    end
    print(string.rep("=", 65))
    print("")
end

-- ---------------------------------------------------------------------------
-- MAIN
-- ---------------------------------------------------------------------------

local function main()
    local opts = parse_args(arg)

    -- wczytaj config.hk
    local config_path = root_dir .. "config.hk"
    if not Utils.file_exists(config_path) then
        Utils.die("Nie znaleziono config.hk w: " .. config_path)
    end
    local cfg = HK.load_file(config_path)
    HK.resolve_interpolations(cfg)

    local patches_dir  = cfg.patches.dir or "./patches"
    local apply_order  = cfg.patches.apply_order
    if not apply_order or #apply_order == 0 then
        Utils.die("Brak patches.apply_order w config.hk")
    end

    -- okresl wersje do testow
    local version = opts.version
    if not version and not opts.local_src then
        -- auto-detect latest stable z kernel.org
        local downloader = Utils.capture("command -v curl 2>/dev/null") and "curl"
                   or (Utils.capture("command -v wget 2>/dev/null") and "wget")
                   or nil
        if downloader then
            local latest = Source.detect_latest_stable(cfg.source.min_version, downloader)
            version = latest or cfg.source.base_version
        else
            version = cfg.source.base_version
        end
    end
    version = version or cfg.source.base_version

    local work_dir = "/tmp/hackeros_patch_test_" .. tostring(os.time())
    Utils.mkdir_p(work_dir)

    -- pobierz/skopiuj pliki do testow
    local src_ok
    if opts.local_src then
        src_ok = use_local_src(opts.local_src, work_dir)
        version = opts.version or cfg.source.base_version
    else
        src_ok = fetch_kernel_files(version, work_dir, opts)
    end

    if not src_ok then
        Utils.die("Nie udalo sie przygotowac plikow do testow. Sprawdz polaczenie sieciowe.")
    end

    -- testuj patche
    print("")
    Utils.log(string.format("Testowanie %d patchy na Linux %s ...", #apply_order, version))
    local results, pass, fail = test_all_patches(patches_dir, apply_order, work_dir, opts)

    -- sprzatanie
    Utils.rm_rf(work_dir)

    -- raport
    print_report(results, pass, fail, version)

    os.exit(fail > 0 and 1 or 0)
end

local ok, err = pcall(main)
if not ok then
    Utils.err("test_patches: nieoczekiwany blad: " .. tostring(err))
    os.exit(1)
end
