-- main.lua — goodreads.koplugin
-- KOReader plugin to sync reading status with goodreads.com.
--
-- Auth: browser session cookies (copy manually from DevTools).
-- No official API — uses observed HTML/JSON endpoints on www.goodreads.com.
--
-- Architecture:
--   main.lua              — WidgetContainer, init, KOReader events
--   goodreads_api.lua     — HTTP client facade
--   goodreads_parser.lua  — JSON/HTML/JS parsing
--   goodreads_settings.lua — settings and sidecar book links
--   goodreads_menu.lua    — menu UI

local DataStorage = require("datastorage")
local Dispatcher  = require("dispatcher")
local logger      = require("logger")
local _           = require("lib/goodreads_i18n").gettext
local T           = require("ffi/util").template

local Device      = require("device")
local NetworkMgr  = require("ui/network/manager")
local UIManager   = require("ui/uimanager")

local InfoMessage  = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Api                = require("goodreads_api")
local GoodreadsMenu      = require("goodreads_menu")
local GoodreadsSettings  = require("goodreads_settings")
local Identifiers        = require("goodreads_identifiers")

-- Minimum interval between automatic status sync requests (seconds)
local MIN_AUTO_SYNC_INTERVAL = 60

local CORE_SHELVES = {
  ["to-read"]           = true,
  ["currently-reading"] = true,
  ["read"]              = true,
}

local GoodreadsPlugin = WidgetContainer:extend {
  name         = "goodreads",
  is_doc_only  = false,
}

function GoodreadsPlugin:init()
  self.state = {
    current_status = nil,
    current_shelf = nil,
    last_auto_sync_at = 0,
    page = nil,
    autolink_pending = false,
    ensure_remote_pending = false,
    last_error_at = 0,
    last_error = nil,
    network_retry_scheduled = false,
    network_retry_done = false,
  }

  local settings_path = ("%s/%s"):format(
    DataStorage:getSettingsDir(), "goodreads_settings.lua"
  )
  self.settings = GoodreadsSettings:new(settings_path, self.ui)

  Api.settings = self.settings
  Api.on_error = function(err)
    self:_handleApiError(err)
  end

  self.menu = GoodreadsMenu:new {
    settings = self.settings,
    state    = self.state,
    ui       = self.ui,
    plugin   = self,
  }

  self:onDispatcherRegisterActions()
  self.ui.menu:registerToMainMenu(self)

  logger.info("Goodreads: plugin initialized")
end

function GoodreadsPlugin:_handleApiError(err)
  local now = os.time()
  if err == self.state.last_error and now - (self.state.last_error_at or 0) < 120 then
    return
  end
  self.state.last_error = err
  self.state.last_error_at = now

  if err == "session_expired" then
    UIManager:show(InfoMessage:new {
      text = _([[Goodreads: session expired.

Update cookies in Goodreads → Settings → Session cookies,
or in goodreads_config.lua (DevTools → Application → Cookies → goodreads.com).

You do not need to restart KOReader — changes apply immediately.]]),
      icon = "notice-warning",
    })
    return
  end

  -- Transient: Wi-Fi radio up but no IP yet (Kobo resume). Don't block the screen.
  if err == _("No network connection") then
    UIManager:show(Notification:new {
      text = T(_("Goodreads: %1"), tostring(err)),
      timeout = 3,
    })
    return
  end

  if err and err ~= "" then
    UIManager:show(InfoMessage:new {
      text = T(_("Goodreads: %1"), tostring(err)),
      icon = "notice-warning",
    })
  end
end

function GoodreadsPlugin:_quietly(fn)
  local prev = Api.quiet
  Api.quiet = true
  local ok, err = pcall(fn)
  Api.quiet = prev
  if not ok then error(err) end
end

