--[[
    compile.lua

    Odpowiada za faktyczna kompilacje jadra:
      - make -j<jobs> bzImage modules
      - make modules_install / install do tymczasowego DESTDIR
      - opcjonalny strip modulow
--]]

local Utils = require("scripts.utils")

local Compile = {}

local function resolve_jobs(build_cfg)
    if build_cfg.jobs == "auto" or build_cfg.jobs == nil then
        return Utils.nproc()
    end
    local n = tonumber(build_cfg.jobs)
    return n or Utils.nproc()
end

function Compile.build_kernel(cfg, kernel_src_path)
    local build_cfg = cfg.build
    local jobs = resolve_jobs(build_cfg)

    Utils.mkdir_p(build_cfg.log_dir)
    local log_file = build_cfg.log_dir .. "/compile.log"

    Utils.log(string.format("Kompilacja jadra HackerOS (branch: cybersecurity), -j%d ...", jobs))
    Utils.warn("To moze potrwac od kilkunastu minut do kilku godzin, w zaleznosci od sprzetu.")

    local ccache_prefix = ""
    if build_cfg.use_ccache then
        if Utils.run("command -v ccache > /dev/null 2>&1", true) then
            ccache_prefix = "CC='ccache " .. (build_cfg.compiler or "gcc") .. "' "
            Utils.info("ccache wykryty - uzywam do przyspieszenia kompilacji.")
        else
            Utils.warn("use_ccache=true, ale ccache nie jest zainstalowany - pomijam.")
        end
    end

    local make_cmd = string.format(
        "cd '%s' && %sCC=%s make -j%d bzImage modules 2>&1 | tee '%s'",
        kernel_src_path, ccache_prefix, build_cfg.compiler or "gcc", jobs, log_file)

    local ok = Utils.run(make_cmd)
    if not ok then
        Utils.die("Kompilacja jadra nie powiodla sie. Sprawdz log: " .. log_file)
    end

    Utils.ok("Kompilacja jadra zakonczona sukcesem.")
end

--- Instaluje skompilowane jadro + moduly do tymczasowego DESTDIR
-- (uzywanego potem przy pakowaniu .deb), zamiast bezposrednio do /.
function Compile.install_to_destdir(cfg, kernel_src_path, destdir)
    local build_cfg = cfg.build
    local jobs = resolve_jobs(build_cfg)
    local kernel_release = Utils.capture(
        string.format("cd '%s' && make -s kernelrelease", kernel_src_path))

    if not kernel_release or kernel_release == "" then
        Utils.die("Nie udalo sie odczytac kernelrelease ze skompilowanych zrodel.")
    end

    Utils.info("Wykryta wersja release jadra: " .. kernel_release)

    Utils.mkdir_p(destdir .. "/boot")
    Utils.mkdir_p(destdir .. "/lib/modules")

    Utils.log("Instalacja modulow do DESTDIR=" .. destdir .. " ...")
    Utils.run_or_die(
        string.format("cd '%s' && make -j%d INSTALL_MOD_PATH='%s' modules_install",
            kernel_src_path, jobs, destdir),
        "make modules_install nie powiodlo sie.")

    if build_cfg.strip_modules then
        Utils.info("Strip modulow (zmniejszenie rozmiaru .ko)...")
        Utils.run(string.format(
            "find '%s/lib/modules/%s' -name '*.ko' -exec strip --strip-debug {} + 2>/dev/null",
            destdir, kernel_release), true)
    end

    Utils.log("Kopiowanie obrazu jadra (bzImage), System.map, config...")
    local arch_boot_path = kernel_src_path .. "/arch/x86/boot/bzImage"

    Utils.run_or_die(
        string.format("cp '%s' '%s/boot/vmlinuz-%s'",
            arch_boot_path, destdir, kernel_release),
        "Nie udalo sie skopiowac obrazu jadra (bzImage).")

    Utils.run(string.format("cp '%s/System.map' '%s/boot/System.map-%s'",
        kernel_src_path, destdir, kernel_release))
    Utils.run(string.format("cp '%s/.config' '%s/boot/config-%s'",
        kernel_src_path, destdir, kernel_release))

    Utils.ok("Instalacja do DESTDIR zakonczona. kernel-release = " .. kernel_release)

    return kernel_release
end

return Compile
