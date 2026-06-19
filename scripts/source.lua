--[[
    source.lua

    Modul odpowiedzialny za:
      - sciaganie zrodel jadra Linux z kernel.org (lub uzycie lokalnego tarballa)
      - wykrywanie najnowszych stabilnych wersji >= 7.1 (auto_latest)
      - weryfikacje sum kontrolnych (jesli sha_check = true)
      - rozpakowanie do src/linux

    Wymagania zewnetrzne: curl lub wget, tar, xz.
--]]

local Utils = require("scripts.utils")

local Source = {}

--- Sprawdza czy curl albo wget jest dostepny, zwraca nazwe binarki
local function detect_downloader()
    if Utils.run("command -v curl > /dev/null 2>&1", true) then
        return "curl"
    elseif Utils.run("command -v wget > /dev/null 2>&1", true) then
        return "wget"
    end
    return nil
end

local function download(url, dest, tool)
    if tool == "curl" then
        return Utils.run(string.format("curl -fL --retry 3 -o '%s' '%s'", dest, url))
    else
        return Utils.run(string.format("wget --tries=3 -O '%s' '%s'", dest, url))
    end
end

local function fetch_text(url, tool)
    if tool == "curl" then
        return Utils.capture(string.format("curl -fsL '%s'", url))
    else
        return Utils.capture(string.format("wget -qO- '%s'", url))
    end
end

--- Probuje wykryc najnowsza stabilna wersje jadra z kernel.org (releases.json)
-- Zwraca string wersji (np. "7.2") albo nil jesli nie udalo sie ustalic.
function Source.detect_latest_stable(min_version, tool)
    Utils.info("Sprawdzanie najnowszej stabilnej wersji jadra na kernel.org...")

    local json = fetch_text("https://www.kernel.org/releases.json", tool)
    if not json then
        Utils.warn("Nie udalo sie pobrac releases.json - uzyje wersji bazowej z config.hk.")
        return nil
    end

    -- bardzo lekkie "parsowanie" JSON bez zewnetrznej biblioteki:
    -- szukamy pierwszego wystapienia "moniker":"stable" i odpowiadajacego "version"
    -- struktura kernel.org releases.json to lista obiektow w polu "releases"
    local best = nil
    for block in json:gmatch('{[^{}]-"moniker"%s*:%s*"stable"[^{}]-}') do
        local version = block:match('"version"%s*:%s*"([^"]+)"')
        if version then
            -- usuwamy ewentualny prefix "v"
            version = version:gsub("^v", "")
            if not best or Utils.compare_versions(version, best) > 0 then
                best = version
            end
        end
    end

    if best and min_version and Utils.compare_versions(best, min_version) < 0 then
        Utils.warn(string.format(
            "Wykryta wersja %s jest starsza niz min_version %s - ignoruje.",
            best, min_version))
        return nil
    end

    return best
end

