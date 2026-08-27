-- goodreads_api.lua
-- API facade for Goodreads. Routes calls to the legacy Rails backend.

local _ = require("lib/goodreads_i18n").gettext

local GoodreadsApiLegacy = require("goodreads_api_legacy")

-- Plugin status codes.
-- Extra exclusive shelves from the account have no fixed code; sidecar uses `shelf`.
local STATUS_KEYS = {
  [0]  = "Want to read",
  [1]  = "Finished",
  [2]  = "Currently reading",
  [3]  = "Did not finish",
  [-2] = "Status removed",
}

local SHELF_BY_STATUS = {
  [0] = "to-read",
  [1] = "read",
  [2] = "currently-reading",
  [3] = "did-not-finish",
}

local STATUS_BY_SHELF = {
  ["to-read"]           = 0,
  ["read"]              = 1,
  ["currently-reading"] = 2,
  ["did-not-finish"]    = 3,
}

local CORE_SHELVES = { "to-read", "currently-reading", "read" }
local CORE_SET = {
  ["to-read"]           = true,
  ["currently-reading"] = true,
  ["read"]              = true,
}

-- Well-known extra exclusive slug → translated label (only if present on the account).
local KNOWN_EXTRA = {
  ["did-not-finish"] = { label_key = "Did not finish", code = 3 },
  ["paused"]         = { label_key = "Paused" },
}

local GoodreadsApi = {
  settings = nil,
  on_error = nil,
}

local function humanize_slug(slug)
  local s = (slug or ""):gsub("%-", " ")
  if s == "" then return slug or "" end
  return s:sub(1, 1):upper() .. s:sub(2)
end

function GoodreadsApi:statusText(status_code)
  local key = STATUS_KEYS[status_code]
  return key and _(key) or _("Unknown status")
end

function GoodreadsApi:shelfLabel(shelf_name)
  if not shelf_name or shelf_name == "" then
    return _("Unknown status")
  end
  local code = STATUS_BY_SHELF[shelf_name]
  if code and STATUS_KEYS[code] then
    return _(STATUS_KEYS[code])
  end
  local known = KNOWN_EXTRA[shelf_name]
  if known then
    return _(known.label_key)
  end
  return humanize_slug(shelf_name)
end

function GoodreadsApi:shelfForStatus(status_code)
  return SHELF_BY_STATUS[status_code]
end

function GoodreadsApi:statusForShelf(shelf_name)
  if not shelf_name then return nil end
  return STATUS_BY_SHELF[shelf_name]
end

-- xgettext markers: STATUS_KEYS are translated via _(key) at runtime.
if false then
  local _ignore = {
    _("Want to read"),
    _("Finished"),
    _("Currently reading"),
    _("Did not finish"),
    _("Paused"),
    _("Status removed"),
  }
end

--- Radio items for Change status.
-- Always: the three system exclusive shelves + Status removed.
-- Plus any extra exclusive shelves discovered from ShelfChooser on the account
-- (custom exclusive like a user-made DNF shelf). Non-exclusive tag shelves
-- are not listed — those are tags, not reading status.
function GoodreadsApi:statusMenuItems()
  local exclusive = self.settings and self.settings:getExclusiveShelves() or CORE_SHELVES

  local items = {
    { code = 0,  shelf = "to-read",           label_key = "Want to read" },
    { code = 2,  shelf = "currently-reading", label_key = "Currently reading" },
    { code = 1,  shelf = "read",              label_key = "Finished" },
  }

  for _, shelf in ipairs(exclusive) do
    if not CORE_SET[shelf] then
      local known = KNOWN_EXTRA[shelf]
      table.insert(items, {
        code      = known and known.code or STATUS_BY_SHELF[shelf],
        shelf     = shelf,
        label_key = known and known.label_key or nil,
        label     = known and nil or humanize_slug(shelf),
      })
    end
  end

  table.insert(items, { code = -2, label_key = "Status removed" })
  return items
end

function GoodreadsApi:_get_backend()
  local backend = GoodreadsApiLegacy
  backend.settings = self.settings
  backend.on_error = self.on_error
  return backend
end

function GoodreadsApi:search(query)
  return self:_get_backend():search(query)
end

function GoodreadsApi:get_book(book_id)
  return self:_get_backend():get_book(book_id)
end

function GoodreadsApi:get_review_state(book_id)
  return self:_get_backend():get_review_state(book_id)
end

--- Set exclusive-shelf status.
-- @param book_id      Goodreads legacy book id
-- @param status       0 / 1 / 2 / 3 / -2 (nil when using a custom exclusive shelf)
-- @param _unused      kept for call-site compatibility (no review_id needed)
-- @param rating       Goodreads 1–5 (sent only when the target shelf is `read`)
-- @param shelf_name   exclusive shelf slug (required for custom exclusive shelves)
function GoodreadsApi:set_status(book_id, status, _unused, rating, shelf_name)
  return self:_get_backend():set_status(book_id, status, rating, shelf_name)
end

function GoodreadsApi:set_rating(book_id, rating)
  return self:_get_backend():set_rating(book_id, rating)
end

--- KOReader percent (0–100) → POST /user_status.json. Do not send page at the same time.
function GoodreadsApi:set_progress(book_id, percent)
  return self:_get_backend():set_progress(book_id, percent)
end

function GoodreadsApi:remove_status(book_id, current_status, current_shelf)
  return self:_get_backend():remove_status(book_id, current_status, current_shelf)
end

--- KOReader rating (1–5★) → Goodreads (1–5). No scale conversion.
function GoodreadsApi.koreaderToGoodreadsRating(koreader_rating)
  local n = tonumber(koreader_rating)
  if not n or n <= 0 then return 0 end
  n = math.floor(n + 0.5)
  if n < 1 then return 0 end
  if n > 5 then n = 5 end
  return n
end

return GoodreadsApi
