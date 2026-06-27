--[[
    compile.lua

    Odpowiada za faktyczna kompilacje jadra:
      - make -j<jobs> bzImage modules
      - generowanie / wstrzykiwanie klucza podpisywania modulow (signing.lua)
      - make modules_install / install do tymczasowego DESTDIR
      - make headers_install do odrebnego HEADERS_DESTDIR (pakiet -headers)
      - opcjonalny strip modulow
--]]

local Utils   = require("scripts.utils")
local Signing = require("scripts.signing")

local Compile = {}

local function resolve_jobs(build_cfg)
    if build_cfg.jobs == "auto" or build_cfg.jobs == nil then
        return Utils.nproc()
    end
    return tonumber(build_cfg.jobs) or Utils.nproc()
end

--- Krok 1: generuje klucze podpisywania (jesli signing.sign_modules=true)
-- i wstrzykuje CONFIG_MODULE_SIG_KEY do .config.
function Compile.prepare_signing(cfg, kernel_src_path)
    if not (cfg.signing and cfg.signing.sign_modules) then
        Utils.info("Podpisywanie modulow wylaczone (signing.sign_modules=false).")
        return nil, nil
    end

    if not cfg.hardening or not cfg.hardening.module_sig then
        Utils.warn("signing.sign_modules=true ale hardening.module_sig=false - " ..
                   "wlaczam module_sig aby podpisywanie mialo sens.")
    end

    local combined, cert = Signing.ensure_module_signing_key(cfg)
    Signing.inject_into_kernel_config(cfg, kernel_src_path, combined)
    return combined, cert
end

--- Krok 2: kompilacja jadra i modulow.
function Compile.build_kernel(cfg, kernel_src_path)
    local build_cfg = cfg.build
    local jobs = resolve_jobs(build_cfg)

    Utils.mkdir_p(build_cfg.log_dir)
    local log_file = build_cfg.log_dir .. "/compile.log"

    Utils.log(string.format(
        "Kompilacja jadra HackerOS (branch: %s), -j%d ...", cfg.metadata.branch, jobs))
    Utils.warn("To moze potrwac od kilkunastu minut do kilku godzin.")

    local cc = build_cfg.compiler or "gcc"
    local ccache_prefix = ""
    if build_cfg.use_ccache then
        if Utils.run("command -v ccache > /dev/null 2>&1", true) then
            ccache_prefix = "CC='ccache " .. cc .. "' "
            Utils.info("ccache wykryty - przyspiesza kompilacje.")
        else
            Utils.warn("use_ccache=true, ale ccache niedostepny - kontynuuje bez niego.")
        end
    end

    local sq = Utils.shell_quote

    -- Wyznacz absolutne sciezki przed jakimkolwiek cd.
    -- Wrapper.sh robi "cd kernel_src_path" wiec relative paths
    -- wskazalyby na drzewo zrodel jadra, nie katalog projektu.
    local abs_log       = Utils.abspath(log_file)
    local abs_exitcode  = Utils.abspath(build_cfg.log_dir .. "/make_exitcode.tmp")
    local abs_wrapper   = Utils.abspath(build_cfg.log_dir .. "/make_wrapper.sh")

    Utils.mkdir_p(build_cfg.log_dir)

    -- Generujemy tymczasowy skrypt powloki zamiast skomplikowanego shell-quoting.
    local wrapper_lines = {
        "#!/bin/bash",
        "set -o pipefail 2>/dev/null || true",
        "cd " .. sq(kernel_src_path),
        ccache_prefix .. "make -j" .. tostring(jobs)
            .. " bzImage modules 2>&1 | tee " .. sq(abs_log),
        "MAKE_EXIT=${PIPESTATUS[0]:-$?}",
        "echo ${MAKE_EXIT} > " .. sq(abs_exitcode),
        "exit ${MAKE_EXIT}",
    }
    Utils.write_file(abs_wrapper, table.concat(wrapper_lines, "\n") .. "\n")
    os.execute("chmod +x " .. sq(abs_wrapper))

    -- Uruchom wrapper; ignorujemy exit code bash-a, czytamy z pliku
    os.execute(sq(abs_wrapper) .. " || true")

    -- Odczytaj rzeczywisty exit code make z pliku (abs path)
    local ec_handle = io.open(abs_exitcode, "r")
    local make_exitcode = 1
    if ec_handle then
        local raw = ec_handle:read("*l") or "1"
        make_exitcode = tonumber(raw:match("^%s*(%d+)")) or 1
        ec_handle:close()
        os.remove(abs_exitcode)
    end
    os.remove(abs_wrapper)
    if make_exitcode ~= 0 then
        Utils.die("Kompilacja jadra nie powiodla sie (exit "
            .. make_exitcode .. "). Log: " .. log_file)
    end
    Utils.ok("Kompilacja jadra zakonczona sukcesem.")