--- Glowna funkcja: zapewnia obecnosc zrodel jadra w katalogu docelowym.
-- @param cfg tabela config.hk (po resolve_interpolations)
-- @param paths tabela {src_dir=, kernel_src=, build_dir=}
-- @return resolved_version string - wersja faktycznie uzyta do builda
function Source.ensure_kernel_source(cfg, paths)
    local source_cfg = cfg.source
    local base_version = tostring(source_cfg.base_version)
    local resolved_version = base_version

    local tool = detect_downloader()
    if not tool then
        Utils.die("Brak curl i wget - zainstaluj jedno z nich, aby sciagnac zrodla jadra.")
    end

    if source_cfg.auto_latest then
        local latest = Source.detect_latest_stable(tostring(source_cfg.min_version), tool)
        if latest then
            Utils.ok("Najnowsza wykryta wersja stabilna: " .. latest)
            resolved_version = latest
        else
            Utils.warn("Pozostaje przy wersji bazowej z config.hk: " .. base_version)
        end
    end

    if not Utils.version_at_least(resolved_version, source_cfg.min_version) then
        Utils.die(string.format(
            "Wersja jadra %s jest nizsza niz wymagane minimum %s. " ..
            "Ten build.lua wspiera Linux %s i nowsze.",
            resolved_version, source_cfg.min_version, source_cfg.min_version))
    end

    Utils.mkdir_p(paths.src_dir)

    local kernel_dir_name = "linux-" .. resolved_version
    local kernel_dir_path = paths.src_dir .. "/" .. kernel_dir_name
    local symlink_path = paths.kernel_src

    if Utils.dir_exists(kernel_dir_path) and Utils.file_exists(kernel_dir_path .. "/Makefile") then
        Utils.ok("Zrodla jadra " .. resolved_version .. " juz obecne, pomijam pobieranie.")
    else
        local major = resolved_version:match("^(%d+)")
        local tarball_name = "linux-" .. resolved_version .. ".tar.xz"
        local tarball_path = paths.build_dir .. "/" .. tarball_name
        local url = string.format(
            "https://cdn.kernel.org/pub/linux/kernel/v%s.x/%s",
            major, tarball_name)

        Utils.mkdir_p(paths.build_dir)

        if Utils.file_exists(tarball_path) then
            Utils.info("Tarball juz pobrany lokalnie: " .. tarball_path)
        else
            Utils.log("Pobieranie zrodel jadra Linux " .. resolved_version .. " ...")
            local ok = download(url, tarball_path, tool)
            if not ok then
                Utils.die("Nie udalo sie pobrac zrodel jadra z: " .. url)
            end
            Utils.ok("Pobrano: " .. tarball_path)
        end

        if source_cfg.sha_check then
            Source.verify_checksum(tarball_path, major, resolved_version, tool)
        end

        Utils.log("Rozpakowywanie " .. tarball_name .. " (moze potrwac kilka minut)...")
        Utils.run_or_die(
            string.format("tar -xJf '%s' -C '%s'", tarball_path, paths.src_dir),
            "Nie udalo sie rozpakowac archiwum jadra.")
        Utils.ok("Rozpakowano do " .. kernel_dir_path)
    end

    -- tworzymy/aktualizujemy symlink src/linux -> src/linux-X.Y
    Utils.run("rm -f '" .. symlink_path .. "'")
    Utils.run_or_die(
        string.format("ln -s '%s' '%s'", kernel_dir_name, symlink_path),
        "Nie udalo sie utworzyc symlinku do zrodel jadra.")

    return resolved_version
end

--- Weryfikuje sume kontrolna tarballa wzgledem sha256sums.asc z kernel.org.
-- Jesli weryfikacja sie nie powiedzie, przerywa build (sha_check = true w config.hk).
function Source.verify_checksum(tarball_path, major, version, tool)
    Utils.info("Weryfikacja sumy kontrolnej sha256...")

    local sums_url = string.format(
        "https://cdn.kernel.org/pub/linux/kernel/v%s.x/sha256sums.asc", major)
    local sums = fetch_text(sums_url, tool)

    if not sums then
        Utils.warn("Nie udalo sie pobrac sha256sums.asc - pomijam weryfikacje (kontynuuje).")
        return
    end

    local fname = "linux-" .. version .. ".tar.xz"
    local expected = sums:match("([%da-fA-F]+)%s+" .. fname:gsub("%.", "%%."))

    if not expected then
        Utils.warn("Brak wpisu checksum dla " .. fname .. " - pomijam weryfikacje.")
        return
    end

    local actual = Utils.capture(string.format("sha256sum '%s' | awk '{print $1}'", tarball_path))

    if not actual or actual:lower() ~= expected:lower() then
        Utils.die(string.format(
            "Niezgodnosc sumy kontrolnej dla %s!\n  oczekiwano: %s\n  otrzymano:  %s\n" ..
            "Archiwum moze byc uszkodzone lub naruszone - przerywam build.",
            fname, expected, tostring(actual)))
    end

    Utils.ok("Suma kontrolna zgodna.")
end

return Source