function GoodreadsPlugin:onDispatcherRegisterActions()
  Dispatcher:registerAction("goodreads_link", {
    category = "none",
    event    = "GoodreadsLink",
    title    = _("Goodreads: Link book"),
    general  = true,
  })

  Dispatcher:registerAction("goodreads_set_reading", {
    category = "none",
    event    = "GoodreadsSetReading",
    title    = _("Goodreads: Status — Currently reading"),
    general  = true,
  })

  Dispatcher:registerAction("goodreads_set_read", {
    category = "none",
    event    = "GoodreadsSetRead",
    title    = _("Goodreads: Status — Finished"),
    general  = true,
  })

  Dispatcher:registerAction("goodreads_track", {
    category = "none",
    event    = "GoodreadsTrack",
    title    = _("Goodreads: Enable auto-tracking"),
    general  = true,
  })

  Dispatcher:registerAction("goodreads_stop_track", {
    category = "none",
    event    = "GoodreadsStopTrack",
    title    = _("Goodreads: Disable auto-tracking"),
    general  = true,
  })

  Dispatcher:registerAction("goodreads_sync_rating", {
    category = "none",
    event    = "GoodreadsSyncRating",
    title    = _("Goodreads: Send rating"),
    general  = true,
  })

  Dispatcher:registerAction("goodreads_sync_progress", {
    category = "none",
    event    = "GoodreadsSyncProgress",
    title    = _("Goodreads: Update progress"),
    general  = true,
  })
end

function GoodreadsPlugin:onGoodreadsLink()
  if not self.ui.document then
    UIManager:show(InfoMessage:new { text = _("Goodreads: open a book to link it") })
    return
  end
  self:_withWifi(function()
    self.menu:showLinkBookDialog(false)
  end)
end

function GoodreadsPlugin:onGoodreadsSetReading()
  self:_quickSetStatus(2)
end

function GoodreadsPlugin:onGoodreadsSetRead()
  self:_quickSetStatus(1)
end

function GoodreadsPlugin:onGoodreadsTrack()
  if not self.ui.document then return end
  if not self.settings:bookLinked() then
    UIManager:show(InfoMessage:new {
      text = _("Goodreads: link a book first"),
    })
    return
  end
  self.settings:setSync(true)
  UIManager:show(Notification:new {
    text = _("Goodreads: auto-tracking enabled"),
    timeout = 2,
  })
end

function GoodreadsPlugin:onGoodreadsStopTrack()
  if not self.ui.document then return end
  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Goodreads: auto-tracking disabled"),
    timeout = 2,
  })
end

function GoodreadsPlugin:onGoodreadsSyncRating()
  if not self.ui.document or not self.settings:bookLinked() then
    UIManager:show(InfoMessage:new {
      text = _("Goodreads: link a book and open it"),
    })
    return
  end
  self:_withWifi(function()
    self:syncRatingNow(true)
  end)
end

function GoodreadsPlugin:onGoodreadsSyncProgress()
  if not self.ui.document or not self.settings:bookLinked() then
    UIManager:show(InfoMessage:new {
      text = _("Goodreads: link a book and open it"),
    })
    return
  end
  self:_withWifi(function()
    self:syncProgressNow(true)
  end)
end

function GoodreadsPlugin:_resolveRating(filename, status_code)
  if not self.settings:syncRatingEnabled() then
    return 0
  end
  if status_code ~= nil and status_code ~= 1 then
    return 0
  end
  local kr = self.settings:getKoreaderRating(filename)
  return Api.koreaderToGoodreadsRating(kr)
end

--- Set status without a dialog (Dispatcher / auto-tracking).
-- @param status_code  status code
-- @param opts         { silent=bool, force=bool, ensure=bool, filename=string }
function GoodreadsPlugin:_quickSetStatus(status_code, opts)
  opts = opts or {}
  local file = opts.filename or (self.ui.document and self.ui.document.file)
  if not file then return end

  if not self.settings:readBookSetting(file, "edition_id") then
    if not opts.silent then
      UIManager:show(InfoMessage:new {
        text = _("Goodreads: link a book first via Goodreads → Link book")
      })
    end
    return
  end

  local current = self.settings:readBookSetting(file, "status")
  if not opts.force and not opts.ensure and current == status_code then
    if status_code == 1 and self.settings:syncRatingEnabled() then
      local new_rating = self:_resolveRating(file, 1)
      local old_rating = tonumber(self.settings:readBookSetting(file, "rating")) or 0
      if new_rating == old_rating then
        return
      end
    else
      return
    end
  end

  self:_withWifi(function()
    local edition_id = self.settings:readBookSetting(file, "edition_id")
    local rating     = self:_resolveRating(file, status_code)

    local result
    local function do_set()
      result = Api:set_status(edition_id, status_code, nil, rating)
    end
    if opts.silent then
      self:_quietly(do_set)
    else
      do_set()
    end
    if result and result.ok then
      local update = { status = status_code, shelf = Api:shelfForStatus(status_code) }
      if status_code == 1 then
        update.rating = result.rating or 0
      end
      if result.date_read then
        update.date_read = result.date_read
      end
      self.settings:updateBookSetting(file, update)
      if self.ui.document and self.ui.document.file == file then
        self.state.current_status = status_code
        self.state.current_shelf = update.shelf
      end
      self.state.last_auto_sync_at = os.time()
      self.state.ensure_remote_pending = false
      if status_code == 2 then
        self:_sendProgress(file, { force = true })
      end
      if not opts.silent then
        UIManager:show(Notification:new {
          text = T(_("Goodreads: %1"), Api:statusText(status_code)),
          timeout = 3,
        })
      end
    end
  end, opts.silent)
