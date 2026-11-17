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

local function can_write_in(dir)
    if not dir then return false end
    local probe = dir .. path_separator() .. ".sgdb_write_test"
    local f = io.open(probe, "wb")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
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
        table.insert(candidates, "/tmp")
        local runtime = env("XDG_RUNTIME_DIR")
        if runtime then table.insert(candidates, strip_trailing_sep(runtime)) end
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
local function make_tmpfile()
    download_counter = download_counter + 1
    return temp_directory() .. path_separator() .. TEMP_PREFIX .. session_prefix .. "_" .. tostring(download_counter) .. ".bin"
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
        logger:error(err)
        return ""
    end

    if response.status ~= 200 then
        if response.status == 401 then
            logger:error(string.format("Got HTTP %d, did you make sure to set an API key in the Repage SteamGrid configuration?", response.status))
        else
            logger:error(string.format("Got HTTP %d", response.status))
        end
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
        -- Only reuse the cached file if it still exists on disk
        local f = io.open(img_cache[a_img_url], "rb")
        if f then
            local sz = f:seek("end") or 0
            f:close()
            if sz > 0 then
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

-- Size in bytes of the artwork file for this slot and extension, or -1 if missing
function artwork_file_size(a_appid, b_imagetype, c_ext, d_expected)
    local suffix = ARTWORK_STEM_SUFFIX[b_imagetype]
    local app = appid_string(a_appid)
    local ext = sanitize_ext(c_ext)
    if suffix == nil or not app or not ext then return -1 end
    local file_name = app .. suffix .. "." .. ext
    local expected = tonumber(d_expected)
    local first_size = -1
    for _, grid_dir in ipairs(icons.grid_dirs(false)) do
        local f = io.open(fs.join(grid_dir, file_name), "rb")
        if f then
            local size = f:seek("end") or -1
            f:close()
            if expected and expected > 0 and size == expected then
                return size
            end
            if first_size < 0 and size > 0 then
                first_size = size
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
    local dirs = icons.grid_dirs(false)
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
                local max_size = ext == "webm" and (4 * 1024 * 1024) or (6 * 1024 * 1024)
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
    for _, grid_dir in ipairs(icons.grid_dirs(false)) do
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

-- PLATFORM

-- "windows" | "linux" | "steamdeck" | "macos". Used by the frontend to pick
-- platform-specific wording and behavior.
function get_platform()
    return platform_name
end

-- PLUGIN MANAGEMENT

local function on_frontend_loaded()
    logger:info("Frontend loaded")
end

local function cleanup_stale_temp_files()
    local dir = temp_directory()
    if not dir then return end
    local own_prefix = TEMP_PREFIX .. session_prefix .. "_"
    for _, entry in ipairs(icons.safe_list(dir)) do
        if entry.is_file then
            local name = icons.base_name(entry.path)
            if name:match("^repage_.*%.bin$") and name:sub(1, #own_prefix) ~= own_prefix then
                pcall(os.remove, entry.path)
            end
        end
    end
end

local function on_load()
    cleanup_stale_temp_files()
    logger:info("Backend loaded on " .. platform_name .. " (temp dir: " .. tostring(temp_directory()) .. ")")
    millennium.ready()
end

local function on_unload()
    -- These are plugin-owned temporary downloads, not Steam artwork. Remove
    -- every tracked file when the backend unloads so normal shutdown/reload
    -- does not leave cache files accumulating in the system temp directory.
    local cached_urls = {}
    for url in pairs(img_cache) do
        table.insert(cached_urls, url)
    end
    for _, url in ipairs(cached_urls) do
        drop_cached(url, true)
    end
    logger:info("Backend unloaded; temporary cache cleaned")
end

return {
    on_frontend_loaded = on_frontend_loaded,
    on_load = on_load,
    on_unload = on_unload
}