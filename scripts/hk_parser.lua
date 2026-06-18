--[[
    hk_parser.lua

    Minimalny parser formatu .hk uzywanego w ekosystemie HackerOS.
    Implementuje skladnie opisana w dokumentacji:
    https://hackeros-linux-system.github.io/HackerOS-Website/tools-docs/hk.html

    Wsparcie:
      - komentarze "! ..."
      - sekcje [nazwa]
      - klucze L1/L2/L3... przez "->", "-->", "--->"
      - mapy inline (klucz bez "=>")
      - klucze kropkowe "a.b.c => val"
      - typy: string, number, bool, array
      - tablice wieloliniowe w stylu:
            -> apply_order => [
              "a",
              "b"
              ]
      - interpolacja ${sekcja.klucz}, ${sekcja.klucz[0]}, ${env:VAR}

    Nie jest to pelna implementacja calej specyfikacji (np. cytowane klucze
    z literalnymi kropkami), ale pokrywa wszystko czego uzywa config.hk
    w tym projekcie.
--]]

local HK = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- liczy ile myslnikow jest przed ">" zeby wyznaczyc glebokosc zagniezdzenia
local function count_dashes(prefix)
    local _, n = prefix:gsub("-", "")
    return n
end

-- parsuje pojedyncza "primitywna" wartosc (string/number/bool)
local function parse_scalar(raw)
    raw = trim(raw)

    if raw == "" then
        return ""
    end

    -- string cytowany
    local quoted = raw:match('^"(.*)"$')
    if quoted then
        quoted = quoted:gsub("\\n", "\n"):gsub("\\t", "\t")
                        :gsub("\\r", "\r"):gsub('\\"', '"')
                        :gsub("\\\\", "\\")
        return quoted
    end

    -- bool
    local lower = raw:lower()
    if lower == "true" then return true end
    if lower == "false" then return false end

    -- number
    if raw:match("^%-?%d+%.?%d*$") then
        return tonumber(raw)
    end

    -- plain string (bez cytowania)
    return raw
end

-- parsuje wartosc, ktora moze byc tablica (jednoliniowa lub wieloliniowa)
-- "lines" to caly bufor linii, "idx" to indeks biezacej linii (gdzie zaczyna sie '[')
-- zwraca: wartosc, nowy_idx
local function parse_value(value_str, lines, idx)
    value_str = trim(value_str)

    if value_str:match("^%[") and not value_str:match("%]%s*$") then
        -- tablica wieloliniowa - zbieramy kolejne linie do napotkania "]"
        local buffer = { value_str }
        local cur = idx
        while cur <= #lines do
            cur = cur + 1
            local l = lines[cur]
            if not l then break end
            table.insert(buffer, trim(l))
            if l:match("%]%s*$") then
                break
            end
        end
        local joined = table.concat(buffer, " ")
        return parse_value(joined, lines, idx), cur
    end

    if value_str:match("^%[.*%]$") then
        local inner = value_str:match("^%[(.*)%]$")
        local items = {}
        -- split po przecinkach respektujac cytowane stringi
        local cur_item = ""
        local in_quotes = false
        local i = 1
        while i <= #inner do
            local c = inner:sub(i, i)
            if c == '"' then
                in_quotes = not in_quotes
                cur_item = cur_item .. c
            elseif c == "," and not in_quotes then
                table.insert(items, parse_scalar(cur_item))
                cur_item = ""
            else
                cur_item = cur_item .. c
            end
            i = i + 1
        end
        if trim(cur_item) ~= "" then
            table.insert(items, parse_scalar(cur_item))
        end
        return items, idx
    end

    return parse_scalar(value_str), idx
end