end

--- Krok 3: instalacja do DESTDIR (bootloader image + moduly).
function Compile.install_to_destdir(cfg, kernel_src_path, destdir)
    local build_cfg = cfg.build
    local jobs = resolve_jobs(build_cfg)

    local kernel_release = Utils.capture(
        string.format("cd '%s' && make -s kernelrelease 2>/dev/null", kernel_src_path))
    if not kernel_release or kernel_release == "" then
        Utils.die("Nie udalo sie odczytac kernelrelease.")
    end
    Utils.info("kernel-release: " .. kernel_release)

    Utils.mkdir_p(destdir .. "/boot")
    Utils.mkdir_p(destdir .. "/lib/modules")

    -- moduly
    Utils.log("Instalacja modulow do DESTDIR...")
    Utils.run_or_die(
        string.format("cd '%s' && make -j%d INSTALL_MOD_PATH='%s' modules_install",
            kernel_src_path, jobs, destdir),
        "make modules_install nie powiodlo sie.")

    if build_cfg.strip_modules then
        Utils.info("Strip modulow (.ko)...")
        Utils.run(string.format(
            "find '%s/lib/modules/%s' -name '*.ko' -exec strip --strip-debug {} + 2>/dev/null",
            destdir, kernel_release), true)
    end

    -- bzImage / System.map / .config
    local bzimage = kernel_src_path .. "/arch/x86/boot/bzImage"
    Utils.run_or_die(
        string.format("cp '%s' '%s/boot/vmlinuz-%s'", bzimage, destdir, kernel_release))
    Utils.run(string.format("cp '%s/System.map' '%s/boot/System.map-%s'",
        kernel_src_path, destdir, kernel_release))
    Utils.run(string.format("cp '%s/.config' '%s/boot/config-%s'",
        kernel_src_path, destdir, kernel_release))

    Utils.ok("Instalacja do DESTDIR zakonczona. kernel-release=" .. kernel_release)
    return kernel_release
end

--- Krok 4: instalacja naglowkow do odrebnego HEADERS_DESTDIR
-- (potrzebne do zbudowania odrebnego pakietu linux-headers-* dla DKMS).
function Compile.install_headers_to_destdir(cfg, kernel_src_path, headers_destdir, kernel_release)
    if not (cfg.headers_package and cfg.headers_package.enabled) then
        Utils.info("Pakiet naglowkow wylaczony (headers_package.enabled=false).")
        return false
    end

    local jobs = resolve_jobs(cfg.build)

    Utils.mkdir_p(headers_destdir)

    local hdr_install_dir = string.format(
        "%s/usr/src/linux-headers-%s", headers_destdir, kernel_release)
    Utils.mkdir_p(hdr_install_dir)

    Utils.log("Instalacja naglowkow jadra do " .. hdr_install_dir .. " ...")
    Utils.run_or_die(
        string.format("cd '%s' && make -j%d INSTALL_HDR_PATH='%s/usr' headers_install",
            kernel_src_path, jobs, headers_destdir),
        "make headers_install nie powiodlo sie.")

    -- kopiujemy .config i Module.symvers (potrzebne do budowy modulow out-of-tree)
    Utils.run(string.format("cp '%s/.config' '%s/'", kernel_src_path, hdr_install_dir))
    Utils.run(string.format("cp '%s/Module.symvers' '%s/' 2>/dev/null || true",
        kernel_src_path, hdr_install_dir))

    -- sign-file binary (do podpisywania modulow z DKMS)
    local sign_file_src = kernel_src_path .. "/scripts/sign-file"
    local sign_file_dest = hdr_install_dir .. "/scripts"
    Utils.mkdir_p(sign_file_dest)
    if Utils.file_exists(sign_file_src) then
        Utils.run(string.format("cp '%s' '%s/'", sign_file_src, sign_file_dest))
        Utils.run(string.format("chmod 0755 '%s/sign-file'", sign_file_dest))
    end

    -- symlink /usr/src/linux-headers-<release>/build -> siebie (konwencja Debiana)
    Utils.run(string.format("ln -sfn '%s' '%s/build'",
        hdr_install_dir, hdr_install_dir))

    Utils.ok("Naglowki zainstalowane w " .. hdr_install_dir)
    return true
end

return Compile
