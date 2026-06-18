--[[
    patches.lua

    Naklada patche z patches/ na zrodla jadra w kolejnosci zdefiniowanej
    w config.hk ([patches].apply_order). Tworzy plik .hackeros-patches-applied
    w drzewie zrodel, aby uniknac podwojnego patchowania przy ponownym
    wywolaniu build.lua na tych samych zrodlach.
--]]

local Utils = require("scripts.utils")

local Patches = {}

function Patches.apply_all(cfg, kernel_src_path)
    local patch_cfg = cfg.patches
    local marker = kernel_src_path .. "/.hackeros-patches-applied"

    if Utils.file_exists(marker) then
        Utils.ok("Patche HackerOS juz nalozone wczesniej (znaleziono marker), pomijam.")
        return
    end

    if not patch_cfg or not patch_cfg.apply_order then
        Utils.warn("Brak listy patchy w config.hk - kontynuuje bez patchowania.")
        return
    end

    local patches_dir = patch_cfg.dir or "./patches"
    local applied_count = 0

    for _, patch_name in ipairs(patch_cfg.apply_order) do
        local patch_path = patches_dir .. "/" .. patch_name

        if not Utils.file_exists(patch_path) then
            local msg = "Brak pliku patcha: " .. patch_path
            if patch_cfg.fail_on_reject then
                Utils.die(msg)
            else
                Utils.warn(msg .. " - pomijam.")
                goto continue
            end
        end

        Utils.info("Nakladanie patcha: " .. patch_name)

        -- najpierw "dry run" zeby wykryc rejecty zanim cokolwiek zmodyfikujemy
        local dry_ok = Utils.run(
            string.format("patch -p1 --dry-run -d '%s' < '%s' > /dev/null 2>&1",
                kernel_src_path, patch_path), true)

        if not dry_ok then
            local msg = "Patch '" .. patch_name .. "' nie aplikuje sie czysto (konflikt/reject)."
            if patch_cfg.fail_on_reject then
                Utils.die(msg .. " Przerywam build zgodnie z fail_on_reject=true.")
            else
                Utils.warn(msg .. " Pomijam (fail_on_reject=false).")
                goto continue
            end
        end

        local ok = Utils.run(
            string.format("patch -p1 -d '%s' < '%s'", kernel_src_path, patch_path))

        if not ok then
            Utils.die("Nieoczekiwany blad podczas nakladania patcha: " .. patch_name)
        end

        applied_count = applied_count + 1
        Utils.ok("Nalozono: " .. patch_name)

        ::continue::
    end

    Utils.write_file(marker, string.format(
        "HackerOS Kernel patchset applied\nDate: %s\nPatches applied: %d\n",
        os.date("%Y-%m-%d %H:%M:%S"), applied_count))

    Utils.ok(string.format("Nalozono %d patch(y) z patchsetu HackerOS Cybersecurity.", applied_count))
end

return Patches