-- ustawia wartosc w zagniezdzonej mapie wg listy kluczy (split po kropkach
-- lub po hierarchii myslnikow)
local function set_nested(map, key_path, value)
    local node = map
    for i = 1, #key_path - 1 do
        local k = key_path[i]
        if type(node[k]) ~= "table" then
            node[k] = {}
        end
        node = node[k]
    end
    node[key_path[#key_path]] = value
end

local function split_dots(key)
    local parts = {}
    for part in key:gmatch("[^%.]+") do
        table.insert(parts, part)
    end
    return parts
end

--- Parsuje string zawierajacy tresc pliku .hk
-- @param content string
-- @return table (zagniezdzona mapa sekcji)
function HK.parse(content)
    local result = {}
    local current_section = nil
    local section_name = nil

    -- stos sciezek dla zagniezdzenia myslnikowego: stack[depth] = key
    local depth_stack = {}

    local lines = {}
    for l in (content .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, l)
    end

    local i = 1
    while i <= #lines do
        local raw_line = lines[i]
        local line = trim(raw_line)

        -- pusta linia lub komentarz
        if line == "" or line:match("^!") then
            i = i + 1
            goto continue
        end

        -- sekcja [nazwa]
        local sect = line:match("^%[([%w_%-%.]+)%]$")
        if sect then
            section_name = sect
            current_section = {}
            result[section_name] = current_section
            depth_stack = {}
            i = i + 1
            goto continue
        end

        if current_section == nil then
            -- linia poza sekcja - ignorujemy (blad uzytkownika w pliku)
            i = i + 1
            goto continue
        end

        -- klucz z myslnikami: "-> key => value" lub "-> mapname" (inline map)
        local dashes, rest = line:match("^(%-+)>%s*(.*)$")
        if dashes then
            local depth = count_dashes(dashes)
            local key, val = rest:match("^([^=]+)=>%s*(.*)$")

            if key then
                key = trim(key)
                local val_parsed, new_i = parse_value(val, lines, i)
                i = new_i

                local key_parts = split_dots(key)

                if depth == 1 then
                    depth_stack = { key_parts }
                    set_nested(current_section, key_parts, val_parsed)
                else
                    -- budujemy pelna sciezke z poprzednich poziomow + biezacy klucz
                    local full_path = {}
                    for d = 1, depth - 1 do
                        if depth_stack[d] then
                            for _, p in ipairs(depth_stack[d]) do
                                table.insert(full_path, p)
                            end
                        end
                    end
                    for _, p in ipairs(key_parts) do
                        table.insert(full_path, p)
                    end
                    depth_stack[depth] = key_parts
                    set_nested(current_section, full_path, val_parsed)
                end
            else
                -- mapa inline, bez "=>" - tworzy podmape
                local mapname = trim(rest)
                local key_parts = split_dots(mapname)

                if depth == 1 then
                    depth_stack = { key_parts }
                    set_nested(current_section, key_parts, {})
                else
                    local full_path = {}
                    for d = 1, depth - 1 do
                        if depth_stack[d] then
                            for _, p in ipairs(depth_stack[d]) do
                                table.insert(full_path, p)
                            end
                        end
                    end
                    for _, p in ipairs(key_parts) do
                        table.insert(full_path, p)
                    end
                    depth_stack[depth] = key_parts
                    set_nested(current_section, full_path, {})
                end
            end
        end

        i = i + 1
        ::continue::
    end

    return result
end

--- Wczytuje plik .hk z dysku
function HK.load_file(path)
    local f, err = io.open(path, "r")
    if not f then
        error("hk_parser: nie mozna otworzyc pliku '" .. path .. "': " .. tostring(err))
    end
    local content = f:read("*a")
    f:close()
    return HK.parse(content)
end

-- pomocnicze: dostep po sciezce "sekcja.klucz.podklucz"
local function get_by_path(config, path)
    local parts = split_dots(path)
    local node = config
    for _, p in ipairs(parts) do
        -- wsparcie dla indeksu tablicy: klucz[0]
        local base, idx = p:match("^([%w_%-]+)%[(%d+)%]$")
        if base then
            node = node[base]
            if node == nil then return nil end
            node = node[tonumber(idx) + 1]
        else
            if type(node) ~= "table" then return nil end
            node = node[p]
        end
        if node == nil then return nil end
    end
    return node
end

--- Rozwiazuje interpolacje ${...} w calej konfiguracji (rekurencyjnie, in-place)
function HK.resolve_interpolations(config)
    local MAX_DEPTH = 10

    local function resolve_string(s, depth)
        depth = depth or 0
        if depth > MAX_DEPTH then
            error("hk_parser: mozliwy cykl interpolacji (zbyt glebokie zagniezdzenie) w: " .. tostring(s))
        end

        local resolved, count = s:gsub("%${([^}]+)}", function(ref)
            if ref:match("^env:") then
                local var = ref:sub(5)
                return os.getenv(var) or ""
            end
            local val = get_by_path(config, ref)
            if val == nil then
                error("hk_parser: nieprawidlowa referencja interpolacji '" .. ref .. "'")
            end
            if type(val) == "table" then
                error("hk_parser: nie mozna interpolowac tablicy/mapy: '" .. ref .. "'")
            end
            return tostring(val)
        end)

        if count > 0 and resolved:match("%${") then
            return resolve_string(resolved, depth + 1)
        end
        return resolved
    end

    local function walk(node)
        if type(node) ~= "table" then return node end
        for k, v in pairs(node) do
            if type(v) == "string" and v:match("%${") then
                node[k] = resolve_string(v)
            elseif type(v) == "table" then
                walk(v)
            end
        end
        return node
    end

    walk(config)
    return config
end

HK.get_by_path = get_by_path

return HK
