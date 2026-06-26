--[[
    utils.lua

    Funkcje pomocnicze dla HackerOS Kernel build systemu:
    - kolorowy logging
    - bezpieczne wywolywanie komend shell
    - operacje na plikach/sciezkach
    - parsowanie wersji jadra (semver-like dla kernel.org)
--]]

local Utils = {}

-- ---------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------

local COLORS = {
    reset  = "\27[0m",
    red    = "\27[31m",
    green  = "\27[32m",
    yellow = "\27[33m",
    blue   = "\27[34m",
    cyan   = "\27[36m",
    bold   = "\27[1m",
}

local function supports_color()
    local term = os.getenv("TERM")
    return term ~= nil and term ~= "" and term ~= "dumb"
end

local USE_COLOR = supports_color()

local function paint(color, text)
    if not USE_COLOR then return text end
    return COLORS[color] .. text .. COLORS.reset
end

function Utils.log(msg)
    io.write(paint("cyan", "[hk-build] ") .. msg .. "\n")
    io.flush()
end

function Utils.info(msg)
    io.write(paint("blue", "[info]  ") .. msg .. "\n")
    io.flush()
end

function Utils.ok(msg)
    io.write(paint("green", "[ok]    ") .. msg .. "\n")
    io.flush()
end

function Utils.warn(msg)
    io.write(paint("yellow", "[warn]  ") .. msg .. "\n")
    io.flush()
end

function Utils.err(msg)
    io.write(paint("red", "[error] ") .. msg .. "\n")
    io.flush()
end

function Utils.step(n, total, msg)
    io.write(paint("bold", string.format("\n[%d/%d] ", n, total)) .. msg .. "\n")
    io.flush()
end

function Utils.die(msg)
    Utils.err(msg)
    os.exit(1)
end

-- ---------------------------------------------------------------------
-- Shell helpers
-- ---------------------------------------------------------------------

--- Bezpiecznie cytuje sciezke do uzycia w poleceniu powloki (single-quote escaping).
-- Zamienia kazdy ' na '\'' co jest bezpieczne w /bin/sh i bash.
function Utils.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\''") .. "'"
end

--- Wykonuje komende w shellu. Zwraca true/false + kod wyjscia.
-- @param cmd string
-- @param quiet boolean opcjonalnie wycisz output komendy
function Utils.run(cmd, quiet)
    if not quiet then
        Utils.info("$ " .. cmd)
    end
    local ok, how, code = os.execute(cmd)
    -- Lua 5.1 zwraca tylko status; Lua 5.2+ zwraca (ok, "exit"/"signal", code)
    if how == nil then
        return ok == true or ok == 0, ok
    end
    return ok == true and code == 0, code
end

--- Jak run(), ale zabija caly build jesli komenda sie nie powiedzie
function Utils.run_or_die(cmd, err_msg)
    local ok, code = Utils.run(cmd)
    if not ok then
        Utils.die((err_msg or ("Komenda nie powiodla sie: " .. cmd)) ..
                  string.format(" (kod wyjscia: %s)", tostring(code)))
    end
    return ok
end

--- Wykonuje komende i zwraca jej stdout jako string (bez koncowego \n)
function Utils.capture(cmd)
    local handle = io.popen(cmd, "r")
    if not handle then return nil end
    local out = handle:read("*a")
    handle:close()
    if out then
        out = out:gsub("%s+$", "")
    end
    return out
end

-- ---------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------

function Utils.file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

function Utils.dir_exists(path)
    return Utils.run("test -d '" .. path .. "'", true)
end

function Utils.mkdir_p(path)
    return Utils.run_or_die("mkdir -p '" .. path .. "'",
        "Nie udalo sie utworzyc katalogu: " .. path)
end

function Utils.rm_rf(path)
    -- ochronka przed przypadkowym rm -rf / lub rm -rf ~
    if path == "" or path == "/" or path == "~" then
        Utils.die("Odmowa wykonania rm_rf na niebezpiecznej sciezce: '" .. path .. "'")
    end
    return Utils.run("rm -rf -- '" .. path .. "'")
end

function Utils.basename(path)
    return path:match("([^/]+)$") or path
end

function Utils.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

function Utils.write_file(path, content)
    local f, err = io.open(path, "w")
    if not f then
        Utils.die("Nie mozna zapisac pliku '" .. path .. "': " .. tostring(err))
    end
    f:write(content)
    f:close()
end

function Utils.append_file(path, content)
    local f, err = io.open(path, "a")
    if not f then
        Utils.die("Nie mozna dopisac do pliku '" .. path .. "': " .. tostring(err))
    end
    f:write(content)
    f:close()
end

-- ---------------------------------------------------------------------
-- Detekcja systemu
-- ---------------------------------------------------------------------

function Utils.nproc()
    local n = Utils.capture("nproc 2>/dev/null")
    return tonumber(n) or 4
end

function Utils.lua_version_string()
    return _VERSION or "unknown"
end

--- Sprawdza, ze interpreter to Lua 5.5+ (lub przynajmniej 5.4 jako minimum
-- akceptowalne z ostrzezeniem). Zwraca major, minor.
function Utils.check_lua_version(min_major, min_minor)
    local major, minor = _VERSION:match("Lua (%d+)%.(%d+)")
    major, minor = tonumber(major), tonumber(minor)
    if not major then
        Utils.warn("Nie udalo sie wykryc wersji Lua, kontynuuje mimo to.")
        return
    end
    if major < min_major or (major == min_major and minor < min_minor) then
        Utils.die(string.format(
            "Wymagana Lua %d.%d lub nowsza, wykryto %s. " ..
            "Uzyj: lua5.5 build.lua",
            min_major, min_minor, _VERSION))
    end
end

-- ---------------------------------------------------------------------
-- Parsowanie / porownywanie wersji jadra (np. "7.1", "7.1.2", "6.18.5")
-- ---------------------------------------------------------------------

--- Zamienia string wersji na tabele {major, minor, patch}
-- Akceptuje takze number (np. 7.1 sparsowane z .hk bez cudzyslowu jako
-- Lua number) - wymusza tostring na wejsciu, zeby v:match nie wybuchlo.
function Utils.parse_kernel_version(v)
    v = tostring(v)
    local major, minor, patch = v:match("^(%d+)%.(%d+)%.?(%d*)$")
    if not major then
        return nil
    end
    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch) or 0,
        raw   = v,
    }
end

--- Porownuje dwie wersje jadra. Zwraca -1, 0, 1
function Utils.compare_versions(a, b)
    local va, vb = Utils.parse_kernel_version(a), Utils.parse_kernel_version(b)
    if not va or not vb then return 0 end
    if va.major ~= vb.major then return va.major < vb.major and -1 or 1 end
    if va.minor ~= vb.minor then return va.minor < vb.minor and -1 or 1 end
    if va.patch ~= vb.patch then return va.patch < vb.patch and -1 or 1 end
    return 0
end

--- true jesli wersja "v" jest >= "min_v"
function Utils.version_at_least(v, min_v)
    return Utils.compare_versions(v, min_v) >= 0
end

return Utils
