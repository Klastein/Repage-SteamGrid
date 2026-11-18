local millennium = require("millennium")
local utils = require("utils")
local fs = require("fs")
local logger = require("logger")

local M = {}

local BACKUP_SUFFIX = ".easygrid_orig"
local PNG_SIGNATURE = "\137\80\78\71\13\10\26\10"

-- ---------------------------------------------------------------------------
-- Portable helpers (Windows / Linux / Steam Deck / macOS)
-- Every filesystem call that can fail because of permissions, a missing folder
-- or a sandbox (Flatpak, SteamOS read-only areas) goes through these wrappers,
-- so one bad folder never aborts the whole operation.
-- ---------------------------------------------------------------------------

local function safe_exists(path)
    local ok, result = pcall(fs.exists, path)
    return ok and result and true or false
end

local function safe_list(dir)
    local ok, entries = pcall(fs.list, dir)
    if ok and type(entries) == "table" then
        return entries
    end
    return {}
end

-- Last component of a path, whatever the separator is.
local function base_name(path)
    local trimmed = tostring(path or ""):gsub("[/\\]+$", "")
    return trimmed:match("([^/\\]+)$") or ""
end

local function steam_root()
    local ok, path = pcall(millennium.steam_path)
    if ok and type(path) == "string" and path ~= "" then
        return path
    end
    return nil
end

-- Non-Steam shortcut ids are unsigned 32-bit numbers in file names, but some
-- callers hand them over as signed values.
local ALLOWED_ICON_EXTS = { png = true, jpg = true, jpeg = true, webp = true, gif = true, ico = true }

local function normalize_appid(appid)
    local n = tonumber(appid)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n)
    if n < 0 then n = n + 4294967296 end
    if n < 0 or n > 4294967295 then return nil end
    return string.format("%d", n)
end

local function sanitize_extension(ext, default_ext)
    local clean = tostring(ext or default_ext or "png"):lower():gsub("^%.", "")
    if ALLOWED_ICON_EXTS[clean] then
        return clean
    end
    return nil
end

local function steam_userdata_path()
    local root = steam_root()
    if not root then return nil end
    return fs.join(root, "userdata")
end

local function steam_library_cache_path()
    local root = steam_root()
    if not root then return nil end
    return fs.join(root, "appcache", "librarycache")
end

-- Steam account folders are numeric ids. "0" is a placeholder and anything
-- else (".DS_Store" folders on macOS, stray directories) is not an account.
local function is_account_dir(entry)
    if not entry or not entry.is_directory then return false end
    local name = base_name(entry.path)
    return name:match("^%d+$") ~= nil and name ~= "0"
end

-- SteamID64 -> 32-bit account id (the folder name under userdata/).
-- Subtracted as decimal strings so LuaJIT (53-bit float) never loses precision.
local STEAMID64_BASE_STR = "76561197960265728"

local function decimal_gt(a, b)
    if #a ~= #b then return #a > #b end
    return a > b
end

