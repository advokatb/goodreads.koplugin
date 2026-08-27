-- goodreads_settings.lua
-- Wrapper over LuaSettings (global plugin settings) and DocSettings (per-document sidecar).
--
-- Global settings: <data_dir>/settings/goodreads_settings.lua
--
-- Book link stored in document sidecar under key "goodreads":
--   {
--     edition_id    = "944073",   -- Goodreads legacy book id (same as book_id)
--     book_id       = "944073",
--     review_id     = nil,        -- optional; not required for status/rating
--     title         = "Title",
--     authors       = "Author",
--     goodreads_url = "https://www.goodreads.com/book/show/944073.The_Blade_Itself",
--     status        = 2,          -- 0 to-read / 1 read / 2 currently-reading / 3 DNF / -2 removed
--     shelf         = "currently-reading", -- exclusive shelf slug (source of truth for extras)
--     rating        = 5,          -- last sent Goodreads rating (1–5)
--     date_read     = "2026-08-26", -- last sent finished date (reading session)
--     last_progress = 10,         -- last posted /user_status.json percent
--     pages         = 480,        -- optional page count from /book/show
--     sync          = true,       -- auto-tracking for this book (nil → always_sync)
--   }

local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local logger = require("logger")

local GoodreadsSettings = {}
GoodreadsSettings.__index = GoodreadsSettings

-- Unique sentinel: Lua `{ key = nil }` omits the key, so callers pass this to delete.
GoodreadsSettings.UNSET = {}

GoodreadsSettings.KEY_COOKIE          = "session_cookie"
GoodreadsSettings.KEY_CONFIRM         = "menu_confirmation"
GoodreadsSettings.KEY_ALWAYS_SYNC     = "always_sync"
GoodreadsSettings.KEY_ENABLE_WIFI     = "enable_wifi"
GoodreadsSettings.KEY_SYNC_RATING     = "sync_rating"
GoodreadsSettings.KEY_MARK_READING_AT = "mark_reading_at_percent"
GoodreadsSettings.KEY_AUTO_LINK       = "auto_link_by_goodreads_id"
GoodreadsSettings.KEY_AUTO_LINK_ISBN  = "auto_link_by_isbn"
GoodreadsSettings.KEY_SYNC_PROGRESS   = "sync_progress"
GoodreadsSettings.KEY_USER_ID         = "user_id"
GoodreadsSettings.KEY_EXCLUSIVE_SHELVES = "exclusive_shelves"

function GoodreadsSettings:new(path, ui)
  local o = setmetatable({}, self)
  o.settings = LuaSettings:open(path)
  o.ui = ui
  return o
end

-- ─── Global settings ─────────────────────────────────────────────────────────

local function strip_jwt_token(cookie)
  if not cookie or cookie == "" then return "" end
  cookie = cookie:gsub(";?%s*jwt_token=[^;]*", "")
  cookie = cookie:gsub("^%s*;%s*", "")
  cookie = cookie:gsub("%s*;%s*$", "")
  return cookie
end

function GoodreadsSettings:readSetting(key)
  return self.settings:readSetting(key)
end

function GoodreadsSettings:updateSetting(key, value)
  self.settings:saveSetting(key, value)
  self.settings:flush()
end

--- Session cookies (from settings or goodreads_config.lua fallback)
function GoodreadsSettings:getCookie()
  local cookie = self:readSetting(GoodreadsSettings.KEY_COOKIE)
  if not cookie or cookie == "" then
    package.loaded["goodreads_config"] = nil
    local ok, config = pcall(require, "goodreads_config")
    if ok and config and config.session_cookie and config.session_cookie ~= "" then
      cookie = config.session_cookie
      logger.info("Goodreads: loaded cookie from goodreads_config.lua")
    end
  end
  return strip_jwt_token(cookie or "")
end

function GoodreadsSettings:setCookie(value)
  self:updateSetting(GoodreadsSettings.KEY_COOKIE, strip_jwt_token(value or ""))
