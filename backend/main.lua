local logger = require("logger")
local millennium = require("millennium")
local http = require("http")
local utils = require("utils")
local icons = require("icons")
local fs = require("fs")

local is_windows = package.config:sub(1, 1) == "\\"

local img_cache = {}
local img_size = {}
local img_pins = {}
local img_cleanup_pending = {}
local cache_order = {}
local cache_bytes = 0
local MAX_CACHED_IMAGES = 12
-- A generous safety ceiling for temporary downloads. A single larger image is
-- still retained until it is consumed; this limit only trims older, unused files.
local MAX_CACHED_BYTES = 128 * 1024 * 1024
local CHUNK_SIZE = 3 * 512 * 1024  -- 1.5 MB (multiple of 3 bytes so base64 chunks join cleanly)
local download_counter = 0

-- ---------------------------------------------------------------------------
-- Platform helpers (Windows / Linux / Steam Deck / macOS)
-- ---------------------------------------------------------------------------

local function env(name)
    local ok, value = pcall(os.getenv, name)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function strip_trailing_sep(path)
    local trimmed = tostring(path):gsub("[/\\]+$", "")
    if trimmed == "" then return tostring(path) end
    return trimmed
end

local function path_separator()
    return is_windows and "\\" or "/"
end

local write_probe_seq = 0
local function can_write_in(dir)
    if not dir then return false end
    local sep = path_separator()
    local probe = nil
    for _ = 1, 8 do
        write_probe_seq = write_probe_seq + 1
        local candidate = dir .. sep .. ".repage_wprobe_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999)) .. "_" .. tostring(write_probe_seq)
        local rf = io.open(candidate, "rb")
        if rf then
            rf:close()
        else
            probe = candidate
            break
        end
    end
    if not probe then return false end
    local f = io.open(probe, "wb")
    if not f then return false end
    local ok_w = f:write("1")
    local ok_f = f:flush()
    f:close()
    local removed = os.remove(probe)
    return ok_w ~= nil and ok_f ~= false and removed ~= nil
end

local function home_directory()
    if is_windows then
        local profile = env("USERPROFILE")
        if profile then return profile end
        local drive, hpath = env("HOMEDRIVE"), env("HOMEPATH")
        if drive and hpath then return drive .. hpath end
        return nil
    end
    return env("HOME")
end

-- "windows", "macos", "steamdeck" or "linux". The Steam client sets
-- SteamDeck=1 in its environment on a Steam Deck (desktop and game mode).
local function file_contains(path, pattern)
    local f = io.open(path, "rb")
    if not f then return false end
    local content = f:read(4096)
    f:close()
    return type(content) == "string" and content:find(pattern) ~= nil
end

local function detect_platform()
    if is_windows then return "windows" end
    if env("SteamDeck") == "1" or env("SteamOS") == "1" then return "steamdeck" end
    if file_contains("/etc/os-release", "ID=[\"']?steamos[\"']?") then return "steamdeck" end
    if type(jit) == "table" and jit.os == "OSX" then return "macos" end
    local cpath = tostring(package.cpath or "")
    if cpath:find("%.dylib") or cpath:find("/Library/") or cpath:find("/opt/homebrew") then
        return "macos"
    end
    local home = env("HOME") or ""
    if home:find("^/Users/") then return "macos" end
    return "linux"
end

local platform_name = detect_platform()

-- Temporary files go to the OS temp folder. If it is not writable (sandboxed
-- Steam, odd TMPDIR) fall back to the runtime dir and then to ~/.cache.
local temp_dir_cache = nil
local function temp_directory()
    if temp_dir_cache then return temp_dir_cache end

    local candidates = {}
    if is_windows then
        table.insert(candidates, env("TEMP"))
        table.insert(candidates, env("TMP"))
        table.insert(candidates, "C:\\Windows\\Temp")
    else
        local tmpdir = env("TMPDIR")  -- macOS: per-user /var/folders/... (ends with "/")
        if tmpdir then table.insert(candidates, strip_trailing_sep(tmpdir)) end
        local runtime = env("XDG_RUNTIME_DIR")
        if runtime then table.insert(candidates, strip_trailing_sep(runtime)) end
        table.insert(candidates, "/tmp")
        local home = home_directory()
        if home then
            table.insert(candidates, home .. "/.cache")
        end
    end

    for _, dir in ipairs(candidates) do
        if dir and can_write_in(dir) then
            temp_dir_cache = dir
            return dir
        end
    end

    logger:error("No writable temporary folder found; downloads will fail")
    temp_dir_cache = candidates[1] or (is_windows and "C:\\Windows\\Temp" or "/tmp")
    return temp_dir_cache
end

-- The "repage_" prefix keeps this plugin from ever touching temp files that
-- belong to other tools (Easy SteamGrid also uses "sgdb_*.bin"). The random part
-- keeps two sessions started in the same second apart.
pcall(math.randomseed, os.time() + math.floor((os.clock() or 0) * 1000000))
local session_prefix = tostring(os.time()) .. "x" .. tostring(math.random(100000, 999999))
local TEMP_PREFIX = "repage_"
local last_heartbeat_at = 0
local function touch_session_heartbeat(force)
    local now = os.time()
    if not force and (now - last_heartbeat_at) < 60 then return end
    last_heartbeat_at = now
    local dir = temp_directory()
    if not dir then return end
    local hb = dir .. path_separator() .. "repage_hb_" .. session_prefix .. ".lock"
    local f = io.open(hb, "wb")
    if f then
        f:write(tostring(now))
        f:close()
    end
end
local function remove_session_heartbeat()
    local dir = temp_directory()
    if not dir then return end
    pcall(os.remove, dir .. path_separator() .. "repage_hb_" .. session_prefix .. ".lock")
end
function ping_session_heartbeat()
    touch_session_heartbeat(true)
    return "ok"
end
local function make_tmpfile()
    download_counter = download_counter + 1
    touch_session_heartbeat(false)
    return temp_directory() .. path_separator() .. TEMP_PREFIX .. session_prefix .. "_t" .. tostring(os.time()) .. "_" .. tostring(download_counter) .. ".bin"
end

-- Steam appids of non-Steam shortcuts are unsigned 32-bit values, but some
-- callers hand them over as signed numbers. Normalize to the unsigned form
-- used in the grid file names, and to an integer string.
local ALLOWED_MEDIA_EXTS = {
    png = true, jpg = true, jpeg = true, webp = true, gif = true, ico = true, webm = true
}

local function sanitize_ext(ext)
    local clean = tostring(ext or ""):lower():gsub("^%.", "")
    if ALLOWED_MEDIA_EXTS[clean] then return clean end
    return nil
end

-- Rejects anything a lenient URL parser could read differently from the plain
-- "https://host/path" form checked below: user-info ("@"), backslashes, spaces
-- and control characters.
local function is_plain_https_url(url)
    if type(url) ~= "string" or #url > 2048 then return false end
    if url:find("[%c%s\\@]") then return false end
    return url:match("^https://[^/:?#]+[/?#]?") ~= nil
end

local function url_host(url)
    if not is_plain_https_url(url) then return nil end
    local host = url:match("^https://([^/:?#]+)")
    if not host then return nil end
    return host:lower()
end