local function subtract_steamid64_base(steamid)
    if type(steamid) ~= "string" or not steamid:match("^%d+$") then return nil end
    if not decimal_gt(steamid, STEAMID64_BASE_STR) then return nil end
    local res, borrow = {}, 0
    local ia, ib = #steamid, #STEAMID64_BASE_STR
    while ia > 0 or ib > 0 do
        local da = ia > 0 and (steamid:byte(ia) - 48) or 0
        local db = ib > 0 and (STEAMID64_BASE_STR:byte(ib) - 48) or 0
        local diff = da - db - borrow
        if diff < 0 then
            diff = diff + 10
            borrow = 1
        else
            borrow = 0
        end
        res[#res + 1] = string.char(48 + diff)
        ia = ia - 1
        ib = ib - 1
    end
    local out = string.reverse(table.concat(res)):gsub("^0+", "")
    if out == "" then return nil end
    local acc = tonumber(out)
    if not acc or acc <= 0 or acc > 4294967295 then return nil end
    return out
end

---Account id (string) of the Steam user that is currently logged in, read from
---config/loginusers.vdf ("MostRecent" "1"). Returns nil when it cannot be
---determined, in which case callers fall back to every account folder.
---@return string|nil
function M.active_account_id()
    local root = steam_root()
    if not root then return nil end
    local f = io.open(fs.join(root, "config", "loginusers.vdf"), "rb")
    if not f then return nil end
    local content = f:read(512 * 1024)
    f:close()
    if type(content) ~= "string" or content == "" then return nil end
    local best_ts = -1
    local best_id = nil
    for steamid, block in content:gmatch('"(7656%d+)"%s*(%b{})') do
        if block:find('"[Mm]ost[Rr]ecent"%s*"1"') then
            local account_id = subtract_steamid64_base(steamid)
            if account_id then
                return account_id
            end
        end
        local ts_str = block:match('"[Tt]imestamp"%s*"(%d+)"')
        local ts = ts_str and tonumber(ts_str) or -1
        if ts and ts > best_ts then
            local account_id = subtract_steamid64_base(steamid)
            if account_id then
                best_ts = ts
                best_id = account_id
            end
        end
    end
    return best_id
end

---Config/grid folder to operate on. Never performs destructive or write
---operations across multiple accounts when the active account is ambiguous.
---@param create boolean create missing config/grid folder for the resolved account
---@param allow_multi_read boolean|nil allow read-only fallback across accounts
---@return string[]
function M.grid_dirs(create, allow_multi_read)
    local result = {}
    local userdata_path = steam_userdata_path()
    if not userdata_path or not safe_exists(userdata_path) then
        return result
    end

    local active = M.active_account_id()
    if active then
        local account_dir = fs.join(userdata_path, active)
        if safe_exists(account_dir) or create then
            local grid_dir = fs.join(account_dir, "config", "grid")
            if not safe_exists(grid_dir) and create then
                pcall(fs.create_directories, grid_dir)
            end
            if safe_exists(grid_dir) then
                table.insert(result, grid_dir)
            end
        end
        return result
    end

    local account_entries = {}
    for _, entry in ipairs(safe_list(userdata_path)) do
        if is_account_dir(entry) then
            table.insert(account_entries, entry)
        end
    end

    if #account_entries == 1 then
        local grid_dir = fs.join(account_entries[1].path, "config", "grid")
        if not safe_exists(grid_dir) and create then
            pcall(fs.create_directories, grid_dir)
        end
        if safe_exists(grid_dir) then
            table.insert(result, grid_dir)
        end
        return result
    end

    if not allow_multi_read then
        logger:error("grid_dirs: active Steam account could not be identified among " .. tostring(#account_entries) .. " accounts; refusing multi-account write/delete")
        return result
    end

    for _, entry in ipairs(account_entries) do
        local grid_dir = fs.join(entry.path, "config", "grid")
        if safe_exists(grid_dir) then
            table.insert(result, grid_dir)
        end
    end
    return result
end

M.safe_exists = safe_exists
M.safe_list = safe_list
M.base_name = base_name

local STEM_EXTENSIONS = { "png", "jpg", "jpeg", "webp", "gif", "ico", "webm" }

local function path_exists_as_file(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

-- Removes dir/<stem>.<ext> for every extension Steam artwork can use. This probes
-- a handful of exact paths instead of listing the folder: librarycache and grid
-- folders can hold thousands of files and were listed on every apply.
-- keep_ext (optional) is left untouched.
local function remove_matching_stem(dir, stem, keep_ext)
    local removed = false
    for _, ext in ipairs(STEM_EXTENSIONS) do
        if not (keep_ext and ext == keep_ext) then
            local path = fs.join(dir, stem .. "." .. ext)
            if path_exists_as_file(path) then
                local ok, res = pcall(fs.remove, path)
                if ok and res ~= false then
                    removed = true
                end
            end
        end
    end
    return removed
end
M.remove_matching_stem = remove_matching_stem
M.path_exists_as_file = path_exists_as_file

local function is_hashed_icon_file(entry)
    if not entry.is_file then return false end
    local stem = fs.stem(entry.path)
    local ext = string.lower(fs.extension(entry.path) or "")
    return #stem == 40 and string.match(stem, "^%x+$") ~= nil
        and (ext == ".jpg" or ext == ".jpeg" or ext == ".png" or ext == ".ico")
end

local function read_u16(bytes, offset)
    local b1, b2 = string.byte(bytes, offset + 1, offset + 2)
    return (b1 or 0) + (b2 or 0) * 256
end

local function read_u32(bytes, offset)
    local b1, b2, b3, b4 = string.byte(bytes, offset + 1, offset + 4)
    return (b1 or 0) + (b2 or 0) * 256 + (b3 or 0) * 65536 + (b4 or 0) * 16777216
end

local function extract_png_from_ico(bytes)
    if #bytes < 6 then return nil end
    if read_u16(bytes, 0) ~= 0 or read_u16(bytes, 2) ~= 1 then return nil end
    local count = read_u16(bytes, 4)

    local best_chunk = nil
    local best_area = -1
    for i = 0, count - 1 do
        local entry_offset = 6 + i * 16
        if entry_offset + 16 > #bytes then break end
        local width = string.byte(bytes, entry_offset + 1) or 0
        local height = string.byte(bytes, entry_offset + 2) or 0
        if width == 0 then width = 256 end
        if height == 0 then height = 256 end
        local data_size = read_u32(bytes, entry_offset + 8)
        local data_offset = read_u32(bytes, entry_offset + 12)

        if data_size > 0 and data_offset + data_size <= #bytes then
            local chunk = string.sub(bytes, data_offset + 1, data_offset + data_size)
            if string.sub(chunk, 1, 8) == PNG_SIGNATURE then
                local area = width * height
                if area > best_area then
                    best_area = area
                    best_chunk = chunk
                end
            end
        end
    end

    return best_chunk
end

local function write_bytes(path, bytes)
    local ok, result = pcall(utils.write_file, path, bytes)
    if not ok then
        logger:error("write_icon: could not write " .. tostring(path) .. ": " .. tostring(result))
        return false
    end
    return result ~= false
end

---Write icon bytes to every location Steam reads an app icon from.
---@param appid string|number
---@param bytes string raw file bytes (already downloaded)
---@param extension string file extension without the dot, e.g. "png" or "ico"
---@return boolean success
function M.write_icon(appid, bytes, extension)
    appid = normalize_appid(appid)
    if not appid then
        logger:error("write_icon: invalid appid")
        return false
    end
    extension = sanitize_extension(extension, "png")
    if not extension then
        logger:error("write_icon: unsupported extension for appid " .. appid)
        return false
    end

    if extension == "ico" then
        local png_bytes = extract_png_from_ico(bytes)
        if not png_bytes then
            logger:error("write_icon: .ico has no embedded PNG frame, skipping appid " .. appid)
            return false
        end
        bytes = png_bytes
        extension = "png"
    end

    local wrote_any = false
    local base = appid .. "_icon"

    local file_name = base .. "." .. extension
    for _, grid_dir in ipairs(M.grid_dirs(true)) do
        remove_matching_stem(grid_dir, base, extension)
        if write_bytes(fs.join(grid_dir, file_name), bytes) then
            wrote_any = true
        end
    end

    local cache_dir = steam_library_cache_path()
    if cache_dir and safe_exists(cache_dir) then
        remove_matching_stem(cache_dir, base, extension)
        if write_bytes(fs.join(cache_dir, base .. "." .. extension), bytes) then
            wrote_any = true
        end

        local app_cache_dir = fs.join(cache_dir, appid)
        if safe_exists(app_cache_dir) then
            for _, entry in ipairs(safe_list(app_cache_dir)) do
                if is_hashed_icon_file(entry) then
                    local backup_path = entry.path .. BACKUP_SUFFIX
                    if not safe_exists(backup_path) then
                        pcall(fs.copy, entry.path, backup_path)
                    end
                    if write_bytes(entry.path, bytes) then
                        wrote_any = true
                    end
                end
            end
        end
    end

    return wrote_any
end

---Remove any custom icon set via write_icon and restore the original hashed
---cache file from backup, if one was made.
---@param appid string|number
---@return boolean changed
function M.clear_icon(appid)
    appid = normalize_appid(appid)
    if not appid then
        logger:error("clear_icon: invalid appid")
        return false
    end
    local base = appid .. "_icon"
    local changed = false

    local cache_dir = steam_library_cache_path()
    if cache_dir and safe_exists(cache_dir) then
        if remove_matching_stem(cache_dir, base) then
            changed = true
        end

        local app_cache_dir = fs.join(cache_dir, appid)
        if safe_exists(app_cache_dir) then
            for _, entry in ipairs(safe_list(app_cache_dir)) do
                if entry.is_file and utils.endswith(entry.path, BACKUP_SUFFIX) then
                    local original_path = string.sub(entry.path, 1, #entry.path - #BACKUP_SUFFIX)
                    if safe_exists(original_path) then
                        pcall(fs.remove, original_path)
                    end
                    local ok_copy, copied = pcall(fs.copy, entry.path, original_path)
                    if ok_copy and copied ~= false and safe_exists(original_path) then
                        pcall(fs.remove, entry.path)
                        changed = true
                    else
                        logger:error("clear_icon: failed to restore backup " .. tostring(entry.path))
                    end
                end
            end
        end
    end

    for _, grid_dir in ipairs(M.grid_dirs(false)) do
        if remove_matching_stem(grid_dir, base) then
            changed = true
        end
    end

    return changed
end

return M