end

function GoodreadsSettings:menuConfirm()
  return self:readSetting(GoodreadsSettings.KEY_CONFIRM) == true
end

function GoodreadsSettings:setMenuConfirm(value)
  self:updateSetting(GoodreadsSettings.KEY_CONFIRM, value)
end

function GoodreadsSettings:enableWifiOnDemand()
  return self:readSetting(GoodreadsSettings.KEY_ENABLE_WIFI) == true
end

function GoodreadsSettings:setEnableWifiOnDemand(value)
  self:updateSetting(GoodreadsSettings.KEY_ENABLE_WIFI, value == true)
end

function GoodreadsSettings:syncRatingEnabled()
  local v = self:readSetting(GoodreadsSettings.KEY_SYNC_RATING)
  if v == nil then return true end
  return v == true
end

function GoodreadsSettings:setSyncRatingEnabled(value)
  self:updateSetting(GoodreadsSettings.KEY_SYNC_RATING, value == true)
end

function GoodreadsSettings:alwaysSync()
  return self:readSetting(GoodreadsSettings.KEY_ALWAYS_SYNC) == true
end

function GoodreadsSettings:setAlwaysSync(value)
  self:updateSetting(GoodreadsSettings.KEY_ALWAYS_SYNC, value == true)
end

function GoodreadsSettings:markReadingAtPercent()
  return self:readSetting(GoodreadsSettings.KEY_MARK_READING_AT) or 1
end

--- Autolink by embedded GOODREADS identifier (on by default).
function GoodreadsSettings:autoLinkByGoodreadsId()
  local v = self:readSetting(GoodreadsSettings.KEY_AUTO_LINK)
  if v == nil then return true end
  return v == true
end

function GoodreadsSettings:setAutoLinkByGoodreadsId(value)
  self:updateSetting(GoodreadsSettings.KEY_AUTO_LINK, value == true)
end

--- Autolink by ISBN when no GOODREADS id is present (on by default).
function GoodreadsSettings:autoLinkByIsbn()
  local v = self:readSetting(GoodreadsSettings.KEY_AUTO_LINK_ISBN)
  if v == nil then return true end
  return v == true
end

function GoodreadsSettings:setAutoLinkByIsbn(value)
  self:updateSetting(GoodreadsSettings.KEY_AUTO_LINK_ISBN, value == true)
end

--- POST /user_status.json percent while auto-tracking (on by default).
function GoodreadsSettings:syncProgressEnabled()
  local v = self:readSetting(GoodreadsSettings.KEY_SYNC_PROGRESS)
  if v == nil then return true end
  return v == true
end

function GoodreadsSettings:setSyncProgressEnabled(value)
  self:updateSetting(GoodreadsSettings.KEY_SYNC_PROGRESS, value == true)
end

function GoodreadsSettings:getUserId()
  local id = self:readSetting(GoodreadsSettings.KEY_USER_ID)
  if id and tostring(id):match("^%d+$") then
    return tostring(id)
  end
  return nil
end

function GoodreadsSettings:setUserId(value)
  if value and tostring(value):match("^%d+$") then
    self:updateSetting(GoodreadsSettings.KEY_USER_ID, tostring(value))
  end
end

function GoodreadsSettings:getExclusiveShelves()
  local v = self:readSetting(GoodreadsSettings.KEY_EXCLUSIVE_SHELVES)
  if type(v) == "table" and #v > 0 then
    return v
  end
  return { "to-read", "currently-reading", "read" }
end

function GoodreadsSettings:hasExclusiveShelf(name)
  if not name then return false end
  for _, shelf in ipairs(self:getExclusiveShelves()) do
    if shelf == name then return true end
  end
  return false
end

function GoodreadsSettings:setExclusiveShelves(list)
  if type(list) == "table" and #list > 0 then
    self:updateSetting(GoodreadsSettings.KEY_EXCLUSIVE_SHELVES, list)
  end