local function host_in_domain(host, domain)
    return host == domain or host:sub(-(#domain + 1)) == "." .. domain
end

local function is_allowed_download_url(url)
    local host = url_host(url)
    if not host then return false end
    return host_in_domain(host, "steamgriddb.com")
        or host_in_domain(host, "steamstatic.com")
        or host == "steamcdn-a.akamaihd.net"
        or host_in_domain(host, "steamusercontent.com")
end

-- First bytes of every file type the plugin is allowed to hand to Steam.
local function detect_media_kind(head)
    if type(head) ~= "string" or #head < 4 then return nil end
    if head:sub(1, 3) == "\255\216\255" then return "jpg" end
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if head:sub(1, 6) == "GIF87a" or head:sub(1, 6) == "GIF89a" then return "gif" end
    if #head >= 12 and head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return "webp" end
    if head:sub(1, 4) == "\26\69\223\163" then return "webm" end
    if head:sub(1, 4) == "\0\0\1\0" then return "ico" end
    return nil
end

local MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024

local function appid_string(appid)
    local n = tonumber(appid)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n)
    if n < 0 then n = n + 4294967296 end
    if n < 0 or n > 4294967295 then return nil end
    return string.format("%d", n)
end

-- Reads a small SteamGridDB image for the sidebar logo preview only.
-- This path intentionally stays in memory: it does not use img_cache,
-- img_pins, temporary files, or the gallery/apply download lifecycle.
function read_preview_image(a_img_url)
    local url = tostring(a_img_url or "")
    local host = url_host(url)
    if not host then return "" end
    if not host_in_domain(host, "steamgriddb.com") then
        logger:info("Preview image host not allowed: " .. host)
        return ""
    end

    local response, err = http.get(url, {
        headers = { ["Accept"] = "image/png,image/jpeg,image/webp,image/*;q=0.8,*/*;q=0.5" }
    })
    if not response or response.status ~= 200 or type(response.body) ~= "string" then
        logger:info("Preview image fetch failed: " .. tostring(err or (response and response.status)))
        return ""
    end

    local body = response.body
    if #body == 0 or #body > 6 * 1024 * 1024 then
        logger:info("Preview image rejected by size limit: " .. tostring(#body))
        return ""
    end

    local mime = nil
    if body:sub(1, 3) == "\255\216\255" then
        mime = "image/jpeg"
    elseif body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP" then
        mime = "image/webp"
    elseif body:sub(1, 6) == "GIF87a" or body:sub(1, 6) == "GIF89a" then
        mime = "image/gif"
    elseif body:sub(1, 8) == "\137PNG\r\n\26\n" then
        mime = "image/png"
    elseif type(response.headers) == "table" then
        for key, value in pairs(response.headers) do
            if tostring(key):lower() == "content-type" then
                local candidate = tostring(value):match("^%s*([^;]+)")
                if candidate then
                    local lower = candidate:lower()
                    if lower == "image/png" or lower == "image/jpeg" or lower == "image/webp" or lower == "image/gif" then
                        mime = lower
                    end
                end
                break
            end
        end
    end

    if not mime then
        logger:info("Preview image rejected: unsupported content")
        return ""
    end

    local encoded = utils.base64_encode(body) or ""
    encoded = string.gsub(encoded, "[^A-Za-z0-9+/=]", "")
    if encoded == "" then return "" end
    return mime .. "\n" .. encoded
end

-- INTERFACES

function call_api_backend(a_bearer, b_endpoint)
    local bearer = tostring(a_bearer or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if bearer:find("[%c%s]") or #bearer > 256 then
        logger:error("API key rejected: it contains spaces or control characters")
        return string.format("{ \"http_status\": %d }", 401)
    end
    local clean_endpoint = tostring(b_endpoint or ""):gsub("^/+", "")
    if clean_endpoint == "" or clean_endpoint:find("[%c]") or clean_endpoint:find("%.%.") then
        logger:error("Invalid API endpoint rejected")
        return ""
    end
    local endpoint = "https://www.steamgriddb.com/api/v2/" .. clean_endpoint

    logger:info("Querying endpoint " .. endpoint)
    local response, err = http.get(endpoint, {
        headers = {
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " .. bearer,
        }
    })

    if not response then
        local emsg = tostring(err or "network_or_timeout_error"):gsub("[%c]+", " "):sub(1, 160)
        local full_err = "[api-error] Network/HTTP failure on " .. endpoint .. ": " .. emsg
        logger:error(full_err)
        logger:info(full_err)
        return string.format("{ \"http_status\": 0, \"error\": %q }", emsg)
    end

    if response.status ~= 200 then
        local body_snip = tostring(response.body or ""):gsub("[%c]+", " "):sub(1, 160)
        local hmsg = string.format("[api-error] HTTP %d on %s (body: %s)", response.status, endpoint, body_snip ~= "" and body_snip or "empty")
        logger:error(hmsg)
        logger:info(hmsg)
        return string.format("{ \"http_status\": %d }", response.status)
    end

    return response.body
end

local function remove_cache_order_entry(url)
    for i = #cache_order, 1, -1 do
        if cache_order[i] == url then
            table.remove(cache_order, i)
        end
    end
end

local function mark_cache_recent(url)
    remove_cache_order_entry(url)
    table.insert(cache_order, url)
end

-- Removes a downloaded image from disk and from the cache tables. A pinned
-- image is being read by the frontend and must not be evicted mid-transfer.
local function drop_cached(url, force)
    if (img_pins[url] or 0) > 0 and not force then
        img_cleanup_pending[url] = true
        return false
    end

    local path = img_cache[url]
    if path then
        local ok, err = os.remove(path)
        if not ok and err then
            logger:info("Temporary cache removal skipped for " .. path .. ": " .. tostring(err))
        end
    end

    cache_bytes = math.max(0, cache_bytes - (tonumber(img_size[url]) or 0))
    img_cache[url] = nil
    img_size[url] = nil
    img_pins[url] = nil
    img_cleanup_pending[url] = nil
    remove_cache_order_entry(url)
    return true
end

-- Enforce both limits without touching an image currently being read or the
-- newest download. If every older entry is pinned, the cache may temporarily
-- exceed the limits and is trimmed as soon as a reader releases its pin.
local function enforce_cache_limits(protected_url)
    while #cache_order > MAX_CACHED_IMAGES or cache_bytes > MAX_CACHED_BYTES do
        local candidate = nil
        for _, url in ipairs(cache_order) do
            if url ~= protected_url and (img_pins[url] or 0) == 0 then
                candidate = url
                break
            end
        end
        if not candidate then
            break
        end
        drop_cached(candidate)
    end
end

function pin_image(a_img_url)
    local path = img_cache[a_img_url]
    if not path then return false end
    local f = io.open(path, "rb")
    if not f then
        drop_cached(a_img_url, true)
        return false
    end
    f:close()
    img_pins[a_img_url] = (img_pins[a_img_url] or 0) + 1
    mark_cache_recent(a_img_url)
    return true
end

function unpin_image(a_img_url)
    local pins = img_pins[a_img_url] or 0
    if pins <= 0 then return false end
    pins = pins - 1
    if pins > 0 then
        img_pins[a_img_url] = pins
        return true
    end

    img_pins[a_img_url] = nil
    if img_cleanup_pending[a_img_url] then
        drop_cached(a_img_url, true)
    else
        enforce_cache_limits(nil)
    end
    return true
end

function download_image(a_img_url)
    if not is_allowed_download_url(a_img_url) then
        logger:error("download_image rejected untrusted URL: " .. tostring(a_img_url))
        return 0
    end
    -- Already downloaded (for example by a hover prefetch): answer at once
    if img_cache[a_img_url] and img_size[a_img_url] then
        local expected_sz = tonumber(img_size[a_img_url]) or 0
        local f = io.open(img_cache[a_img_url], "rb")
        if f then
            local sz = f:seek("end") or 0
            local head = (sz >= 12 and f:seek("set", 0)) and f:read(12) or nil
            f:close()
            if sz > 0 and sz == expected_sz and detect_media_kind(head) then
                img_cleanup_pending[a_img_url] = nil
                mark_cache_recent(a_img_url)
                logger:info("Image already cached: " .. a_img_url)
                return sz
            end
        end
        drop_cached(a_img_url, true)
    end

    logger:info("Downloading image " .. a_img_url)
    drop_cached(a_img_url)

    local tmpfile = make_tmpfile()
    local result, err
    -- Retry once: large downloads sometimes end with a partial file
    for attempt = 1, 2 do
        result, err = http.download(a_img_url, tmpfile)
        if result and result.status == 200 then break end
        logger:error("http.download attempt " .. attempt .. " failed: " .. tostring(err or (result and result.status)))
        os.remove(tmpfile)
        result = nil
    end
    if not result then
        return 0
    end

    local bytes_written = tonumber(result.bytes_written) or 0
    if bytes_written <= 0 then
        os.remove(tmpfile)
        logger:error("Download returned no bytes for " .. a_img_url)
        return 0
    end
    if bytes_written > MAX_DOWNLOAD_BYTES then
        os.remove(tmpfile)
        logger:error("Download rejected: " .. tostring(bytes_written) .. " bytes is over the size limit")
        return 0
    end
    do
        local probe = io.open(tmpfile, "rb")
        local head = probe and probe:read(12) or nil
        if probe then probe:close() end
        if not detect_media_kind(head) then
            os.remove(tmpfile)
            logger:error("Download rejected: not an image or video file (" .. tostring(a_img_url) .. ")")
            return 0
        end
    end

    img_cache[a_img_url] = tmpfile
    img_size[a_img_url] = bytes_written
    img_cleanup_pending[a_img_url] = nil
    cache_bytes = cache_bytes + bytes_written
    mark_cache_recent(a_img_url)

    -- Keep the existing eight-entry behavior and also prevent ordinary
    -- prefetches from allowing temporary disk usage to grow without a bound.
    -- The just-downloaded image is protected so it can always be applied.
    enforce_cache_limits(a_img_url)

    logger:info(string.format("Cached %d bytes (temporary cache: %d files, %.1f MiB)",
        bytes_written, #cache_order, cache_bytes / (1024 * 1024)))
    return bytes_written
end

function get_image_chunk(a_img_url, b_chunk_index)
    local path = img_cache[a_img_url]
    if not path then
        logger:error("No cached image for: " .. a_img_url)
        return ""
    end

    local f = io.open(path, "rb")
    if not f then
        logger:error("Cannot open cached file: " .. path)
        return ""
    end

    local index = tonumber(b_chunk_index)
    if not index or index < 0 or index ~= math.floor(index) then
        f:close()
        logger:error("get_image_chunk: invalid chunk index " .. tostring(b_chunk_index))
        return ""
    end
    local offset = index * CHUNK_SIZE
    f:seek("set", offset)
    local data = f:read(CHUNK_SIZE)
    f:close()

    if not data or #data == 0 then
        return ""
    end

    local b64 = utils.base64_encode(data) or ""
    -- The encoder adds line breaks; keep only base64 characters so sizes add up
    b64 = string.gsub(b64, "[^A-Za-z0-9+/=]", "")
    return b64
end

function cleanup_image(a_img_url)
    if img_cache[a_img_url] then
        logger:info("Cleaning up: " .. img_cache[a_img_url])
    end
    drop_cached(a_img_url)
    enforce_cache_limits(nil)
end

function log_frontend(msg)
    local text = tostring(msg)
    if text:find("^%[perf") then
        local lua_kb = math.floor(collectgarbage("count") or 0)
        local disk_mb = string.format("%.2f", (cache_bytes or 0) / (1024 * 1024))
        logger:info(string.format("[frontend] %s | [lua ram=%dKB diskFiles=%d diskMB=%s platform=%s]", text, lua_kb, #cache_order, disk_mb, tostring(platform_name)))
    else
        logger:info("[frontend] " .. text)
    end
end

-- ICONS

function set_icon_from_url(a_appid, b_img_url, c_extension)
    local tmp_path = img_cache[b_img_url]
    if not tmp_path then
        logger:error("set_icon_from_url: no cached download for " .. tostring(b_img_url))
        return false
    end

    local f = io.open(tmp_path, "rb")
    if not f then
        logger:error("set_icon_from_url: cannot open cached file: " .. tmp_path)
        return false
    end
    local bytes = f:read("*a")
    f:close()

    local result = icons.write_icon(a_appid, bytes, c_extension)

    -- Keep all cache bookkeeping in sync, including byte totals and LRU order.
    drop_cached(b_img_url)

    return result
end

function clear_icon(a_appid)
    return icons.clear_icon(a_appid)
end


-- SAVE TO DISK

local WINDOWS_RESERVED_NAMES = {
    CON = true, PRN = true, AUX = true, NUL = true,
    COM1 = true, COM2 = true, COM3 = true, COM4 = true, COM5 = true, COM6 = true, COM7 = true, COM8 = true, COM9 = true,
    LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true, LPT5 = true, LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true
}

local function sanitize_file_name(name)
    name = tostring(name or "image")
    name = name:gsub('[\\/:*?"<>|%c]', "_")
    name = name:gsub("%s+", " ")
    name = name:gsub("^%s+", ""):gsub("[%. ]+$", "")
    if #name > 150 then name = name:sub(1, 150) end
    if name == "" then name = "image" end
    local stem = name:match("^([^%.]+)") or name
    if WINDOWS_RESERVED_NAMES[stem:upper()] then
        name = "_" .. name
    end
    return name
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function read_text_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function is_directory(path)
    local ok, result = pcall(fs.exists, path)
    return ok and result and true or false
end

-- Linux / Steam Deck: the Downloads folder can be renamed or translated
-- ("Transferências", "Descargas"...). XDG says where it really is.
local function xdg_download_directory(home)
    local from_env = env("XDG_DOWNLOAD_DIR")
    if from_env and is_directory(from_env) then return strip_trailing_sep(from_env) end

    local config_home = env("XDG_CONFIG_HOME") or (home .. "/.config")
    local content = read_text_file(config_home .. "/user-dirs.dirs")
    if not content then return nil end

    local value = content:match('[\r\n]%s*XDG_DOWNLOAD_DIR%s*=%s*"([^"\r\n]+)"')
        or content:match('^%s*XDG_DOWNLOAD_DIR%s*=%s*"([^"\r\n]+)"')
    if not value then return nil end
    local function home_fn() return home end
    value = value:gsub("^%${HOME}", home_fn)
    value = value:gsub("^%$HOME", home_fn)
    value = value:gsub("^~", home_fn)
    value = strip_trailing_sep(value)
    -- XDG points at $HOME itself when the folder is disabled: ignore that.
    if value == "" or value == strip_trailing_sep(home) then return nil end
    if is_directory(value) then return value end
    return nil
end

local function downloads_directory()
    local home = home_directory()
    if not home then return nil end
    local sep = path_separator()

    local dir = nil
    if not is_windows then
        dir = xdg_download_directory(home)
    end
    if not dir then
        dir = strip_trailing_sep(home) .. sep .. "Downloads"
        if not is_directory(dir) then
            pcall(fs.create_directories, dir)
        end
    end
    if not can_write_in(dir) then
        logger:error("save_image_to_downloads: Downloads folder is not writable: " .. dir)
        -- Last resort: the home folder itself (e.g. a sandboxed Steam).
        if can_write_in(home) then
            return home, sep
        end
        return nil
    end
    return dir, sep
end

-- Fallback used when the file picker is unavailable: copy the already-downloaded
-- temporary image to the user's Downloads folder under a non-clashing name.
function save_image_to_downloads(a_img_url, b_file_name)
    local source_path = img_cache[a_img_url]
    if not source_path then
        logger:error("save_image_to_downloads: no cached download for " .. tostring(a_img_url))
        return ""
    end

    local dir, sep = downloads_directory()
    if not dir then
        logger:error("save_image_to_downloads: could not resolve the Downloads folder")
        return ""
    end

    local safe_name = sanitize_file_name(b_file_name)
    local stem, ext = safe_name:match("^(.*)(%.[%w]+)$")
    if not stem or stem == "" then
        stem, ext = safe_name, ""
    end

    local target = dir .. sep .. stem .. ext
    local counter = 1
    while file_exists(target) and counter < 1000 do
        counter = counter + 1
        target = dir .. sep .. stem .. " (" .. tostring(counter) .. ")" .. ext
    end
    if file_exists(target) then
        target = dir .. sep .. stem .. " (" .. tostring(os.time()) .. ")" .. ext
        if file_exists(target) then
            logger:error("save_image_to_downloads: target already exists: " .. target)
            return ""
        end
    end

    local input = io.open(source_path, "rb")
    if not input then
        logger:error("save_image_to_downloads: cannot open cached file: " .. source_path)
        return ""
    end
    local output = io.open(target, "wb")
    if not output then
        input:close()
        logger:error("save_image_to_downloads: cannot write: " .. target)
        return ""
    end

    local ok = true
    while true do
        local block = input:read(1024 * 1024)
        if not block then break end
        local wrote = output:write(block)
        if not wrote then
            ok = false
            break
        end
    end
    input:close()
    output:close()

    if not ok or not file_exists(target) then
        os.remove(target)
        logger:error("save_image_to_downloads: write failed for " .. target)
        return ""
    end

    logger:info("Saved image to " .. target)
    return target
end

-- ICON DATA

local B64_INDEX = {}
do
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #chars do B64_INDEX[chars:byte(i)] = i - 1 end
end

local function base64_decode(data)
    data = tostring(data or ""):gsub("[^A-Za-z0-9+/]", "")
    local out, n, len = {}, 0, #data
    for i = 1, len - 3, 4 do
        local a, b, c, d = data:byte(i, i + 3)
        local v = B64_INDEX[a] * 262144 + B64_INDEX[b] * 4096 + B64_INDEX[c] * 64 + B64_INDEX[d]
        n = n + 1
        out[n] = string.char(math.floor(v / 65536), math.floor(v / 256) % 256, v % 256)
    end
    local rest = len % 4
    if rest == 2 then
        local a, b = data:byte(len - 1, len)
        local v = B64_INDEX[a] * 64 + B64_INDEX[b]
        n = n + 1
        out[n] = string.char(math.floor(v / 16))
    elseif rest == 3 then
        local a, b, c = data:byte(len - 2, len)
        local v = B64_INDEX[a] * 4096 + B64_INDEX[b] * 64 + B64_INDEX[c]
        n = n + 1
        out[n] = string.char(math.floor(v / 1024), math.floor(v / 4) % 256)
    end
    return table.concat(out)
end

-- Writes an icon (PNG or JPG, base64) to every place Steam reads icons from.
function write_icon_data(a_appid, b_data, c_extension)
    local bytes = base64_decode(b_data)
    if #bytes < 8 then
        logger:error("write_icon_data: empty icon data for " .. tostring(a_appid))
        return false
    end
    return icons.write_icon(a_appid, bytes, c_extension)
end

-- Steam file stems for each artwork type (index matches the plugin's type index)
local ARTWORK_STEM_SUFFIX = { [0] = "p", [1] = "_hero", [2] = "_logo", [3] = "", [4] = "_icon" }

local function remove_artwork_stem(grid_dir, stem, keep_ext)
    -- Exact-path probing (see icons.remove_matching_stem): no directory listing.
    local removed = icons.remove_matching_stem(grid_dir, stem, keep_ext and keep_ext:lower() or nil)
    if removed then
        logger:info("clear_artwork: removed older files for " .. stem .. " in " .. grid_dir)
    end
end

-- Removes older artwork files of this slot, whatever their extension,
-- except the one with c_keep_ext (the file just applied).
function clear_artwork_files(a_appid, b_imagetype, c_keep_ext)
    local suffix = ARTWORK_STEM_SUFFIX[b_imagetype]
    local app = appid_string(a_appid)
    if suffix == nil or not app then return false end
    local keep = c_keep_ext ~= nil and sanitize_ext(c_keep_ext) or nil
    local stem = app .. suffix
    for _, grid_dir in ipairs(icons.grid_dirs(false)) do
        remove_artwork_stem(grid_dir, stem, keep)
    end
    return true
end

-- Size in bytes of the artwork file for this slot and extension, or -1 if missing/corrupt
function artwork_file_size(a_appid, b_imagetype, c_ext, d_expected)
    local suffix = ARTWORK_STEM_SUFFIX[b_imagetype]
    local app = appid_string(a_appid)
    local ext = sanitize_ext(c_ext)
    if suffix == nil or not app or not ext then return -1 end
    local file_name = app .. suffix .. "." .. ext
    local expected = tonumber(d_expected)
    local first_size = -1
    for _, grid_dir in ipairs(icons.grid_dirs(false, true)) do
        local f = io.open(fs.join(grid_dir, file_name), "rb")
        if f then
            local size = f:seek("end") or -1
            local head = (size >= 12 and f:seek("set", 0)) and f:read(12) or nil
            f:close()
            if size > 0 and detect_media_kind(head) then
                if expected and expected > 0 and size == expected then
                    return size
                end
                if first_size < 0 then
                    first_size = size
                end
            end
        end
    end
    return first_size
end

-- Return the persisted artwork path so the Steam UI can decode it ahead of navigation.
-- This is read-only: it never changes Steam's files or launches an external process.
function read_artwork_preview(a_appid, b_imagetype)
    local suffix = ARTWORK_STEM_SUFFIX[b_imagetype]
    local app = appid_string(a_appid)
    if suffix == nil or not app then return "" end

    local exts = { "png", "jpg", "jpeg", "webp", "gif", "webm" }
    local found_oversized = false
    local dirs = icons.grid_dirs(false, true)
    if b_imagetype == 4 then
        local root_ok, root = pcall(millennium.steam_path)
        if root_ok and type(root) == "string" and root ~= "" then
            local lib_cache = fs.join(root, "appcache", "librarycache")
            if icons.safe_exists(lib_cache) then
                table.insert(dirs, lib_cache)
            end
        end
    end

    for _, grid_dir in ipairs(dirs) do
        for _, ext in ipairs(exts) do
            local path = fs.join(grid_dir, app .. suffix .. "." .. ext)
            local f = io.open(path, "rb")
            if f then
                local size = f:seek("end") or 0
                -- The preview crosses the IPC bridge as base64 and Lua calls are
                -- serialized, so keep it small. Bigger files are reported as "toobig"
                -- (the UI keeps its cached thumbnail instead of clearing it).
                local max_size = 8 * 1024 * 1024
                if size > max_size then
                    found_oversized = true
                    f:close()
                elseif size >= 8 then
                    f:seek("set", 0)
                    local bytes = f:read("*a")
                    f:close()
                    if type(bytes) == "string" and #bytes >= 8 then
                        local mime = nil
                        if bytes:sub(1, 3) == "\255\216\255" then
                            mime = "image/jpeg"
                        elseif bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
                            mime = "image/webp"
                        elseif bytes:sub(1, 6) == "GIF87a" or bytes:sub(1, 6) == "GIF89a" then
                            mime = "image/gif"
                        elseif bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
                            mime = "image/png"
                        elseif bytes:sub(1, 4) == "\26\69\223\163" and ext == "webm" then
                            mime = "video/webm"
                        end
                        if mime then
                            local encoded = utils.base64_encode(bytes) or ""
                            encoded = string.gsub(encoded, "[^A-Za-z0-9+/=]", "")
                            if encoded ~= "" then
                                return mime .. "\n" .. encoded
                            end
                        end
                    end
                else
                    f:close()
                end
            end
        end
    end
    if found_oversized then return "toobig" end
    return ""
end

function artwork_file_path(a_appid, b_imagetype, c_ext)
    local suffix = ARTWORK_STEM_SUFFIX[b_imagetype]
    local app = appid_string(a_appid)
    local ext = sanitize_ext(c_ext)
    if suffix == nil or not app or not ext then return "" end
    local file_name = app .. suffix .. "." .. ext
    for _, grid_dir in ipairs(icons.grid_dirs(false, true)) do
        local path = fs.join(grid_dir, file_name)
        local f = io.open(path, "rb")
        if f then
            f:close()
            return path
        end
    end
    return ""
end

-- Touch the saved artwork after SteamClient.Apps.SetCustomArtworkForApp has
-- completed. This operation is filesystem-only and does not launch another process.
function refresh_artwork_file(a_appid, b_imagetype, c_ext)
    local suffix = ARTWORK_STEM_SUFFIX[b_imagetype]
    local app = appid_string(a_appid)
    local ext = sanitize_ext(c_ext)
    if suffix == nil or not app or not ext then return 0 end
    local file_name = app .. suffix .. "." .. ext
    local touched = 0
    for _, grid_dir in ipairs(icons.grid_dirs(false)) do
        local path = fs.join(grid_dir, file_name)
        local f = io.open(path, "r+b")
        if f then
            local first = f:read(1)
            if first then
                f:seek("set", 0)
                local written, err = f:write(first)
                if written then
                    f:flush()
                    touched = touched + 1
                else
                    logger:error("refresh_artwork_file: could not touch " .. path .. ": " .. tostring(err))
                end
            end
            f:close()
        end
    end
    logger:info("refresh_artwork_file: " .. file_name .. " touched " .. touched .. " time(s)")
    return touched
end

-- SELF-UPDATER (GitHub Releases)

local GITHUB_LATEST_API = "https://api.github.com/repos/Klastein/Repage-SteamGrid/releases/latest"
local UPDATE_ZIP_CACHE = nil

local function is_allowed_github_url(url)
    if type(url) ~= "string" then return false end
    local lower = url:lower()
    if not lower:match("^https://") or lower:find("[%c%s\\@]") then return false end
    local host = url_host(url)
    if not host then return false end
    if host == "github.com" then
        return lower:match("^https://github%.com/klastein/repage%-steamgrid/releases/download/[^/]+/repage_steamgrid_[%w%.%-_]+%.zip$") ~= nil
    end
    if host == "api.github.com" then
        return lower:match("^https://api%.github%.com/repos/klastein/repage%-steamgrid/") ~= nil
    end
    return false
end

local function verify_plugin_dir(dir)
    if not dir or dir == "" then return false end
    local pjson = read_text_file(dir .. path_separator() .. "plugin.json")
    if type(pjson) ~= "string" then return false end
    return pjson:find('"name"%s*:%s*"repage%-steamgrid"') ~= nil
end

local function resolve_plugin_dir()
    local sep = path_separator()
    local ok_dbg, info = pcall(function() return debug and debug.getinfo and debug.getinfo(1, "S") end)
    if ok_dbg and type(info) == "table" and type(info.source) == "string" then
        local src = info.source:gsub("^@", "")
        local is_abs = is_windows and (src:match("^[A-Za-z]:[/\\]") ~= nil) or (src:sub(1, 1) == "/")
        if is_abs then
            local norm = is_windows and src:gsub("/", "\\") or src
            local parent = norm:match("^(.*)[/\\]backend[/\\]main%.lua$")
            if parent and verify_plugin_dir(parent) then
                return parent
            end
        end
    end

    local candidates = {}
    local ok_root, sroot = pcall(millennium.steam_path)
    if ok_root and type(sroot) == "string" and sroot ~= "" then
        local sr = strip_trailing_sep(sroot)
        table.insert(candidates, sr .. sep .. "millennium" .. sep .. "plugins" .. sep .. "repage-steamgrid")
        table.insert(candidates, sr .. sep .. "plugins" .. sep .. "repage-steamgrid")
    end
    if not is_windows then
        local xdg = env("XDG_DATA_HOME")
        if xdg then
            table.insert(candidates, strip_trailing_sep(xdg) .. "/millennium/plugins/repage-steamgrid")
        end
        local home = home_directory()
        if home then
            table.insert(candidates, strip_trailing_sep(home) .. "/.local/share/millennium/plugins/repage-steamgrid")
        end
    end

    for _, dir in ipairs(candidates) do
        if verify_plugin_dir(dir) then return dir end
    end

    for _, dir in ipairs(candidates) do
        local plugins_root = dir:match("^(.*)[/\\][^/\\]+$")
        if plugins_root and is_directory(plugins_root) then
            for _, entry in ipairs(icons.safe_list(plugins_root)) do
                if entry.is_directory and verify_plugin_dir(entry.path) then
                    return entry.path
                end
            end
        end
    end
    return nil
end

local function is_safe_rel_path(rel)
    if type(rel) ~= "string" or rel == "" or #rel > 240 then return false end
    if rel:find("[%c\\:]") or rel:sub(1, 1) == "/" then return false end
    if rel:find("%.%.") then return false end
    return true
end

function check_github_update()
    local response, err = http.get(GITHUB_LATEST_API, {
        headers = {
            ["Accept"] = "application/vnd.github+json",
            ["User-Agent"] = "Repage-SteamGrid-Updater/1.0"
        }
    })
    if not response then
        logger:info("check_github_update failed: " .. tostring(err))
        return "{\"http_status\":0}"
    end
    if response.status ~= 200 or type(response.body) ~= "string" or response.body == "" then
        logger:info("check_github_update HTTP " .. tostring(response.status))
        return string.format("{\"http_status\":%d}", tonumber(response.status) or 0)
    end
    return response.body
end

function download_update_zip(a_zip_url)
    local url = tostring(a_zip_url or "")
    if not is_allowed_github_url(url) then
        logger:error("download_update_zip rejected untrusted URL: " .. url)
        return 0
    end
    if UPDATE_ZIP_CACHE then
        pcall(os.remove, UPDATE_ZIP_CACHE)
        UPDATE_ZIP_CACHE = nil
    end
    local tmp = temp_directory() .. path_separator() .. "repage_update_" .. session_prefix .. ".zip"
    local result, err = http.download(url, tmp)
    if not result or result.status ~= 200 then
        pcall(os.remove, tmp)
        logger:error("download_update_zip failed: " .. tostring(err or (result and result.status)))
        return 0
    end
    local bytes_written = tonumber(result.bytes_written) or 0
    if bytes_written < 1024 or bytes_written > 32 * 1024 * 1024 then
        pcall(os.remove, tmp)
        logger:error("download_update_zip invalid size: " .. tostring(bytes_written))
        return 0
    end
    local probe = io.open(tmp, "rb")
    local sig = probe and probe:read(4) or nil
    if probe then probe:close() end
    if sig ~= "PK\3\4" then
        pcall(os.remove, tmp)
        logger:error("download_update_zip rejected: not a valid ZIP archive")
        return 0
    end
    UPDATE_ZIP_CACHE = tmp
    return bytes_written
end

function get_update_zip_chunk(a_chunk_index)
    if not UPDATE_ZIP_CACHE then return "" end
    local f = io.open(UPDATE_ZIP_CACHE, "rb")
    if not f then return "" end
    local index = tonumber(a_chunk_index)
    if not index or index < 0 or index ~= math.floor(index) then
        f:close()
        return ""
    end
    f:seek("set", index * CHUNK_SIZE)
    local data = f:read(CHUNK_SIZE)
    f:close()
    if not data or #data == 0 then return "" end
    local b64 = utils.base64_encode(data) or ""
    return string.gsub(b64, "[^A-Za-z0-9+/=]", "")
end

function cleanup_update_zip()
    if UPDATE_ZIP_CACHE then
        pcall(os.remove, UPDATE_ZIP_CACHE)
        UPDATE_ZIP_CACHE = nil
    end
    return true
end

local ALLOWED_UPDATE_FILES = {
    ["plugin.json"] = true,
    ["metadata.json"] = true,
    ["README.md"] = true,
    [".gitignore"] = true,
    ["CREDITS.md"] = true,
    ["INSTALLATION.txt"] = true,
    ["linux-fix.sh"] = true,
    ["LICENSE"] = true,
    ["PATCH_NOTES.txt"] = true,
    ["backend/icons.lua"] = true,
    ["backend/main.lua"] = true,
    [".millennium/dist/index.js"] = true
}

local function shell_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function is_symlink_path(path, entry)
    if not path or path == "" then return false end
    if type(entry) == "table" and entry.is_symlink then return true end
    if type(fs.is_symlink) == "function" then
        local ok, res = pcall(fs.is_symlink, path)
        if ok and res then return true end
    end
    if not is_windows then
        local ok_ex, code = pcall(os.execute, "test -L " .. shell_quote(path))
        if ok_ex and (code == 0 or code == true) then return true end
    end
    return false
end

local function path_exists_or_symlink(path)
    if is_symlink_path(path) then return true end
    local ok, ex = pcall(fs.exists, path)
    if not ok then return true end
    return ex and true or false
end

local function path_has_symlink_component(base_dir, rel)
    if is_symlink_path(base_dir) then return true end
    local sep = path_separator()
    local cur = base_dir
    for seg in tostring(rel or ""):gmatch("[^/]+") do
        cur = cur .. sep .. seg
        if is_symlink_path(cur) then return true end
    end
    return false
end

local function remove_tree_safe(path, depth)
    if not path or path == "" or (depth or 0) > 8 then return false end
    if is_symlink_path(path) then
        pcall(os.remove, path)
        pcall(fs.remove, path)
        return not path_exists_or_symlink(path)
    end
    local ok_ex, exists = pcall(fs.exists, path)
    if not ok_ex then return false end
    if not exists then return true end
    local ok_ls, entries = pcall(fs.list, path)
    if ok_ls and type(entries) == "table" then
        for _, entry in ipairs(entries) do
            if type(entry) == "table" and type(entry.path) == "string" and entry.path ~= "" then
                if is_symlink_path(entry.path, entry) then
                    pcall(os.remove, entry.path)
                    pcall(fs.remove, entry.path)
                elseif entry.is_directory then
                    remove_tree_safe(entry.path, (depth or 0) + 1)
                else
                    pcall(os.remove, entry.path)
                    pcall(fs.remove, entry.path)
                end
            end
        end
    end
    pcall(fs.remove, path)
    pcall(os.remove, path)
    return not path_exists_or_symlink(path)
end

local function cleanup_stale_stage_dir()
    local dir = resolve_plugin_dir()
    if not dir then return end
    local stage_dir = dir .. path_separator() .. ".repage_update_stage"
    if path_exists_or_symlink(stage_dir) then
        local ok = remove_tree_safe(stage_dir, 0)
        if not ok then
            logger:error("[self-update] Startup cleanup could not fully remove stale .repage_update_stage")
        end
    end
end

local STAGED_FILES = {}

function begin_update_stage()
    local dir = resolve_plugin_dir()
    if not dir then return "no_plugin_dir" end
    if not can_write_in(dir) then return "no_write_permission" end
    STAGED_FILES = {}
    local stage_dir = dir .. path_separator() .. ".repage_update_stage"
    if is_symlink_path(stage_dir) then
        pcall(os.remove, stage_dir)
        pcall(fs.remove, stage_dir)
        if path_exists_or_symlink(stage_dir) then return "stage_symlink_blocked" end
    elseif path_exists_or_symlink(stage_dir) then
        if not remove_tree_safe(stage_dir, 0) then return "stage_cleanup_failed" end
    end
    pcall(fs.create_directories, stage_dir)
    if is_symlink_path(stage_dir) then return "stage_symlink_blocked" end
    if not can_write_in(stage_dir) then return "no_write_permission" end
    return "ok"
end

function stage_update_file(a_rel_path, b_b64_data)
    local rel = tostring(a_rel_path or ""):gsub("\\", "/")
    if rel == ".millennium/Dist/index.js" then rel = ".millennium/dist/index.js" end
    if not is_safe_rel_path(rel) then return "invalid_path" end
    if not ALLOWED_UPDATE_FILES[rel] then return "disallowed_path:" .. rel end
    if STAGED_FILES[rel] ~= nil then return "duplicate_path:" .. rel end
    local dir = resolve_plugin_dir()
    if not dir then return "no_plugin_dir" end
    local sep = path_separator()
    local stage_dir = dir .. sep .. ".repage_update_stage"
    if path_has_symlink_component(stage_dir, rel) then return "stage_symlink_blocked:" .. rel end
    local bytes = base64_decode(b_b64_data)
    local stage_path = stage_dir .. sep .. (is_windows and rel:gsub("/", "\\") or rel)
    local parent = stage_path:match("^(.*)[/\\][^/\\]+$")
    if parent then pcall(fs.create_directories, parent) end
    if path_has_symlink_component(stage_dir, rel) then return "stage_symlink_blocked:" .. rel end
    local f = io.open(stage_path, "wb")
    if not f then return "write_failed:" .. rel end
    local ok = f:write(bytes)
    f:close()
    if not ok then return "write_failed:" .. rel end
    STAGED_FILES[rel] = stage_path
    return "ok"
end

local function encode_backup_name(rel)
    return (tostring(rel):gsub("[^%w%.%-_]", "__"))
end

local function verify_file_exact_bytes(path, expected_bytes)
    local f = io.open(path, "rb")
    if not f then return false end
    local content = f:read("*a")
    f:close()
    return content == expected_bytes
end

local function verify_file_size(path, expected_len)
    local f = io.open(path, "rb")
    if not f then return false end
    local sz = f:seek("end") or -1
    f:close()
    return sz == expected_len
end

local function replace_file_safely(tmp_dst, final_dst, expected_bytes)
    local old_swap = final_dst .. ".old_swap"
    pcall(os.remove, old_swap)
    local had_existing = file_exists(final_dst)
    if had_existing then
        local moved_old = os.rename(final_dst, old_swap)
        if moved_old then
            local moved_new = os.rename(tmp_dst, final_dst)
            if moved_new and verify_file_size(final_dst, #expected_bytes) then
                pcall(os.remove, old_swap)
                return true
            end
            pcall(os.remove, final_dst)
            os.rename(old_swap, final_dst)
        end
    else
        if os.rename(tmp_dst, final_dst) and verify_file_size(final_dst, #expected_bytes) then
            return true
        end
    end
    local wf = io.open(final_dst, "wb")
    if not wf then
        pcall(os.remove, tmp_dst)
        return false
    end
    local ok_direct = wf:write(expected_bytes)
    local ok_flush = wf:flush()
    wf:close()
    pcall(os.remove, tmp_dst)
    if ok_direct and ok_flush ~= false and verify_file_size(final_dst, #expected_bytes) then
        pcall(os.remove, old_swap)
        return true
    end
    if had_existing and file_exists(old_swap) then
        pcall(os.remove, final_dst)
        os.rename(old_swap, final_dst)
    end
    return false
end

local function write_verified_marker(tmp_path, final_path, payload)
    pcall(os.remove, tmp_path)
    local f = io.open(tmp_path, "wb")
    if not f then return false end
    local ok_w = f:write(payload)
    local ok_f = f:flush()
    f:close()
    if not ok_w or ok_f == false or not verify_file_exact_bytes(tmp_path, payload) then
        pcall(os.remove, tmp_path)
        return false
    end
    if not replace_file_safely(tmp_path, final_path, payload) then
        pcall(os.remove, tmp_path)
        return false
    end
    return verify_file_exact_bytes(final_path, payload)
end

local function inspect_backup_dir(bdir)
    if not bdir or bdir == "" then
        return "error", nil, "invalid_path"
    end
    local ok_ex, exists = pcall(fs.exists, bdir)
    if not ok_ex then
        logger:error("[self-update] fs.exists threw for backup dir " .. tostring(bdir) .. ": " .. tostring(exists))
        return "error", nil, "exists_check_failed"
    end
    if not exists then
        local parent_dir, leaf_name = tostring(bdir):match("^(.*)[/\\]([^/\\]+)$")
        if not parent_dir or parent_dir == "" or not leaf_name or leaf_name == "" then
            return "error", nil, "invalid_parent_path"
        end
        local ok_p, p_entries = pcall(fs.list, parent_dir)
        if not ok_p or type(p_entries) ~= "table" or #p_entries == 0 then
            logger:error("[self-update] Cannot verify non-existence of " .. tostring(bdir) .. ": parent dir listing failed or returned empty")
            return "error", nil, "parent_dir_unreadable"
        end
        local saw_known_sibling = false
        for _, p_entry in ipairs(p_entries) do
            if type(p_entry) ~= "table" or type(p_entry.path) ~= "string" or p_entry.path == "" then
                return "error", nil, "parent_unclassifiable_entry"
            end
            local bname = icons.base_name(p_entry.path)
            if bname == "plugin.json" or bname == "backend" or bname == ".millennium" then
                saw_known_sibling = true
            end
            if bname == leaf_name then
                logger:error("[self-update] fs.exists returned false for " .. tostring(bdir) .. " but entry exists in parent dir (permission denied)")
                return "error", nil, "exists_permission_mismatch"
            end
        end
        if not saw_known_sibling then
            logger:error("[self-update] Parent directory listing for " .. tostring(parent_dir) .. " did not contain expected plugin files; treating as unreadable")
            return "error", nil, "parent_dir_witness_missing"
        end
        return "missing", {}, nil
    end
    local ok_ls, entries = pcall(fs.list, bdir)
    if not ok_ls or type(entries) ~= "table" then
        logger:error("[self-update] fs.list failed for backup dir " .. tostring(bdir) .. ": " .. tostring(entries))
        return "error", nil, "list_failed"
    end
    local files = {}
    for _, entry in ipairs(entries) do
        if type(entry) ~= "table" or type(entry.path) ~= "string" or entry.path == "" or (not entry.is_file and not entry.is_directory) then
            logger:error("[self-update] Unclassifiable entry in backup dir " .. tostring(bdir))
            return "error", nil, "unclassifiable_entry"
        end
        table.insert(files, entry)
    end
    if #files == 0 then
        local sep = path_separator()
        if file_exists(bdir .. sep .. "journal.txt") or file_exists(bdir .. sep .. "journal.committed") then
            logger:error("[self-update] fs.list returned 0 entries for " .. tostring(bdir) .. " but journal file exists on disk")
            return "error", nil, "empty_list_journal_hidden"
        end
        local probe_name = nil
        local probe_path = nil
        for _ = 1, 8 do
            write_probe_seq = write_probe_seq + 1
            local cname = ".repage_lprobe_" .. session_prefix .. "_" .. tostring(os.time()) .. "_" .. tostring(write_probe_seq)
            local cpath = bdir .. sep .. cname
            if not file_exists(cpath) then
                probe_name = cname
                probe_path = cpath
                break
            end
        end
        if not probe_path then
            return "error", nil, "probe_allocation_failed"
        end
        local pf = io.open(probe_path, "wb")
        if not pf then
            logger:error("[self-update] Cannot create read/list probe in " .. tostring(bdir))
            return "error", nil, "empty_list_write_denied"
        end
        local ok_pw = pf:write("probe")
        local ok_pf = pf:flush()
        pf:close()
        if not ok_pw or ok_pf == false then
            pcall(os.remove, probe_path)
            return "error", nil, "empty_list_probe_flush_failed"
        end
        local ok_pls, p_entries = pcall(fs.list, bdir)
        pcall(os.remove, probe_path)
        if file_exists(probe_path) then
            logger:error("[self-update] Failed to remove list probe in " .. tostring(bdir))
            return "error", nil, "empty_list_probe_cleanup_failed"
        end
        if not ok_pls or type(p_entries) ~= "table" then
            logger:error("[self-update] fs.list failed during read/list verification of " .. tostring(bdir))
            return "error", nil, "empty_list_read_probe_failed"
        end
        local saw_probe = false
        local extra_count = 0
        for _, pe in ipairs(p_entries) do
            if type(pe) ~= "table" or type(pe.path) ~= "string" or pe.path == "" or (not pe.is_file and not pe.is_directory) then
                return "error", nil, "empty_list_probe_unclassifiable"
            end
            if icons.base_name(pe.path) == probe_name and pe.is_file then
                saw_probe = true
            else
                extra_count = extra_count + 1
            end
        end
        if not saw_probe or extra_count > 0 then
            logger:error("[self-update] Read/list probe verification failed in " .. tostring(bdir) .. " (saw_probe=" .. tostring(saw_probe) .. ", extra=" .. tostring(extra_count) .. ")")
            return "error", nil, "empty_list_read_probe_mismatch"
        end
        return "empty", files, nil
    end
    return "has_files", files, nil
end

local function backup_dir_is_confirmed_empty(bdir)
    local state, _, err = inspect_backup_dir(bdir)
    if state == "missing" or state == "empty" then
        return true, state
    end
    return false, (state == "error" and (err or "list_error") or "has_files")
end

local function purge_unpromoted_backup_dir(bdir, sep, rel_list)
    if not bdir then return false, "invalid_path" end
    local state, entries = inspect_backup_dir(bdir)
    if state == "missing" or state == "empty" then
        pcall(fs.remove, bdir)
        pcall(os.remove, bdir)
        return true, "clean"
    end
    if state == "error" then
        logger:error("[self-update] purge_unpromoted_backup_dir aborted: cannot list " .. tostring(bdir))
        return false, "backup_dir_unreadable"
    end
    local jpath = bdir .. sep .. "journal.txt"
    if file_exists(jpath) then
        return false, "active_journal_present"
    end
    pcall(os.remove, jpath .. ".tmp")
    pcall(os.remove, bdir .. sep .. "journal.committed")
    pcall(os.remove, bdir .. sep .. "journal.committed.tmp")
    if type(rel_list) == "table" then
        for _, rel in ipairs(rel_list) do
            pcall(os.remove, bdir .. sep .. encode_backup_name(rel) .. ".bak")
        end
    end
    for _, entry in ipairs(entries) do
        if entry.is_file then
            pcall(os.remove, entry.path)
        end
    end
    pcall(fs.remove, bdir)
    pcall(os.remove, bdir)
    local empty_ok, after_reason = backup_dir_is_confirmed_empty(bdir)
    if not empty_ok then
        logger:error("[self-update] purge_unpromoted_backup_dir could not confirm empty dir (" .. tostring(after_reason) .. ")")
        return false, after_reason
    end
    return true, "clean"
end

local function mark_journal_committed_and_remove(bdir, sep)
    if not bdir then return false end
    local state = inspect_backup_dir(bdir)
    if state == "missing" then return true end
    if state == "error" then
        logger:error("[self-update] Cannot neutralize journal: backup dir is unreadable: " .. tostring(bdir))
        return false
    end
    local payload = "COMMITTED\n"
    local jpath = bdir .. sep .. "journal.txt"
    local jtmp = jpath .. ".tmp"
    local cpath = bdir .. sep .. "journal.committed"
    local ctmp = cpath .. ".tmp"
    pcall(os.remove, jtmp)

    local marker_ok = write_verified_marker(ctmp, cpath, payload)
    if file_exists(jpath) then
        pcall(os.remove, jpath)
        if file_exists(jpath) then
            local jctmp = jpath .. ".committed_tmp"
            if write_verified_marker(jctmp, jpath, payload) then
                pcall(os.remove, jpath)
            end
        end
    end

    local journal_gone = not file_exists(jpath)
    local journal_marked = (not journal_gone) and verify_file_exact_bytes(jpath, payload)
    local empty_ok = backup_dir_is_confirmed_empty(bdir)
    if (journal_gone and (marker_ok or empty_ok)) or (journal_marked and marker_ok) then
        return true
    end

    logger:error("[self-update] Failed to verify journal neutralization in " .. tostring(bdir) .. " (gone=" .. tostring(journal_gone) .. ", marked=" .. tostring(journal_marked) .. ", commit_marker=" .. tostring(marker_ok) .. ")")
    return false
end

local function cleanup_backup_dir(bdir, sep, rel_list)
    if not bdir then return false, "invalid_path" end
    local init_state = inspect_backup_dir(bdir)
    if init_state == "missing" then return true, "clean" end
    if init_state == "error" then
        logger:error("[self-update] cleanup_backup_dir aborted: backup directory cannot be listed: " .. tostring(bdir))
        return false, "backup_dir_unreadable"
    end
    if not mark_journal_committed_and_remove(bdir, sep) then
        logger:error("[self-update] cleanup_backup_dir aborted: journal could not be safely removed or marked COMMITTED; keeping all .bak files intact")
        return false, "journal_active"
    end
    local jpath = bdir .. sep .. "journal.txt"
    local cpath = bdir .. sep .. "journal.committed"
    local all_baks_removed = true
    if type(rel_list) == "table" then
        for _, rel in ipairs(rel_list) do
            local bfile = bdir .. sep .. encode_backup_name(rel) .. ".bak"
            if file_exists(bfile) then
                pcall(os.remove, bfile)
                if file_exists(bfile) then
                    all_baks_removed = false
                end
            end
        end
    end
    local ls_state, entries = inspect_backup_dir(bdir)
    if ls_state == "error" then
        logger:error("[self-update] cleanup_backup_dir failed to list remaining files in " .. tostring(bdir) .. "; keeping commit marker")
        return false, "backup_dir_unreadable"
    end
    if type(entries) == "table" then
        for _, entry in ipairs(entries) do
            if entry.is_file and entry.path ~= cpath and entry.path ~= jpath then
                pcall(os.remove, entry.path)
                if file_exists(entry.path) then
                    all_baks_removed = false
                end
            end
        end
    end
    if file_exists(jpath) then
        pcall(os.remove, jpath)
    end
    local journal_gone = not file_exists(jpath)
    if all_baks_removed and journal_gone then
        pcall(os.remove, cpath)
        pcall(fs.remove, bdir)
        pcall(os.remove, bdir)
        local empty_ok, empty_reason = backup_dir_is_confirmed_empty(bdir)
        if empty_ok then
            return true, "clean"
        end
        logger:error("[self-update] cleanup_backup_dir could not confirm empty backup dir after removal (" .. tostring(empty_reason) .. ")")
        return false, empty_reason
    end
    logger:error("[self-update] cleanup_backup_dir incomplete (baks_removed=" .. tostring(all_baks_removed) .. ", journal_gone=" .. tostring(journal_gone) .. "); keeping commit marker")
    return false, "baks_pending"
end

local function parse_active_journal(jcontent)
    if type(jcontent) ~= "string" or jcontent == "" then return nil, "empty" end
    local first_line = jcontent:match("^([^\r\n]+)") or ""
    if first_line == "COMMITTED" then
        return nil, "committed"
    end
    local expected_count = tonumber(first_line:match("^ACTIVE\t(%d+)$"))
    local entries = {}
    local saw_end = false
    local end_count = -1
    for line in jcontent:gmatch("[^\r\n]+") do
        if line ~= first_line then
            local ec = line:match("^END_JOURNAL\t(%d+)$")
            if ec then
                saw_end = true
                end_count = tonumber(ec) or -1
            else
                local state, rel = line:match("^(%u+)\t(.+)$")
                if (state == "EXISTED" or state == "NEW") and rel and rel ~= "" then
                    table.insert(entries, { state = state, rel = rel })
                end
            end
        end
    end
    if not expected_count then
        if #entries > 0 then
            return entries, "legacy_active"
        end
        return nil, "invalid"
    end
    if not saw_end or end_count ~= expected_count or #entries ~= expected_count then
        return nil, "incomplete_journal"
    end
    return entries, "active"
end

local function recover_interrupted_update()
    local dir = resolve_plugin_dir()
    if not dir then return false end
    local sep = path_separator()
    local bdir = dir .. sep .. ".repage_update_backup"
    local bstate = inspect_backup_dir(bdir)
    if bstate == "missing" or bstate == "empty" then return false end
    if bstate == "error" then
        logger:error("[self-update] recover_interrupted_update cannot inspect " .. tostring(bdir) .. "; preserving directory")
        return false
    end
    local jpath = bdir .. sep .. "journal.txt"
    local cpath = bdir .. sep .. "journal.committed"
    if verify_file_exact_bytes(cpath, "COMMITTED\n") then
        logger:info("[self-update] Verified COMMITTED marker found; finishing pending backup cleanup without rollback")
        cleanup_backup_dir(bdir, sep, nil)
        return false
    end
    if not file_exists(jpath) then
        purge_unpromoted_backup_dir(bdir, sep, nil)
        return false
    end
    local jf = io.open(jpath, "rb")
    if not jf then return false end
    local jcontent = jf:read("*a") or ""
    jf:close()
    local entries, status = parse_active_journal(jcontent)
    if status == "committed" then
        cleanup_backup_dir(bdir, sep, nil)
        return false
    end
    if status == "incomplete_journal" or status == "empty" then
        logger:info("[self-update] Removing unpromoted/incomplete journal before any live file changes")
        pcall(os.remove, jpath)
        purge_unpromoted_backup_dir(bdir, sep, nil)
        return false
    end
    if not entries then
        logger:error("[self-update] Unrecognized journal format in " .. jpath .. "; preserving backup folder")
        return false
    end

    logger:error("[self-update] Interrupted update transaction detected in " .. bdir .. "; rolling back " .. tostring(#entries) .. " file(s) from disk backup")
    local rels = {}
    local failed = {}
    for i = #entries, 1, -1 do
        local item = entries[i]
        local state, rel = item.state, item.rel
        table.insert(rels, rel)
        local dst = dir .. sep .. rel:gsub("/", sep)
        pcall(os.remove, dst .. ".tmp_new")
        pcall(os.remove, dst .. ".old_swap")
        if state == "EXISTED" then
            local bfile = bdir .. sep .. encode_backup_name(rel) .. ".bak"
            local bf = io.open(bfile, "rb")
            if not bf then
                table.insert(failed, rel .. "(missing_bak)")
            else
                local old_bytes = bf:read("*a")
                bf:close()
                if old_bytes == nil then
                    table.insert(failed, rel .. "(unreadable_bak)")
                else
                    local parent = dst:match("^(.*)[/\\][^/\\]+$")
                    if parent and not is_directory(parent) then
                        pcall(fs.create_directories, parent)
                    end
                    local tmp_restore = dst .. ".tmp_restore"
                    local rf = io.open(tmp_restore, "wb")
                    if not rf then
                        table.insert(failed, rel .. "(tmp_open_failed)")
                    else
                        local ok_w = rf:write(old_bytes)
                        local ok_f = rf:flush()
                        rf:close()
                        if not ok_w or ok_f == false or not replace_file_safely(tmp_restore, dst, old_bytes) or not verify_file_size(dst, #old_bytes) then
                            pcall(os.remove, tmp_restore)
                            table.insert(failed, rel .. "(restore_verify_failed)")
                        end
                    end
                end
            end
        elseif state == "NEW" then
            if file_exists(dst) then
                pcall(os.remove, dst)
                if file_exists(dst) then
                    table.insert(failed, rel .. "(remove_new_failed)")
                end
            end
        end
    end

    if #failed > 0 then
        logger:error("[self-update] Rollback incomplete for: " .. table.concat(failed, ", ") .. "; preserving .repage_update_backup for retry")
        return false
    end

    if not cleanup_backup_dir(bdir, sep, rels) then
        logger:error("[self-update] Rollback restored files, but backup dir cleanup could not be completed")
        return false
    end
    logger:info("[self-update] Disk rollback finished cleanly and all files verified")
    return true
end

local function ensure_clean_backup_dir_before_transaction(bdir, sep)
    local init_state = inspect_backup_dir(bdir)
    if init_state == "missing" or init_state == "empty" then
        return true, "clean"
    end
    if init_state == "error" then
        logger:error("[self-update] Refusing to start update: backup directory cannot be listed or verified: " .. tostring(bdir))
        return false, "backup_dir_unreadable"
    end
    local jpath = bdir .. sep .. "journal.txt"
    local cpath = bdir .. sep .. "journal.committed"
    if file_exists(jpath) and not verify_file_exact_bytes(cpath, "COMMITTED\n") then
        logger:info("[self-update] Existing active journal found before new update; attempting recovery first")
        recover_interrupted_update()
        if file_exists(jpath) and not verify_file_exact_bytes(cpath, "COMMITTED\n") then
            logger:error("[self-update] Refusing to start update: previous interrupted update recovery is still pending in " .. tostring(bdir))
            return false, "pending_recovery_locked"
        end
    end
    if file_exists(cpath) or file_exists(jpath) then
        local ok_clean, clean_reason = cleanup_backup_dir(bdir, sep, nil)
        local empty_ok = backup_dir_is_confirmed_empty(bdir)
        if not ok_clean or not empty_ok then
            logger:error("[self-update] Refusing to start update: previous backup directory could not be cleaned in " .. tostring(bdir) .. " (" .. tostring(clean_reason) .. ")")
            return false, (clean_reason == "backup_dir_unreadable" and "backup_dir_unreadable" or "pre_cleanup_failed")
        end
    else
        local ok_purge, purge_reason = purge_unpromoted_backup_dir(bdir, sep, nil)
        local empty_ok = backup_dir_is_confirmed_empty(bdir)
        if not ok_purge or not empty_ok then
            logger:error("[self-update] Refusing to start update: leftover files in backup directory could not be purged in " .. tostring(bdir) .. " (" .. tostring(purge_reason) .. ")")
            return false, (purge_reason == "backup_dir_unreadable" and "backup_dir_unreadable" or "pre_cleanup_failed")
        end
    end
    local final_empty, final_reason = backup_dir_is_confirmed_empty(bdir)
    if not final_empty then
        return false, (final_reason == "list_failed" and "backup_dir_unreadable" or "pre_cleanup_failed")
    end
    return true, "clean"
end

function commit_staged_update()
    touch_session_heartbeat(true)
    local dir = resolve_plugin_dir()
    if not dir then return "no_plugin_dir" end
    local sep = path_separator()
    if not STAGED_FILES["plugin.json"] or not STAGED_FILES["backend/main.lua"] or (not STAGED_FILES[".millennium/dist/index.js"] and not STAGED_FILES[".millennium/Dist/index.js"]) then
        return "incomplete_stage"
    end
    if not is_windows then
        local upper_dist = dir .. "/.millennium/Dist"
        local lower_dist = dir .. "/.millennium/dist"
        if is_directory(upper_dist) and not is_directory(lower_dist) then
            pcall(os.rename, upper_dist, lower_dist)
        end
    end

    local bdir = dir .. sep .. ".repage_update_backup"
    local pre_ok, pre_reason = ensure_clean_backup_dir_before_transaction(bdir, sep)
    if not pre_ok then
        return pre_reason or "pre_cleanup_failed"
    end

    local write_plan = {}
    local ordered_rels = {}
    local backups = {}
    local stage_dir = dir .. sep .. ".repage_update_stage"
    if is_symlink_path(stage_dir) then return "stage_symlink_blocked" end
    for rel, src_path in pairs(STAGED_FILES) do
        local target_rel = rel
        if target_rel == ".millennium/Dist/index.js" then
            target_rel = ".millennium/dist/index.js"
        end
        if not ALLOWED_UPDATE_FILES[target_rel] then
            return "disallowed_path:" .. tostring(target_rel)
        end
        if path_has_symlink_component(stage_dir, target_rel) or is_symlink_path(src_path) then
            return "stage_symlink_blocked:" .. tostring(target_rel)
        end
        local rf = io.open(src_path, "rb")
        if not rf then return "stage_open_failed:" .. target_rel end
        local new_bytes = rf:read("*a")
        rf:close()
        if not new_bytes or #new_bytes == 0 then
            return "stage_empty:" .. target_rel
        end
        local dst = dir .. sep .. target_rel:gsub("/", sep)
        if file_exists(dst) then
            local bf = io.open(dst, "rb")
            if not bf then return "backup_read_failed:" .. target_rel end
            local old_bytes = bf:read("*a")
            bf:close()
            if old_bytes == nil then return "backup_read_failed:" .. target_rel end
            backups[target_rel] = { existed = true, bytes = old_bytes, dst = dst }
        else
            backups[target_rel] = { existed = false, bytes = nil, dst = dst }
        end
        if not write_plan[target_rel] then
            table.insert(ordered_rels, target_rel)
        end
        write_plan[target_rel] = { dst = dst, new_bytes = new_bytes, stage_src = src_path }
    end

    table.sort(ordered_rels, function(a, b)
        local wa = (a == "backend/main.lua" and 3) or (a == "plugin.json" and 2) or 1
        local wb = (b == "backend/main.lua" and 3) or (b == "plugin.json" and 2) or 1
        if wa ~= wb then return wa < wb end
        return a < b
    end)

    pcall(fs.create_directories, bdir)
    local journal_lines = { "ACTIVE\t" .. tostring(#ordered_rels) }
    for _, rel in ipairs(ordered_rels) do
        local b = backups[rel]
        if b.existed then
            local bfile = bdir .. sep .. encode_backup_name(rel) .. ".bak"
            local wf = io.open(bfile, "wb")
            if not wf then
                purge_unpromoted_backup_dir(bdir, sep, ordered_rels)
                return "backup_write_failed:" .. rel
            end
            local ok_b = wf:write(b.bytes)
            local ok_f = wf:flush()
            wf:close()
            if not ok_b or ok_f == false or not verify_file_size(bfile, #b.bytes) then
                purge_unpromoted_backup_dir(bdir, sep, ordered_rels)
                return "backup_verify_failed:" .. rel
            end
            table.insert(journal_lines, "EXISTED\t" .. rel)
        else
            table.insert(journal_lines, "NEW\t" .. rel)
        end
    end
    table.insert(journal_lines, "END_JOURNAL\t" .. tostring(#ordered_rels))
    local journal_payload = table.concat(journal_lines, "\n") .. "\n"

    local jpath = bdir .. sep .. "journal.txt"
    local jtmp = jpath .. ".tmp"
    if not write_verified_marker(jtmp, jpath, journal_payload) then
        pcall(os.remove, jpath)
        purge_unpromoted_backup_dir(bdir, sep, ordered_rels)
        return "journal_verify_failed"
    end

    local modified = {}
    local function rollback_all(reason)
        logger:error("commit_staged_update failed (" .. tostring(reason) .. "); rolling back " .. tostring(#modified) .. " file(s)")
        local rollback_ok = true
        for i = #modified, 1, -1 do
            local rel = modified[i]
            local b = backups[rel]
            if b then
                pcall(os.remove, b.dst .. ".tmp_new")
                pcall(os.remove, b.dst .. ".old_swap")
                if b.existed and b.bytes ~= nil then
                    local tmp_restore = b.dst .. ".tmp_restore"
                    local wf = io.open(tmp_restore, "wb")
                    if not wf then
                        rollback_ok = false
                    else
                        local ok_rw = wf:write(b.bytes)
                        local ok_rf = wf:flush()
                        wf:close()
                        if not ok_rw or ok_rf == false or not replace_file_safely(tmp_restore, b.dst, b.bytes) or not verify_file_size(b.dst, #b.bytes) then
                            pcall(os.remove, tmp_restore)
                            rollback_ok = false
                        end
                    end
                elseif not b.existed then
                    if file_exists(b.dst) then
                        pcall(os.remove, b.dst)
                        if file_exists(b.dst) then
                            rollback_ok = false
                        end
                    end
                end
            end
        end
        if rollback_ok then
            cleanup_backup_dir(bdir, sep, ordered_rels)
        else
            logger:error("[self-update] In-process rollback had errors; preserving .repage_update_backup for startup recovery")
        end
    end

    for _, rel in ipairs(ordered_rels) do
        local plan = write_plan[rel]
        local parent = plan.dst:match("^(.*)[/\\][^/\\]+$")
        if parent and not is_directory(parent) then
            pcall(fs.create_directories, parent)
        end
        local tmp_dst = plan.dst .. ".tmp_new"
        local tf = io.open(tmp_dst, "wb")
        if not tf then
            rollback_all("tmp_open:" .. rel)
            return "commit_write_failed:" .. rel
        end
        local ok_w = tf:write(plan.new_bytes)
        local ok_f = tf:flush()
        tf:close()
        if not ok_w or ok_f == false or not verify_file_size(tmp_dst, #plan.new_bytes) then
            pcall(os.remove, tmp_dst)
            rollback_all("tmp_verify:" .. rel)
            return "commit_verify_failed:" .. rel
        end

        table.insert(modified, rel)
        if not replace_file_safely(tmp_dst, plan.dst, plan.new_bytes) or not verify_file_size(plan.dst, #plan.new_bytes) then
            rollback_all("replace:" .. rel)
            return "commit_verify_failed:" .. rel
        end
        pcall(os.remove, plan.stage_src)
    end

    local clean_ok, clean_state = cleanup_backup_dir(bdir, sep, ordered_rels)
    STAGED_FILES = {}
    local stage_clean_ok = remove_tree_safe(dir .. sep .. ".repage_update_stage", 0)
    if not stage_clean_ok then
        logger:error("[self-update] Could not confirm removal of .repage_update_stage; cleanup deferred to next startup")
    end
    if not is_windows then
        local lower_d = dir .. "/.millennium/dist"
        local upper_d = dir .. "/.millennium/Dist"
        if is_directory(lower_d) and not file_exists(upper_d .. "/index.js") then
            pcall(os.execute, "ln -sfn dist " .. shell_quote(upper_d) .. " 2>/dev/null")
        end
        pcall(os.execute, "chmod -R u+rwX,go+rX " .. shell_quote(dir) .. " 2>/dev/null")
        if file_exists(dir .. "/linux-fix.sh") then
            pcall(os.execute, "chmod u+x,go+rx " .. shell_quote(dir .. "/linux-fix.sh") .. " 2>/dev/null")
        end
    end
    if not clean_ok then
        if clean_state == "journal_active" then
            logger:error("[self-update] Update files were written, but journal neutralization failed; returning commit_journal_finalize_failed")
            return "commit_journal_finalize_failed"
        end
        logger:info("[self-update] Update committed and journal neutralized; backup file cleanup deferred to next startup")
        return "ok_cleanup_pending"
    end
    if not stage_clean_ok then
        return "ok_cleanup_pending"
    end
    logger:info("Self-update committed cleanly to " .. dir)
    return "ok"
end

local function check_and_repair_linux_frontend()
    if is_windows then return end
    local dir = resolve_plugin_dir()
    if not dir then
        logger:error("[linux-frontend] Could not resolve plugin folder; check plugins directory path.")
        return
    end
    local lower_idx = dir .. "/.millennium/dist/index.js"
    local upper_idx = dir .. "/.millennium/Dist/index.js"
    local has_lower = file_exists(lower_idx)
    local has_upper = file_exists(upper_idx)
    if not has_lower and not has_upper then
        logger:error("[linux-frontend] Frontend missing! Neither .millennium/dist/index.js nor .millennium/Dist/index.js is readable in " .. dir)
    else
        logger:info(string.format("[linux-frontend] Check OK in %s (dist=%s, Dist=%s)", dir, tostring(has_lower), tostring(has_upper)))
    end
    if has_lower and not has_upper then
        pcall(os.execute, "ln -sfn dist " .. shell_quote(dir .. "/.millennium/Dist") .. " 2>/dev/null")
    elseif has_upper and not has_lower then
        pcall(os.execute, "ln -sfn Dist " .. shell_quote(dir .. "/.millennium/dist") .. " 2>/dev/null")
    end
    pcall(os.execute, "chmod -R u+rwX,go+rX " .. shell_quote(dir) .. " 2>/dev/null")
    if file_exists(dir .. "/linux-fix.sh") then
        pcall(os.execute, "chmod u+x,go+rx " .. shell_quote(dir .. "/linux-fix.sh") .. " 2>/dev/null")
    end
end

-- PLATFORM

function get_platform()
    touch_session_heartbeat(false)
    return platform_name
end

-- PLUGIN MANAGEMENT

local function on_frontend_loaded()
    touch_session_heartbeat(true)
    logger:info("Frontend loaded")
end

local function is_session_heartbeat_active(dir, sep, sid, now, ttl)
    if not sid or sid == "" then return false end
    if sid == session_prefix then return true end
    local hb = dir .. sep .. "repage_hb_" .. sid .. ".lock"
    local f = io.open(hb, "rb")
    if not f then return false end
    local raw = f:read(64) or ""
    f:close()
    local ts = tonumber(raw:match("(%d+)"))
    if ts and (now - ts) <= ttl and ts <= (now + 60) then
        return true
    end
    return false
end

local function cleanup_stale_temp_files()
    local dir = temp_directory()
    if not dir then return end
    local sep = path_separator()
    touch_session_heartbeat(true)
    local own_prefix = TEMP_PREFIX .. session_prefix .. "_"
    local own_update = "repage_update_" .. session_prefix .. ".zip"
    local own_hb = "repage_hb_" .. session_prefix .. ".lock"
    local now = os.time()
    local STALE_TTL = 3600
    for _, entry in ipairs(icons.safe_list(dir)) do
        if entry.is_file then
            local name = icons.base_name(entry.path)
            if name:match("^repage_hb_.*%.lock$") and name ~= own_hb then
                local sid = name:match("^repage_hb_(%d+x%d+)%.lock$")
                if not is_session_heartbeat_active(dir, sep, sid, now, STALE_TTL) then
                    pcall(os.remove, entry.path)
                end
            else
                local is_other_bin = name:match("^repage_.*%.bin$") and name:sub(1, #own_prefix) ~= own_prefix
                local is_other_zip = name:match("^repage_update_.*%.zip$") and name ~= own_update
                if is_other_bin or is_other_zip then
                    local sid = name:match("^repage_update_(%d+x%d+)") or name:match("^repage_(%d+x%d+)_")
                    local file_ts = tonumber(name:match("_t(%d+)_") or name:match("^repage_update_(%d+)x") or name:match("^repage_(%d+)x"))
                    local session_alive = is_session_heartbeat_active(dir, sep, sid, now, STALE_TTL)
                    local file_fresh = file_ts and ((now - file_ts) <= STALE_TTL and file_ts <= (now + 60)) or false
                    if not session_alive and not file_fresh then
                        pcall(os.remove, entry.path)
                    end
                end
            end
        end
    end
end

local function on_load()
    pcall(recover_interrupted_update)
    pcall(cleanup_stale_stage_dir)
    cleanup_stale_temp_files()
    check_and_repair_linux_frontend()
    logger:info("Backend loaded on " .. platform_name .. " (temp dir: " .. tostring(temp_directory()) .. ")")
    millennium.ready()
end

local function on_unload()
    local cached_urls = {}
    for url in pairs(img_cache) do
        table.insert(cached_urls, url)
    end
    for _, url in ipairs(cached_urls) do
        drop_cached(url, true)
    end
    pcall(cleanup_update_zip)
    pcall(remove_session_heartbeat)
    logger:info("Backend unloaded; temporary cache cleaned")
end

return {
    on_frontend_loaded = on_frontend_loaded,
    on_load = on_load,
    on_unload = on_unload
}