end

function GoodreadsPlugin:syncRatingNow(show_feedback)
  local file = self.ui.document and self.ui.document.file
  if not file then return false end

  local kr = self.settings:getKoreaderRating(file)
  if not kr or kr <= 0 then
    if show_feedback then
      UIManager:show(InfoMessage:new {
        text = _([[Goodreads: no rating in KOReader Book Status (★).
Set stars and try again.]]),
      })
    end
    return false
  end

  local edition_id = self.settings:getLinkedEditionId()
  local rating     = Api.koreaderToGoodreadsRating(kr)

  local result = Api:set_rating(edition_id, rating)
  if result and result.ok then
    self.settings:updateBookSetting(file, { rating = result.rating or rating })
    if show_feedback then
      UIManager:show(Notification:new {
        text = T(_("Goodreads: rating %1★ sent"), tostring(kr)),
        timeout = 3,
      })
    end
    return true
  end
  return false
end

function GoodreadsPlugin:_withWifi(callback, silent)
  if NetworkMgr:isConnected() then
    callback()
    return
  end

  local function when_connected()
    callback()
  end

  -- Radio already up (typical Kobo resume) or we can restore it — wait for IP,
  -- do not fire the request while DHCP is still running.
  if NetworkMgr:isWifiOn() then
    if NetworkMgr.scheduleConnectivityCheck then
      NetworkMgr:scheduleConnectivityCheck(when_connected)
    else
      UIManager:scheduleIn(4, function()
        if NetworkMgr:isConnected() then when_connected() end
      end)
    end
    return
  end

  if self.settings:enableWifiOnDemand()
      and Device:hasWifiRestore()
      and G_reader_settings:nilOrFalse("airplanemode") then
    local original_on = NetworkMgr.wifi_was_on
    NetworkMgr:restoreWifiAsync()
    NetworkMgr:scheduleConnectivityCheck(function()
      NetworkMgr.wifi_was_on = original_on
      G_reader_settings:saveSetting("wifi_was_on", original_on)
      when_connected()
    end)
    return
  end

  if silent then
    return
  end

  NetworkMgr:promptWifiOn(function()
    when_connected()
  end)
end

function GoodreadsPlugin:_canAutoSync(filename, opts)
  opts = opts or {}
  if not filename then return false end
  if not self.settings:readBookSetting(filename, "edition_id") then
    logger.dbg("Goodreads: auto-track skip — book not linked")
    return false
  end
  if not self.settings:fileSyncEnabled(filename) then
    logger.dbg("Goodreads: auto-track skip — auto-tracking off")
    return false
  end
  if opts.ensure then return true end
  local now = os.time()
  if now - (self.state.last_auto_sync_at or 0) < MIN_AUTO_SYNC_INTERVAL then
    logger.dbg("Goodreads: auto-track skip — throttle")
    return false
  end
  return true
end

function GoodreadsPlugin:_readingPercent()
  if not self.ui.document then return nil end
  local percent = nil
  if self.ui.doc_settings then
    percent = tonumber(self.ui.doc_settings:readSetting("percent_finished"))
  end
  if not percent and self.ui.document.getPageCount and self.state.page then
    local total = self.ui.document:getPageCount()
    if total and total > 0 then
      percent = self.state.page / total
    end
  end
  return percent
end

function GoodreadsPlugin:_progressPct()
  local percent = self:_readingPercent()
  if not percent then return nil end
  return math.floor(percent * 100 + 0.5)
end

function GoodreadsPlugin:_progressBlockedByStatus(file)
  if not file then return true end
  local shelf = self.settings:readBookSetting(file, "shelf")
  local current = self.settings:readBookSetting(file, "status")
  -- Exclusive `shelf` wins: a leftover numeric status from a custom-shelf
  -- switch must not look like Finished/DNF.
  if type(shelf) == "string" and shelf ~= "" then
    return shelf == "read" or shelf == "did-not-finish"
  end
  return current == 1 or current == 3 or current == -2