end

--- Drop cached user_id so the next request rediscovers it from /review/list.
function GoodreadsSettings:clearSessionCache()
  self:updateSetting(GoodreadsSettings.KEY_USER_ID, nil)
end

-- ─── Per-document (sidecar) settings ─────────────────────────────────────────

function GoodreadsSettings:_getDocSettings(filename)
  if self.ui and self.ui.doc_settings and self.ui.document
      and self.ui.document.file == filename then
    return self.ui.doc_settings
  end
  return DocSettings:open(filename)
end

function GoodreadsSettings:readBookSettings(filename)
  if not filename then return {} end
  local sidecar = self:_getDocSettings(filename)
  return sidecar:readSetting("goodreads") or {}
end

function GoodreadsSettings:readBookSetting(filename, key)
  return self:readBookSettings(filename)[key]
end

function GoodreadsSettings:updateBookSetting(filename, data)
  if not filename then return end

  local sidecar = self:_getDocSettings(filename)
  local current = sidecar:readSetting("goodreads") or {}

  for k, v in pairs(data) do
    if v == GoodreadsSettings.UNSET then
      current[k] = nil
    else
      current[k] = v
    end
  end

  sidecar:saveSetting("goodreads", current)
  sidecar:flush()
end

function GoodreadsSettings:clearBookSettings(filename)
  if not filename then return end
  local sidecar = self:_getDocSettings(filename)
  sidecar:saveSetting("goodreads", nil)
  sidecar:flush()
end

-- ─── Convenience getters for the current book ────────────────────────────────

function GoodreadsSettings:_currentFile()
  return self.ui and self.ui.document and self.ui.document.file
end

function GoodreadsSettings:bookLinked()
  local file = self:_currentFile()
  if not file then return false end
  return self:readBookSetting(file, "edition_id") ~= nil
end

function GoodreadsSettings:getLinkedEditionId()
  local file = self:_currentFile()
  if not file then return nil end
  return self:readBookSetting(file, "edition_id")
end

function GoodreadsSettings:getLinkedTitle()
  local file = self:_currentFile()
  if not file then return nil end
  return self:readBookSetting(file, "title")
end

function GoodreadsSettings:getLinkedStatus()
  local file = self:_currentFile()
  if not file then return nil end
  return self:readBookSetting(file, "status")
end

function GoodreadsSettings:getLinkedShelf()
  local file = self:_currentFile()
  if not file then return nil end
  if self:readBookSetting(file, "status") == -2 then
    return nil
  end
  local shelf = self:readBookSetting(file, "shelf")
  if type(shelf) == "string" and shelf ~= "" then
    return shelf
  end
  return nil
end

function GoodreadsSettings:fileSyncEnabled(filename)
  if not filename then return false end
  local sync_value = self:readBookSetting(filename, "sync")
  if sync_value == nil then
    sync_value = self:alwaysSync()
  end
  return sync_value == true
end

function GoodreadsSettings:syncEnabled()
  return self:fileSyncEnabled(self:_currentFile())
end

function GoodreadsSettings:setSync(value)
  local file = self:_currentFile()
  if not file then return end
  self:updateBookSetting(file, { sync = value == true })
end

function GoodreadsSettings:getKoreaderRating(filename)
  filename = filename or self:_currentFile()
  if not filename then return nil end
  local sidecar = self:_getDocSettings(filename)
  local summary = sidecar:readSetting("summary")
  if summary and summary.rating then
    return tonumber(summary.rating)
  end
  return nil
end

function GoodreadsSettings:getKoreaderStatus(filename)
  filename = filename or self:_currentFile()
  if not filename then return nil end
  local sidecar = self:_getDocSettings(filename)
  local summary = sidecar:readSetting("summary")
  if summary and summary.status and summary.status ~= "" then
    return summary.status
  end
  return nil
end

return GoodreadsSettings
