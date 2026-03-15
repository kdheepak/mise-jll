local archiver = require("archiver")
local env = require("env")
local file = require("file")
local http = require("http")
local json = require("json")

local M = {}

local GENERAL_BASE = "https://raw.githubusercontent.com/JuliaRegistries/General/master"
local RAW_GITHUB_BASE = "https://raw.githubusercontent.com"
local BRANCH_CANDIDATES = { "main", "master" }
local QUALIFIER_KEYS = {
    "os",
    "arch",
    "libc",
    "call_abi",
    "cxxstring_abi",
    "libgfortran_version",
}
local ARTIFACT_METADATA_KEYS = {
    _artifact_name = true,
    downloads = true,
    ["git-tree-sha1"] = true,
    lazy = true,
}
local QUALIFIER_KEY_SET = {}
for _, key in ipairs(QUALIFIER_KEYS) do
    QUALIFIER_KEY_SET[key] = true
end

local raw_cache = {}
local registry_cache = {}
local package_cache = {}
local artifacts_cache = {}
local wrapper_deps_cache = {}

local function get_env(name)
    if env and type(env.getenv) == "function" then
        return env.getenv(name)
    end
    if os and type(os.getenv) == "function" then
        return os.getenv(name)
    end
    return nil
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

local function ends_with(s, suffix)
    return suffix == "" or s:sub(-#suffix) == suffix
end

local function split_lines(content)
    local lines = {}
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        table.insert(lines, line)
    end
    return lines
end

local function split_top_level(str, delimiter)
    local parts = {}
    local current = {}
    local in_string = false
    local escape_next = false
    local depth = 0

    for i = 1, #str do
        local ch = str:sub(i, i)

        if in_string then
            table.insert(current, ch)
            if escape_next then
                escape_next = false
            elseif ch == "\\" then
                escape_next = true
            elseif ch == '"' then
                in_string = false
            end
        else
            if ch == '"' then
                in_string = true
                table.insert(current, ch)
            elseif ch == "[" then
                depth = depth + 1
                table.insert(current, ch)
            elseif ch == "]" then
                depth = depth - 1
                table.insert(current, ch)
            elseif ch == delimiter and depth == 0 then
                table.insert(parts, trim(table.concat(current)))
                current = {}
            else
                table.insert(current, ch)
            end
        end
    end

    local tail = trim(table.concat(current))
    if tail ~= "" then
        table.insert(parts, tail)
    end

    return parts
end

local function split_string(str, delimiter)
    local parts = {}
    local start = 1

    while true do
        local idx = str:find(delimiter, start, true)
        if idx == nil then
            local tail = str:sub(start)
            if tail ~= "" then
                table.insert(parts, tail)
            end
            break
        end

        local part = str:sub(start, idx - 1)
        if part ~= "" then
            table.insert(parts, part)
        end
        start = idx + #delimiter
    end

    return parts
end

local function strip_comments(line)
    local result = {}
    local in_string = false
    local escape_next = false

    for i = 1, #line do
        local ch = line:sub(i, i)
        if in_string then
            table.insert(result, ch)
            if escape_next then
                escape_next = false
            elseif ch == "\\" then
                escape_next = true
            elseif ch == '"' then
                in_string = false
            end
        else
            if ch == '"' then
                in_string = true
                table.insert(result, ch)
            elseif ch == "#" then
                break
            else
                table.insert(result, ch)
            end
        end
    end

    return trim(table.concat(result))
end

local function unescape_string(s)
    local body = s:sub(2, -2)
    body = body:gsub('\\"', '"')
    body = body:gsub("\\\\", "\\")
    return body
end

local function parse_key_name(raw)
    raw = trim(raw)
    if starts_with(raw, '"') and ends_with(raw, '"') then
        return unescape_string(raw)
    end
    return raw
end

local function parse_value(raw)
    raw = trim(raw)

    if raw == "" then
        return ""
    end

    if raw == "true" then
        return true
    end

    if raw == "false" then
        return false
    end

    if starts_with(raw, '"') and ends_with(raw, '"') then
        return unescape_string(raw)
    end

    if starts_with(raw, "[") and ends_with(raw, "]") then
        local inner = trim(raw:sub(2, -2))
        local values = {}
        if inner == "" then
            return values
        end
        for _, part in ipairs(split_top_level(inner, ",")) do
            table.insert(values, parse_value(part))
        end
        return values
    end

    local num = tonumber(raw)
    if num ~= nil then
        return num
    end

    return raw
end

local function parse_key_value(line)
    local in_string = false
    local escape_next = false
    local depth = 0

    for i = 1, #line do
        local ch = line:sub(i, i)
        if in_string then
            if escape_next then
                escape_next = false
            elseif ch == "\\" then
                escape_next = true
            elseif ch == '"' then
                in_string = false
            end
        else
            if ch == '"' then
                in_string = true
            elseif ch == "[" then
                depth = depth + 1
            elseif ch == "]" then
                depth = depth - 1
            elseif ch == "=" and depth == 0 then
                local key = trim(line:sub(1, i - 1))
                local value = trim(line:sub(i + 1))
                return key, value
            end
        end
    end

    error("invalid TOML assignment: " .. line)
end

local function parse_header_parts(header)
    local parts = split_top_level(header, ".")
    for i, part in ipairs(parts) do
        parts[i] = parse_key_name(part)
    end
    return parts
end

local function parse_simple_toml(content)
    local root = {}
    local current = root

    for _, raw_line in ipairs(split_lines(content)) do
        local line = strip_comments(raw_line)
        if line ~= "" then
            local array_header = line:match("^%[%[(.-)%]%]$")
            if array_header then
                error("array-of-tables are not supported by parse_simple_toml: " .. array_header)
            end

            local header = line:match("^%[(.-)%]$")
            if header then
                current = root
                for _, part in ipairs(parse_header_parts(header)) do
                    current[part] = current[part] or {}
                    current = current[part]
                end
            else
                local key, value = parse_key_value(line)
                current[parse_key_name(key)] = parse_value(value)
            end
        end
    end

    return root
end

local function parse_artifacts_toml(content)
    local entries = {}
    local current_entry = nil
    local current_table = nil

    for _, raw_line in ipairs(split_lines(content)) do
        local line = strip_comments(raw_line)
        if line ~= "" then
            local array_header = line:match("^%[%[(.-)%]%]$")
            if array_header then
                local parts = parse_header_parts(array_header)
                if #parts == 1 then
                    current_entry = {
                        _artifact_name = parts[1],
                        downloads = {},
                    }
                    table.insert(entries, current_entry)
                    current_table = current_entry
                elseif #parts == 2 and parts[2] == "download" then
                    if current_entry == nil or current_entry._artifact_name ~= parts[1] then
                        error("encountered download table before parent artifact table")
                    end
                    local download = {}
                    table.insert(current_entry.downloads, download)
                    current_table = download
                else
                    error("unsupported Artifacts.toml array header: " .. array_header)
                end
            else
                local key, value = parse_key_value(line)
                if current_table == nil then
                    error("encountered assignment outside of an artifact table")
                end
                current_table[parse_key_name(key)] = parse_value(value)
            end
        end
    end

    return entries
end

local function parse_version(version)
    version = trim(version)
    version = version:gsub("^v", "")

    local main, build = version:match("^([^+]+)%+(.+)$")
    if not main then
        main = version
    end

    local parts = {}
    for piece in main:gmatch("[^.]+") do
        table.insert(parts, tonumber(piece) or 0)
    end
    while #parts < 3 do
        table.insert(parts, 0)
    end

    local build_parts = {}
    if build then
        for piece in build:gmatch("[^.]+") do
            table.insert(build_parts, tonumber(piece) or 0)
        end
    end

    return {
        raw = version,
        parts = parts,
        build = build_parts,
    }
end

local function compare_int_vectors(a, b)
    local len = math.max(#a, #b)
    for i = 1, len do
        local av = a[i] or 0
        local bv = b[i] or 0
        if av < bv then
            return -1
        end
        if av > bv then
            return 1
        end
    end
    return 0
end

local function compare_versions(a, b)
    local va = type(a) == "table" and a or parse_version(a)
    local vb = type(b) == "table" and b or parse_version(b)

    local cmp = compare_int_vectors(va.parts, vb.parts)
    if cmp ~= 0 then
        return cmp
    end

    return compare_int_vectors(va.build, vb.build)
end

local function version_key(version)
    local parsed = parse_version(version)
    local key_parts = {
        string.format("%08d", parsed.parts[1]),
        string.format("%08d", parsed.parts[2]),
        string.format("%08d", parsed.parts[3]),
    }
    for i = 1, math.max(1, #parsed.build) do
        table.insert(key_parts, string.format("%08d", parsed.build[i] or 0))
    end
    return table.concat(key_parts, ".")
end

local function sort_versions_desc(versions)
    table.sort(versions, function(a, b)
        local left = type(a) == "table" and a.version or a
        local right = type(b) == "table" and b.version or b
        return compare_versions(left, right) > 0
    end)
    return versions
end

local function make_exact_interval(version)
    local parsed = parse_version(version)
    local upper = {
        parts = { parsed.parts[1], parsed.parts[2], parsed.parts[3] },
        build = {},
    }
    if #parsed.build > 0 then
        for i, part in ipairs(parsed.build) do
            upper.build[i] = part
        end
        upper.build[#upper.build] = upper.build[#upper.build] + 1
    else
        upper.parts[3] = upper.parts[3] + 1
    end
    return {
        lower = parsed,
        upper = upper,
    }
end

local function normalize_endpoint(text, is_upper)
    text = trim(text)
    if text == "*" then
        return nil
    end

    local parts = {}
    for piece in text:gmatch("[^.]+") do
        table.insert(parts, tonumber(piece) or 0)
    end

    while #parts < 3 do
        table.insert(parts, 0)
    end

    if not is_upper then
        return {
            parts = parts,
            build = {},
        }
    end

    local original_length = 0
    for _ in text:gmatch("[^.]+") do
        original_length = original_length + 1
    end

    if original_length == 0 then
        return nil
    end

    parts[original_length] = parts[original_length] + 1
    for i = original_length + 1, 3 do
        parts[i] = 0
    end

    return {
        parts = parts,
        build = {},
    }
end

local function parse_registry_interval(expr)
    expr = trim(expr)
    if expr == "*" then
        return { lower = nil, upper = nil }
    end

    local dash = expr:find("%-")
    if dash then
        local lower_text = expr:sub(1, dash - 1)
        local upper_text = expr:sub(dash + 1)
        return {
            lower = normalize_endpoint(lower_text, false),
            upper = normalize_endpoint(upper_text, true),
        }
    end

    return {
        lower = normalize_endpoint(expr, false),
        upper = normalize_endpoint(expr, true),
    }
end

local function parse_constraint_value(value)
    local intervals = {}

    if type(value) == "string" then
        table.insert(intervals, parse_registry_interval(value))
    elseif type(value) == "table" then
        for _, item in ipairs(value) do
            table.insert(intervals, parse_registry_interval(item))
        end
    else
        error("unsupported compat value type: " .. type(value))
    end

    return intervals
end

local function compare_optional_versions(a, b)
    if a == nil and b == nil then
        return 0
    end
    if a == nil then
        return -1
    end
    if b == nil then
        return 1
    end
    return compare_versions(a, b)
end

local function max_version(a, b)
    if compare_optional_versions(a, b) >= 0 then
        return a
    end
    return b
end

local function min_version(a, b)
    if compare_optional_versions(a, b) <= 0 then
        return a
    end
    return b
end

local function intersect_constraints(a, b)
    if a == nil then
        return b
    end
    if b == nil then
        return a
    end

    local intersection = {}
    for _, left in ipairs(a) do
        for _, right in ipairs(b) do
            local lower = max_version(left.lower, right.lower)
            local upper = min_version(left.upper, right.upper)
            local valid = upper == nil or lower == nil or compare_versions(lower, upper) < 0
            if valid then
                table.insert(intersection, {
                    lower = lower,
                    upper = upper,
                })
            end
        end
    end

    return intersection
end

local function version_satisfies_constraint(version, constraint)
    if constraint == nil then
        return true
    end

    local parsed = type(version) == "table" and version or parse_version(version)

    for _, interval in ipairs(constraint) do
        local lower_ok = interval.lower == nil or compare_versions(parsed, interval.lower) >= 0
        local upper_ok = interval.upper == nil or compare_versions(parsed, interval.upper) < 0
        if lower_ok and upper_ok then
            return true
        end
    end

    return false
end

local function shell_quote(str)
    return "'" .. tostring(str):gsub("'", [['"'"']]) .. "'"
end

local function path_list_separator()
    return ":"
end

local function dirname(path)
    local normalized = tostring(path):gsub("[/\\]+$", "")
    local parent = normalized:match("^(.*)[/\\][^/\\]+$")
    return parent
end

local function concrete_install_path(install_path, exact_version)
    local parent = dirname(install_path)
    if not parent or parent == "" then
        return install_path
    end

    local concrete = file.join_path(parent, exact_version)
    return concrete
end

local function command_status_ok(first, second, third)
    if type(first) == "number" then
        return first == 0, first
    end
    if first == true then
        return true, third or 0
    end
    return false, third or second or first
end

local function unix_shell_command(command)
    return "/bin/sh -lc " .. shell_quote("cd / >/dev/null 2>&1 && " .. command)
end

local function exec_fs_command(command)
    local handle, popen_err = io.popen(unix_shell_command(command) .. " 2>&1")
    if not handle then
        error("Failed to execute command: " .. tostring(popen_err))
    end

    local ok, output = pcall(handle.read, handle, "*a")
    local close_first, close_second, close_third = handle:close()
    local success, code = command_status_ok(close_first, close_second, close_third)
    if not ok then
        error("Failed to execute command: " .. tostring(output))
    end
    if not success then
        local detail = trim(output or "")
        if detail == "" then
            detail = "exit status: " .. tostring(code)
        end
        error("Command failed with status exit status: " .. tostring(code) .. ": " .. detail)
    end

    return output or ""
end

local function sleep_seconds(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        return
    end

    os.execute("sleep " .. tostring(seconds))
end

local function retry_count(env_name, default_value)
    local raw = get_env(env_name) or nil
    local value = tonumber(raw)
    if value and value >= 1 then
        return math.floor(value)
    end
    return default_value
end

local function retry_delay(env_name, default_value)
    local raw = get_env(env_name) or nil
    local value = tonumber(raw)
    if value and value >= 0 then
        return value
    end
    return default_value
end

local function is_retryable_http_failure(err, status_code)
    if status_code and (status_code == 429 or status_code >= 500) then
        return true
    end

    local message = tostring(err or ""):lower()
    local needles = {
        "429",
        "500",
        "502",
        "503",
        "504",
        "bad gateway",
        "server error",
        "timed out",
        "timeout",
        "connection reset",
        "connection refused",
        "connection aborted",
        "broken pipe",
        "unexpected eof",
        "temporary failure",
    }
    for _, needle in ipairs(needles) do
        if message:find(needle, 1, true) then
            return true
        end
    end

    return false
end

local function best_effort_fs_command(path, command)
    local ok, result = pcall(exec_fs_command, command)
    if ok then
        return true, result
    end

    return false, result
end

local function mkdir_p(path)
    local command = "mkdir -p " .. shell_quote(path)
    local ok, result = pcall(exec_fs_command, command)
    if ok then
        return
    end

    error(result)
end

local function remove_path(path)
    best_effort_fs_command(path, "rm -rf " .. shell_quote(path))
end

local function remove_symlink(path)
    best_effort_fs_command(path, "test -L " .. shell_quote(path) .. " && rm -f " .. shell_quote(path) .. " || true")
end

local function remove_file(path)
    best_effort_fs_command(path, "rm -f " .. shell_quote(path))
end

local function write_file(path, content)
    local parent = dirname(path)
    if parent and parent ~= "" then
        mkdir_p(parent)
    end

    local handle, err = io.open(path, "wb")
    if not handle then
        error("failed to open " .. path .. " for writing: " .. tostring(err))
    end
    handle:write(content)
    handle:close()
end

local function url_encode_path_segment(segment)
    return (segment:gsub("([^%w%-%._~])", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

local function fetch_text(url, opts)
    opts = opts or {}

    if raw_cache[url] ~= nil then
        return raw_cache[url]
    end

    local attempts = retry_count("MISE_JLL_HTTP_RETRIES", 4)
    local delay_seconds = retry_delay("MISE_JLL_HTTP_RETRY_DELAY", 1)
    local last_err = nil
    local last_status = nil

    for attempt = 1, attempts do
        local resp, err = http.get({ url = url })
        if not err then
            if resp.status_code == 404 and opts.allow_404 then
                raw_cache[url] = nil
                return nil
            end

            if resp.status_code == 200 then
                raw_cache[url] = resp.body
                return resp.body
            end

            last_status = resp.status_code
            last_err = "unexpected HTTP status " .. tostring(resp.status_code) .. " for " .. url
            if attempt < attempts and is_retryable_http_failure(last_err, resp.status_code) then
                sleep_seconds(delay_seconds * (2 ^ (attempt - 1)))
            else
                break
            end
        else
            last_err = "failed to fetch " .. url .. ": " .. tostring(err)
            if attempt < attempts and is_retryable_http_failure(err, last_status) then
                sleep_seconds(delay_seconds * (2 ^ (attempt - 1)))
            else
                break
            end
        end
    end

    if last_status and not is_retryable_http_failure(last_err, last_status) then
        error(last_err)
    end
    error(last_err or ("failed to fetch " .. url))
end

local function download_file(url, path)
    local parent = dirname(path)
    if parent and parent ~= "" then
        mkdir_p(parent)
    end

    local attempts = retry_count("MISE_JLL_DOWNLOAD_RETRIES", 4)
    local delay_seconds = retry_delay("MISE_JLL_DOWNLOAD_RETRY_DELAY", 1)
    local last_err = nil

    for attempt = 1, attempts do
        remove_file(path)
        local _, err = http.download_file({ url = url }, path)
        if not err then
            return
        end

        last_err = err
        remove_file(path)
        if attempt < attempts and is_retryable_http_failure(err) then
            sleep_seconds(delay_seconds * (2 ^ (attempt - 1)))
        else
            break
        end
    end

    error("failed to download " .. url .. ": " .. tostring(last_err))
end

local function sha256_file(path)
    local commands = {
        "/usr/bin/shasum -a 256 " .. shell_quote(path),
        "/sbin/sha256sum " .. shell_quote(path),
        "shasum -a 256 " .. shell_quote(path),
        "sha256sum " .. shell_quote(path),
    }

    local function extract_hash(output)
        for token in tostring(output):gmatch("([0-9a-fA-F]+)") do
            if #token >= 64 then
                return token
            end
        end
        return nil
    end

    if not file.exists(path) then
        return nil
    end

    for _, command in ipairs(commands) do
        local ok, output = pcall(exec_fs_command, command)
        if ok then
            local hash = extract_hash(output)
            if hash and hash ~= "" then
                return trim(hash)
            end
        end
    end

    return nil
end

local function verify_sha256(path, expected)
    if not expected or expected == "" then
        return
    end

    local actual = sha256_file(path)
    if not actual or actual == "" then
        error("unable to compute SHA-256 for " .. path)
    end

    if actual:lower() ~= expected:lower() then
        error("checksum mismatch for " .. path .. ": expected " .. expected .. " but got " .. actual)
    end
end

local function unique_list(values)
    local seen = {}
    local result = {}
    for _, value in ipairs(values) do
        if value ~= "" and not seen[value] then
            seen[value] = true
            table.insert(result, value)
        end
    end
    return result
end

local function sorted_keys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

local function host_lib_env()
    local os_type = (RUNTIME.osType or ""):lower()
    if os_type == "darwin" then
        return "DYLD_FALLBACK_LIBRARY_PATH"
    end
    if os_type == "linux" then
        return "LD_LIBRARY_PATH"
    end
    error("unsupported operating system for jll backend: " .. tostring(RUNTIME.osType))
end

local function normalize_arch(arch)
    arch = (arch or ""):lower()
    local mapping = {
        amd64 = "x86_64",
        x64 = "x86_64",
        x86_64 = "x86_64",
        i386 = "i686",
        i686 = "i686",
        x86 = "i686",
        ["386"] = "i686",
        arm64 = "aarch64",
        aarch64 = "aarch64",
    }
    return mapping[arch]
end

local function normalize_os(os_type)
    os_type = (os_type or ""):lower()
    local mapping = {
        darwin = "macos",
        macos = "macos",
        linux = "linux",
    }
    return mapping[os_type]
end

local function detect_host_traits()
    local os_name = normalize_os(RUNTIME.osType)
    if not os_name then
        error("unsupported operating system for jll backend: " .. tostring(RUNTIME.osType))
    end

    local arch_name = normalize_arch(RUNTIME.archType)
    if not arch_name then
        error("unsupported architecture for jll backend: " .. tostring(RUNTIME.archType))
    end

    local traits = {
        os = os_name,
        arch = arch_name,
    }

    if os_name == "linux" then
        local env_type = (RUNTIME.envType or ""):lower()
        if env_type == "gnu" then
            traits.libc = "glibc"
        elseif env_type == "musl" then
            traits.libc = "musl"
        end
    end

    local libc_override = get_env("MISE_JLL_LIBC")
    local call_abi_override = get_env("MISE_JLL_CALL_ABI")
    local cxxstring_override = get_env("MISE_JLL_CXXSTRING_ABI")
    local libgfortran_override = get_env("MISE_JLL_LIBGFORTRAN_VERSION")

    if libc_override and libc_override ~= "" then
        traits.libc = libc_override
    end
    if call_abi_override and call_abi_override ~= "" then
        traits.call_abi = call_abi_override
    end
    if cxxstring_override and cxxstring_override ~= "" then
        traits.cxxstring_abi = cxxstring_override
    end
    if libgfortran_override and libgfortran_override ~= "" then
        traits.libgfortran_version = libgfortran_override
    end

    return traits
end

local function is_jll_package(name)
    return ends_with(name, "_jll")
end

local function registry_path_for_package(package_name)
    local first = package_name:sub(1, 1):upper()
    return GENERAL_BASE .. "/jll/" .. first .. "/" .. package_name
end

local function fetch_package_registry(package_name)
    if registry_cache[package_name] then
        return registry_cache[package_name]
    end

    local base = registry_path_for_package(package_name)
    local package_toml = parse_simple_toml(fetch_text(base .. "/Package.toml"))
    local versions_toml = parse_simple_toml(fetch_text(base .. "/Versions.toml"))

    local deps_toml = {}
    local compat_toml = {}
    local deps_text = fetch_text(base .. "/Deps.toml", { allow_404 = true })
    if deps_text then
        deps_toml = parse_simple_toml(deps_text)
    end

    local compat_text = fetch_text(base .. "/Compat.toml", { allow_404 = true })
    if compat_text then
        compat_toml = parse_simple_toml(compat_text)
    end

    local versions = {}
    local version_map = {}
    for version, info in pairs(versions_toml) do
        local item = {
            version = version,
            yanked = info.yanked == true,
            git_tree_sha1 = info["git-tree-sha1"],
        }
        version_map[version] = item
        table.insert(versions, item)
    end
    sort_versions_desc(versions)

    local deps_sections = {}
    for expr, info in pairs(deps_toml) do
        table.insert(deps_sections, {
            constraint = { parse_registry_interval(expr) },
            deps = info,
        })
    end

    local compat_sections = {}
    for expr, info in pairs(compat_toml) do
        table.insert(compat_sections, {
            constraint = { parse_registry_interval(expr) },
            compat = info,
        })
    end

    local registry = {
        package_name = package_name,
        repo_url = package_toml.repo,
        uuid = package_toml.uuid,
        versions = versions,
        version_map = version_map,
        deps_sections = deps_sections,
        compat_sections = compat_sections,
    }

    registry_cache[package_name] = registry
    return registry
end

local function package_metadata_for_version(package_name, version)
    local cache_key = package_name .. "@" .. version
    if package_cache[cache_key] then
        return package_cache[cache_key]
    end

    local registry = fetch_package_registry(package_name)
    local version_info = registry.version_map[version]
    if not version_info then
        error("version " .. version .. " not found for " .. package_name)
    end

    local deps = {}
    for _, section in ipairs(registry.deps_sections) do
        if version_satisfies_constraint(version, section.constraint) then
            for dep_name, dep_uuid in pairs(section.deps) do
                deps[dep_name] = dep_uuid
            end
        end
    end

    local compat = {}
    for _, section in ipairs(registry.compat_sections) do
        if version_satisfies_constraint(version, section.constraint) then
            for dep_name, raw_constraint in pairs(section.compat) do
                if is_jll_package(dep_name) then
                    local parsed = parse_constraint_value(raw_constraint)
                    compat[dep_name] = intersect_constraints(compat[dep_name], parsed)
                end
            end
        end
    end

    local metadata = {
        package_name = package_name,
        version = version,
        repo_url = registry.repo_url,
        git_tree_sha1 = version_info.git_tree_sha1,
        deps = deps,
        compat = compat,
        yanked = version_info.yanked,
    }

    package_cache[cache_key] = metadata
    return metadata
end

local function canonical_root_package(tool)
    local normalized = trim(tool)
    normalized = normalized:gsub("%.jl$", "")
    normalized = normalized:gsub("%-", "_")

    if not ends_with(normalized, "_jll") then
        normalized = normalized .. "_jll"
    end

    local repo_name = normalized .. ".jl"
    for _, branch in ipairs(BRANCH_CANDIDATES) do
        local url = RAW_GITHUB_BASE .. "/JuliaBinaryWrappers/" .. repo_name .. "/" .. branch .. "/Project.toml"
        local project_toml = fetch_text(url, { allow_404 = true })
        if project_toml then
            local parsed = parse_simple_toml(project_toml)
            if parsed.name and parsed.name ~= "" then
                return parsed.name
            end
        end
    end

    error("unable to resolve JLL package for tool " .. tool)
end

local function available_versions(package_name)
    local registry = fetch_package_registry(package_name)
    local versions = {}
    for _, info in ipairs(registry.versions) do
        if not info.yanked then
            table.insert(versions, info.version)
        end
    end
    return versions
end

local function resolve_requested_version(package_name, requested)
    local versions = available_versions(package_name)
    if #versions == 0 then
        error("no non-yanked versions found for " .. package_name)
    end

    if requested == nil or requested == "" or requested == "latest" then
        return versions[1]
    end

    for _, version in ipairs(versions) do
        if version == requested then
            return version
        end
    end

    if not requested:find("%+") then
        local prefix = requested .. "+"
        for _, version in ipairs(versions) do
            if version == requested or starts_with(version, prefix) then
                return version
            end
        end
    end

    error("version " .. requested .. " not found for " .. package_name)
end

local function candidate_versions_for_package(package_name, constraint)
    local versions = available_versions(package_name)
    local candidates = {}
    for _, version in ipairs(versions) do
        if version_satisfies_constraint(version, constraint) then
            table.insert(candidates, version)
        end
    end
    return candidates
end

local function shallow_copy(tbl)
    local copy = {}
    for key, value in pairs(tbl) do
        copy[key] = value
    end
    return copy
end

local function resolve_package(package_name, constraint, state)
    local selected_version = state.selected[package_name]
    if selected_version then
        if version_satisfies_constraint(selected_version, constraint) then
            return state
        end
        return nil
    end

    local candidates = candidate_versions_for_package(package_name, constraint)
    for _, version in ipairs(candidates) do
        local next_state = {
            selected = shallow_copy(state.selected),
        }
        next_state.selected[package_name] = version

        local metadata = package_metadata_for_version(package_name, version)
        local ok = true

        for _, dep_name in ipairs(sorted_keys(metadata.deps)) do
            if is_jll_package(dep_name) then
                local dep_constraint = metadata.compat[dep_name]
                local resolved = resolve_package(dep_name, dep_constraint, next_state)
                if resolved == nil then
                    ok = false
                    break
                end
                next_state = resolved
            end
        end

        if ok then
            return next_state
        end
    end

    return nil
end

local function topological_order(root_package, selection)
    local visited = {}
    local order = {}

    local function visit(package_name)
        if visited[package_name] then
            return
        end
        visited[package_name] = true

        local metadata = package_metadata_for_version(package_name, selection[package_name])
        for _, dep_name in ipairs(sorted_keys(metadata.deps)) do
            if is_jll_package(dep_name) and selection[dep_name] then
                visit(dep_name)
            end
        end

        table.insert(order, package_name)
    end

    visit(root_package)
    return order
end

local function repo_owner_and_name(repo_url)
    local owner, repo = repo_url:match("github%.com/([^/]+)/([^/]+)%.git$")
    if owner and repo then
        return owner, repo
    end

    owner, repo = repo_url:match("github%.com/([^/]+)/([^/]+)$")
    if owner and repo then
        return owner, repo
    end

    error("unsupported repository URL: " .. tostring(repo_url))
end

local function artifact_tag(package_name, version)
    return package_name:gsub("_jll$", "") .. "-v" .. version
end

local function artifacts_for_package_version(package_name, version)
    local cache_key = package_name .. "@" .. version
    if artifacts_cache[cache_key] then
        return artifacts_cache[cache_key]
    end

    local registry = fetch_package_registry(package_name)
    local owner, repo = repo_owner_and_name(registry.repo_url)
    local tag = url_encode_path_segment(artifact_tag(package_name, version))
    local url = RAW_GITHUB_BASE .. "/" .. owner .. "/" .. repo .. "/" .. tag .. "/Artifacts.toml"
    local entries = parse_artifacts_toml(fetch_text(url))
    artifacts_cache[cache_key] = entries
    return entries
end

local function artifact_traits(entry)
    local traits = {}
    for key, value in pairs(entry) do
        if not ARTIFACT_METADATA_KEYS[key] then
            traits[key] = value
        end
    end
    return traits
end

local function artifact_qualifier_keys(entry)
    local keys = {}
    for key in pairs(entry) do
        if not ARTIFACT_METADATA_KEYS[key] then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    return keys
end

local function traits_match(entry, traits)
    if entry.os ~= traits.os or entry.arch ~= traits.arch then
        return false
    end

    for _, key in ipairs(artifact_qualifier_keys(entry)) do
        if key ~= "os" and key ~= "arch" then
            if QUALIFIER_KEY_SET[key] then
                if entry[key] ~= nil and traits[key] ~= nil and entry[key] ~= traits[key] then
                    return false
                end
            elseif traits[key] ~= entry[key] then
                return false
            end
        end
    end

    return true
end

local function matching_artifacts_for_package_version(package_name, version, traits)
    local matches = {}
    for _, entry in ipairs(artifacts_for_package_version(package_name, version)) do
        if traits_match(entry, traits) then
            table.insert(matches, entry)
        end
    end
    return matches
end

local function specificity_score(entry)
    local count = 0
    for _, key in ipairs(artifact_qualifier_keys(entry)) do
        if key ~= "os" and key ~= "arch" and entry[key] ~= nil then
            count = count + 1
        end
    end
    return count
end

local function artifact_score(entry)
    local cxx_score = 0
    if entry.cxxstring_abi == "cxx11" then
        cxx_score = 2
    elseif entry.cxxstring_abi == "cxx03" then
        cxx_score = 1
    end

    local gfortran_score = entry.libgfortran_version and version_key(entry.libgfortran_version)
        or "00000000.00000000.00000000.00000000"

    return {
        cxx_score = cxx_score,
        gfortran_score = gfortran_score,
        specificity = specificity_score(entry),
    }
end

local function compare_artifact_scores(left, right)
    if left.cxx_score ~= right.cxx_score then
        return left.cxx_score > right.cxx_score
    end
    if left.gfortran_score ~= right.gfortran_score then
        return left.gfortran_score > right.gfortran_score
    end
    if left.specificity ~= right.specificity then
        return left.specificity > right.specificity
    end
    return false
end

local function describe_artifact(entry)
    local parts = {
        entry.os,
        entry.arch,
    }
    for _, key in ipairs(artifact_qualifier_keys(entry)) do
        if key ~= "os" and key ~= "arch" and entry[key] then
            table.insert(parts, key .. "=" .. entry[key])
        end
    end
    return table.concat(parts, ", ")
end

local function select_artifact(package_name, version, traits)
    local matches = matching_artifacts_for_package_version(package_name, version, traits)

    if #matches == 0 then
        error("no matching artifact found for " .. package_name .. "@" .. version)
    end

    if #matches == 1 then
        return matches[1]
    end

    table.sort(matches, function(a, b)
        return compare_artifact_scores(artifact_score(a), artifact_score(b))
    end)

    if #matches >= 2 then
        local first = artifact_score(matches[1])
        local second = artifact_score(matches[2])
        local tied = first.cxx_score == second.cxx_score
            and first.gfortran_score == second.gfortran_score
            and first.specificity == second.specificity
        if tied then
            error(
                "ambiguous artifact selection for "
                    .. package_name
                    .. "@"
                    .. version
                    .. "; set MISE_JLL_CXXSTRING_ABI or MISE_JLL_LIBGFORTRAN_VERSION. Candidates: "
                    .. describe_artifact(matches[1])
                    .. " | "
                    .. describe_artifact(matches[2])
            )
        end
    end

    return matches[1]
end

local function has_matching_artifact(package_name, version, traits)
    return #matching_artifacts_for_package_version(package_name, version, traits) > 0
end

local function artifact_download_url(entry)
    if not entry.downloads or #entry.downloads == 0 then
        error("artifact entry is missing download metadata")
    end
    return entry.downloads[1].url
end

local function wrapper_triplet_from_artifact(entry)
    local url = artifact_download_url(entry)
    local filename = url:match("/([^/]+)$")
    if not filename then
        error("unable to determine wrapper triplet from " .. url)
    end

    local stem = filename
    stem = stem:gsub("%.tar%.gz$", "")
    stem = stem:gsub("%.tar%.xz$", "")
    stem = stem:gsub("%.tar%.bz2$", "")
    stem = stem:gsub("%.tar%.zst$", "")
    stem = stem:gsub("%.zip$", "")

    local arch = entry.arch
    if not arch or arch == "" then
        error("artifact entry is missing arch qualifier for " .. url)
    end

    local marker = "." .. arch .. "-"
    local triplet_start = stem:find(marker, 1, true)
    if not triplet_start then
        error("unexpected artifact filename format: " .. filename)
    end

    return stem:sub(triplet_start + 1)
end

local function wrapper_deps_for_package_version(package_name, version, traits)
    local artifact = select_artifact(package_name, version, traits)
    local triplet = wrapper_triplet_from_artifact(artifact)
    local cache_key = package_name .. "@" .. version .. "#" .. triplet
    if wrapper_deps_cache[cache_key] ~= nil then
        return wrapper_deps_cache[cache_key]
    end

    local registry = fetch_package_registry(package_name)
    local owner, repo = repo_owner_and_name(registry.repo_url)
    local tag = url_encode_path_segment(artifact_tag(package_name, version))
    local url = RAW_GITHUB_BASE .. "/" .. owner .. "/" .. repo .. "/" .. tag .. "/src/wrappers/" .. triplet .. ".jl"
    local content = fetch_text(url, { allow_404 = true })
    if not content then
        wrapper_deps_cache[cache_key] = nil
        return nil
    end

    local deps = {}
    local seen = {}
    for _, line in ipairs(split_lines(content)) do
        local dep_name = trim(line):match("^using%s+([%w_]+_jll)%s*$")
        if dep_name and not seen[dep_name] then
            seen[dep_name] = true
            table.insert(deps, dep_name)
        end
    end

    wrapper_deps_cache[cache_key] = deps
    return deps
end

local function active_install_order(root_package, selection, traits)
    local visited = {}
    local order = {}

    local function visit(package_name)
        if visited[package_name] then
            return
        end

        local version = selection[package_name]
        if not version then
            return
        end

        if package_name ~= root_package and not has_matching_artifact(package_name, version, traits) then
            return
        end

        visited[package_name] = true

        local metadata = package_metadata_for_version(package_name, version)
        local deps = wrapper_deps_for_package_version(package_name, version, traits)
        if deps == nil then
            deps = {}
            for _, dep_name in ipairs(sorted_keys(metadata.deps)) do
                if is_jll_package(dep_name) and selection[dep_name] then
                    table.insert(deps, dep_name)
                end
            end
        end

        for _, dep_name in ipairs(deps) do
            if selection[dep_name] then
                visit(dep_name)
            end
        end

        table.insert(order, package_name)
    end

    visit(root_package)
    return order
end

local function merge_traits(base, artifact)
    local merged = shallow_copy(base)
    for _, key in ipairs(artifact_qualifier_keys(artifact)) do
        local value = artifact[key]
        if value ~= nil then
            if merged[key] ~= nil and merged[key] ~= value then
                error(
                    "artifact qualifier conflict for "
                        .. key
                        .. ": "
                        .. tostring(merged[key])
                        .. " vs "
                        .. tostring(value)
                )
            end
            merged[key] = value
        end
    end
    return merged
end

local function select_download(entry)
    for _, download in ipairs(entry.downloads or {}) do
        if download.url and download.url ~= "" then
            return download
        end
    end
    error("artifact entry is missing download URLs")
end

local function archive_suffix(url)
    local suffixes = { ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".zip", ".tar" }
    for _, suffix in ipairs(suffixes) do
        if ends_with(url, suffix) then
            return suffix
        end
    end
    return ".archive"
end

local function extract_archive(archive_path, destination_dir)
    local command
    if ends_with(archive_path, ".zip") then
        command = "unzip -oq " .. shell_quote(archive_path) .. " -d " .. shell_quote(destination_dir)
    else
        command = "tar -xf " .. shell_quote(archive_path) .. " -C " .. shell_quote(destination_dir)
    end

    local ok, err = pcall(exec_fs_command, command)
    if ok then
        return
    end

    local fallback_ok, fallback_err = pcall(archiver.decompress, archive_path, destination_dir)
    if fallback_ok then
        return
    end

    error(
        "failed to extract artifact archive "
            .. archive_path
            .. " using "
            .. command
            .. ": "
            .. tostring(err)
            .. "; fallback failed: "
            .. tostring(fallback_err)
    )
end

local function install_artifact(entry, destination_dir)
    local download = select_download(entry)

    remove_path(destination_dir)
    remove_symlink(destination_dir)
    mkdir_p(destination_dir)
    local archive_path = destination_dir .. ".download" .. archive_suffix(download.url)
    download_file(download.url, archive_path)
    verify_sha256(archive_path, download.sha256)
    extract_archive(archive_path, destination_dir)
    remove_file(archive_path)
end

local function package_root(install_path, package_name)
    return file.join_path(install_path, "packages", package_name)
end

local function root_bin_path(install_path)
    return file.join_path(install_path, "bin")
end

local function link_root_bin(install_path, package_name)
    local package_bin = file.join_path(package_root(install_path, package_name), "bin")
    local install_bin = root_bin_path(install_path)

    remove_path(install_bin)
    remove_symlink(install_bin)
    remove_file(install_bin)
    if not file.exists(package_bin) then
        return
    end

    file.symlink(package_bin, install_bin)
end

local function collect_env_paths(install_path, order)
    local path_entries = {}
    local lib_entries = {}
    local install_bin = root_bin_path(install_path)

    if file.exists(install_bin) then
        table.insert(path_entries, install_bin)
    end

    for _, package_name in ipairs(order) do
        local root = package_root(install_path, package_name)
        local bin_dir = file.join_path(root, "bin")
        local lib_dir = file.join_path(root, "lib")
        local lib64_dir = file.join_path(root, "lib64")

        if file.exists(bin_dir) then
            table.insert(path_entries, bin_dir)
        end
        if file.exists(lib_dir) then
            table.insert(lib_entries, lib_dir)
        end
        if file.exists(lib64_dir) then
            table.insert(lib_entries, lib64_dir)
        end
    end

    return unique_list(path_entries), unique_list(lib_entries)
end

local function prepend_env_entries(entries, base_value)
    local merged = {}
    for _, value in ipairs(entries or {}) do
        table.insert(merged, value)
    end
    if base_value and base_value ~= "" then
        for _, value in ipairs(split_string(base_value, path_list_separator())) do
            table.insert(merged, value)
        end
    end
    return table.concat(unique_list(merged), path_list_separator())
end

local function write_manifest(install_path, manifest)
    local path = file.join_path(install_path, "manifest.json")
    write_file(path, json.encode(manifest))
end

function M.list_versions(tool)
    local package_name = canonical_root_package(tool)
    local versions = available_versions(package_name)
    table.sort(versions, function(a, b)
        return compare_versions(a, b) < 0
    end)
    return {
        package_name = package_name,
        versions = versions,
    }
end

function M.install(tool, requested_version, install_path)
    local root_package = canonical_root_package(tool)
    local root_version = resolve_requested_version(root_package, requested_version)
    local effective_install_path = concrete_install_path(install_path, root_version)
    local tool_install_root = dirname(effective_install_path)
    local traits = detect_host_traits()
    local root_artifact = select_artifact(root_package, root_version, traits)
    local resolved = resolve_package(root_package, { make_exact_interval(root_version) }, { selected = {} })
    if not resolved then
        error("failed to resolve dependencies for " .. root_package .. "@" .. root_version)
    end

    local resolved_traits = merge_traits(traits, root_artifact)
    local order = active_install_order(root_package, resolved.selected, resolved_traits)
    local artifact_selection = {}

    artifact_selection[root_package] = root_artifact
    traits = merge_traits(traits, root_artifact)

    for _, package_name in ipairs(order) do
        if package_name ~= root_package then
            local version = resolved.selected[package_name]
            local artifact = select_artifact(package_name, version, traits)
            artifact_selection[package_name] = artifact
            traits = merge_traits(traits, artifact)
        end
    end

    if tool_install_root and tool_install_root ~= "" then
        remove_symlink(tool_install_root)
        mkdir_p(tool_install_root)
    end
    remove_path(effective_install_path)
    remove_symlink(effective_install_path)
    mkdir_p(effective_install_path)
    local packages_path = file.join_path(effective_install_path, "packages")
    remove_path(packages_path)
    remove_symlink(packages_path)
    mkdir_p(packages_path)
    for _, package_name in ipairs(order) do
        install_artifact(artifact_selection[package_name], package_root(effective_install_path, package_name))
    end
    link_root_bin(effective_install_path, root_package)

    local path_entries, lib_entries = collect_env_paths(effective_install_path, order)
    local packages = {}
    for _, package_name in ipairs(order) do
        table.insert(packages, {
            package = package_name,
            version = resolved.selected[package_name],
            path = package_root(effective_install_path, package_name),
            artifact = artifact_traits(artifact_selection[package_name]),
        })
    end

    write_manifest(effective_install_path, {
        root_package = root_package,
        root_version = root_version,
        host_traits = traits,
        order = order,
        packages = packages,
        env = {
            path_entries = path_entries,
            lib_entries = lib_entries,
            lib_env = host_lib_env(),
        },
    })

    return {
        package_name = root_package,
        version = root_version,
        order = order,
        install_path = effective_install_path,
    }
end

function M.exec_env(install_path)
    local manifest_path = file.join_path(install_path, "manifest.json")
    if not file.exists(manifest_path) then
        return {}
    end

    local manifest = json.decode(file.read(manifest_path))
    local env_vars = {}
    local env_spec = manifest.env or {}
    local path_entries = env_spec.path_entries or {}
    local lib_entries = env_spec.lib_entries or {}
    local lib_env = env_spec.lib_env

    if #path_entries > 0 then
        table.insert(env_vars, {
            key = "PATH",
            value = prepend_env_entries(path_entries, get_env("PATH")),
        })
    end

    if lib_env and #lib_entries > 0 then
        local lib_value = prepend_env_entries(lib_entries, get_env(lib_env))
        table.insert(env_vars, {
            key = lib_env,
            value = lib_value,
        })
        table.insert(env_vars, {
            key = "JLL_" .. lib_env,
            value = lib_value,
        })
    end

    return env_vars
end

return M