end

--- Manual "Update progress" is enabled when a percent can actually be posted.
function GoodreadsPlugin:canSyncProgressNow()
  local file = self.ui.document and self.ui.document.file
  if not file or not self.settings:bookLinked() then return false end
  if self:_progressBlockedByStatus(file) then return false end
  local pct = self:_progressPct()
  return pct ~= nil and pct >= 1 and pct < 99.5
end

--- Explicit progress push (menu / gesture). Independent of auto-track and of
-- Settings → Sync reading progress (that toggle is only for automatic posts).
-- Want to read / no shelf → Currently reading first. Custom exclusives (Paused)
-- keep their shelf. Finished / DNF / ~100% are refused.
function GoodreadsPlugin:syncProgressNow(show_feedback)
  local file = self.ui.document and self.ui.document.file
  if not file or not self.settings:bookLinked() then
    if show_feedback then
      UIManager:show(InfoMessage:new {
        text = _("Goodreads: link a book and open it"),
      })
    end
    return false
  end

  if self:_progressBlockedByStatus(file) then
    if show_feedback then
      UIManager:show(InfoMessage:new {
        text = _("Goodreads: progress updates are for books you are reading. Use Change status if this book is Finished or DNF."),
      })
    end
    return false
  end

  local pct = self:_progressPct()
  if not pct or pct < 1 then
    if show_feedback then
      UIManager:show(InfoMessage:new {
        text = _("Goodreads: not enough reading progress yet"),
      })
    end
    return false
  end
  if pct >= 99.5 then
    if show_feedback then
      UIManager:show(InfoMessage:new {
        text = _("Goodreads: book is almost finished. Use Change status → Finished."),
      })
    end
    return false
  end

  local current = self.settings:readBookSetting(file, "status")
  local shelf = self.settings:readBookSetting(file, "shelf")
  local is_reading = current == 2 or shelf == "currently-reading"
  local is_custom = type(shelf) == "string" and shelf ~= "" and not CORE_SHELVES[shelf]
  if not is_reading and not is_custom then
    local edition_id = self.settings:getLinkedEditionId()
    local status_result = Api:set_status(edition_id, 2, nil, 0)
    if not status_result or not status_result.ok then
      return false
    end
    local reading_shelf = Api:shelfForStatus(2) or "currently-reading"
    self.settings:updateBookSetting(file, { status = 2, shelf = reading_shelf })
    self.state.current_status = 2
    self.state.current_shelf = reading_shelf
    self.state.ensure_remote_pending = false
  end

  local result = self:_sendProgress(file, { manual = true, force = true })
  if result and result.ok then
    if show_feedback then
      UIManager:show(Notification:new {
        text = T(_("Goodreads: progress %1% sent"), tostring(result.percent or pct)),
        timeout = 3,
      })
    end
    return true
  end
  return false
end

function GoodreadsPlugin:_sendProgress(file, opts)
  opts = opts or {}
  if not file then return nil end
  if not opts.manual then
    if not self.settings:syncProgressEnabled() then return nil end
    if not self.settings:fileSyncEnabled(file) then return nil end
  end
  local edition_id = self.settings:readBookSetting(file, "edition_id")
  if not edition_id then return nil end
  if self:_progressBlockedByStatus(file) then return nil end

  local pct = self:_progressPct()
  if not pct or pct < 1 or pct >= 99.5 then return nil end

  local last = tonumber(self.settings:readBookSetting(file, "last_progress"))
  if not opts.force and last and math.abs(last - pct) < 1 then
    return nil
  end
  if not opts.force then
    local now = os.time()
    if now - (self.state.last_auto_sync_at or 0) < MIN_AUTO_SYNC_INTERVAL then
      return nil
    end
  end

  local result = Api:set_progress(edition_id, pct)
  if result and result.ok then
    self.settings:updateBookSetting(file, { last_progress = result.percent or pct })
    self.state.last_auto_sync_at = os.time()
    return result
  end
  return nil
end

--- Start reading → Currently reading; ~100% → Finished.
-- Also POST percent to /user_status.json while Currently reading (optional).
-- @param opts { ensure=bool }  re-push status even if sidecar already matches
function GoodreadsPlugin:_maybeAutoTrackProgress(opts)
  opts = opts or {}
  if not self.ui.document then return end
  local file = self.ui.document.file
  if not self:_canAutoSync(file, opts) then return end

  local current = self.settings:readBookSetting(file, "status")
  local shelf   = self.settings:readBookSetting(file, "shelf")
  if current == 1 or current == 3 or shelf == "read" then
    logger.dbg("Goodreads: auto-track skip — finished/DNF locally")
    return
  end
  if type(shelf) == "string" and shelf ~= "" and not CORE_SHELVES[shelf] then
    logger.dbg("Goodreads: auto-track skip — custom exclusive shelf " .. shelf)
    return
  end

  local percent = self:_readingPercent()
  local pct = percent and (percent * 100) or 0
  local silent_opts = { silent = true, filename = file, ensure = opts.ensure }
  if percent and pct >= 99.5 then
    logger.info("Goodreads: auto-track Finished (" .. string.format("%.1f", pct) .. "%)")
    self:_quickSetStatus(1, silent_opts)
  else
    -- Currently reading as soon as you start (link / first pages). Do not wait
    -- for 1%: front matter is often still 0.x%
    if current ~= 2 or opts.ensure then
      logger.info("Goodreads: auto-track Currently reading (" .. string.format("%.1f", pct) .. "%)")
      self:_quickSetStatus(2, silent_opts)
    else
      self:_withWifi(function()
        self:_sendProgress(file)
      end, true)
    end
  end
end

function GoodreadsPlugin:onPageUpdate(page)
  self.state.page = page
  self:_maybeAutoTrackProgress()
end

function GoodreadsPlugin:onPosUpdate(_, page)
  if page then
    self:onPageUpdate(page)
  end
end

function GoodreadsPlugin:onEndOfBook()
  local file = self.ui.document and self.ui.document.file
  if not file or not self.settings:fileSyncEnabled(file) then return end
  if not self.settings:readBookSetting(file, "edition_id") then return end

  local mark_read = false
  if G_reader_settings:isTrue("end_document_auto_mark") then
    mark_read = true
  end
  if not mark_read then
    local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
    mark_read = action == "mark_read"
    if action == "pop-up" then
      mark_read = "later"
    end
  end
  if not mark_read then return end

  local do_mark = function()
    self:_quickSetStatus(1, { silent = false, force = true, filename = file })
  end

  if mark_read == "later" then
    UIManager:scheduleIn(30, function()
      local status = self.settings:getKoreaderStatus(file)
      if status == "complete" then
        do_mark()
      end
    end)
  else
    do_mark()
  end
end

--- Sync when KOReader Book Status changes (reading/complete/abandoned).
function GoodreadsPlugin:onDocSettingsItemsChanged(file, doc_settings)
  if not file or not doc_settings or not doc_settings.summary then return end
  if not self.settings:fileSyncEnabled(file) then return end
  if not self.settings:readBookSetting(file, "edition_id") then return end

  local kr_status = doc_settings.summary.status
  local status_code
  if kr_status == "complete" then
    status_code = 1
  elseif kr_status == "reading" then
    status_code = 2
  elseif kr_status == "abandoned" then
    if self.settings:hasExclusiveShelf("did-not-finish") then
      status_code = 3
    end
  end
  if not status_code then return end

  self:_quickSetStatus(status_code, { silent = false, force = true, filename = file })
end

function GoodreadsPlugin:_scheduleNetworkRetry()
  if self.state.network_retry_scheduled or self.state.network_retry_done then
    return
  end
  self.state.network_retry_scheduled = true
  UIManager:scheduleIn(5, function()
    self.state.network_retry_scheduled = false
    self.state.network_retry_done = true
    if not self.ui.document then return end
    if not NetworkMgr:isConnected() then return end
    if self.state.autolink_pending then
      self:_tryAutolinkByGoodreadsId()
    elseif self.state.ensure_remote_pending then
      self:_runPendingEnsure()
    elseif self.settings:bookLinked() then
      self:_refreshRemoteState()
    end
  end)
end

function GoodreadsPlugin:_runPendingEnsure()
  if not self.state.ensure_remote_pending then return end
  if not self.ui.document then return end
  if not self.settings:syncEnabled() then
    self.state.ensure_remote_pending = false
    return
  end
  if not NetworkMgr:isConnected() then
    logger.info("Goodreads: auto-track wait — no network yet")
    self:_scheduleNetworkRetry()
    return
  end
  self.state.ensure_remote_pending = false
  self:_quietly(function()
    self:_maybeAutoTrackProgress({ ensure = true })
  end)
end

function GoodreadsPlugin:_tryAutolinkByGoodreadsId()
  if not self.state.autolink_pending then return end
  if not self.ui.document then return end
  if self.settings:bookLinked() then
    self.state.autolink_pending = false
    return
  end
  local want_id = self.settings:autoLinkByGoodreadsId()
  local want_isbn = self.settings:autoLinkByIsbn()
  if not want_id and not want_isbn then
    self.state.autolink_pending = false
    return
  end

  if not NetworkMgr:isConnected() then
    logger.info("Goodreads: autolink wait — no network yet")
    self:_scheduleNetworkRetry()
    return
  end

  local gr_id = want_id and Identifiers.getGoodreadsId(self.ui) or nil
  local isbn = (not gr_id and want_isbn) and Identifiers.getIsbn(self.ui) or nil
  if not gr_id and not isbn then
    self.state.autolink_pending = false
    return
  end

  self.state.autolink_pending = false
  if gr_id then
    logger.info("Goodreads: autolink by id " .. gr_id)
    self.menu:linkByGoodreadsId(gr_id)
  else
    logger.info("Goodreads: autolink by ISBN " .. isbn)
    self.menu:linkByIsbn(isbn, nil, { autolink = true })
  end
end

function GoodreadsPlugin:_refreshRemoteState()
  if not self.ui.document then return end
  if not self.settings:bookLinked() then return end
  if not NetworkMgr:isConnected() then
    self:_scheduleNetworkRetry()
    return
  end
  local edition_id = self.settings:getLinkedEditionId()
  local state
  self:_quietly(function()
    state = Api:get_review_state(edition_id)
  end)
  if not state or not state.ok then
    self:_scheduleNetworkRetry()
    return
  end
  local file = self.ui.document.file
  local update = {
    status    = state.status ~= nil and state.status or GoodreadsSettings.UNSET,
    shelf     = state.shelf or GoodreadsSettings.UNSET,
  }
  if state.review_id then
    update.review_id = state.review_id
  elseif not state.shelf then
    update.review_id = GoodreadsSettings.UNSET
  end
  if state.rating and state.rating > 0 then
    update.rating = state.rating
  end
  self.settings:updateBookSetting(file, update)
  self.state.current_status = state.status
  self.state.current_shelf = state.shelf
  logger.info("Goodreads: remote shelf=" .. tostring(state.shelf)
    .. " status=" .. tostring(state.status))
end

function GoodreadsPlugin:onReaderReady()
  if not self.ui.document then return end

  local cached_status = self.settings:getLinkedStatus()
  self.state.current_status = cached_status
  self.state.current_shelf = self.settings:getLinkedShelf()
      or Api:shelfForStatus(cached_status)
  self.state.page = self.ui:getCurrentPage()
  self.state.autolink_pending = not self.settings:bookLinked()
      and (self.settings:autoLinkByGoodreadsId() or self.settings:autoLinkByIsbn())
  self.state.ensure_remote_pending = self.settings:bookLinked()
      and self.settings:syncEnabled()

  if cached_status ~= nil then
    logger.info("Goodreads: restored cached status=" .. tostring(cached_status)
      .. " for " .. self.ui.document.file)
  end

  if self.state.autolink_pending then
    UIManager:scheduleIn(2, function()
      self:_tryAutolinkByGoodreadsId()
    end)
  elseif self.state.ensure_remote_pending then
    UIManager:scheduleIn(2, function()
      self:_runPendingEnsure()
    end)
  elseif self.settings:bookLinked() then
    UIManager:scheduleIn(2, function()
      self:_refreshRemoteState()
    end)
  end
end

function GoodreadsPlugin:onNetworkConnected()
  self.state.network_retry_done = false
  self:_quietly(function()
    self:_tryAutolinkByGoodreadsId()
    if self.state.ensure_remote_pending then
      self:_runPendingEnsure()
    else
      self:_refreshRemoteState()
    end
  end)
end

function GoodreadsPlugin:onDocumentClose()
  self.state.current_status = nil
  self.state.current_shelf = nil
  self.state.page = nil
  self.state.autolink_pending = false
  self.state.ensure_remote_pending = false
  self.state.network_retry_scheduled = false
  self.state.network_retry_done = false
end

function GoodreadsPlugin:addToMainMenu(menu_items)
  menu_items["goodreads"] = self.menu:mainMenu()
end

return GoodreadsPlugin
