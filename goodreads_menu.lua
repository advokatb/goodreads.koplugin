-- goodreads_menu.lua
-- Plugin menu for KOReader.
-- Registered via self.ui.menu:registerToMainMenu(self) in main.lua.

local _ = require("lib/goodreads_i18n").gettext
local T = require("ffi/util").template
local logger = require("logger")

local UIManager     = require("ui/uimanager")
local InfoMessage   = require("ui/widget/infomessage")
local Font          = require("ui/font")
local InputDialog   = require("ui/widget/inputdialog")
local Menu          = require("ui/widget/menu")
local Notification  = require("ui/widget/notification")
local ConfirmBox    = require("ui/widget/confirmbox")

local Api           = require("goodreads_api")
local Identifiers   = require("goodreads_identifiers")
local GoodreadsSettings = require("goodreads_settings")

local function loadPluginMeta()
  local src = debug.getinfo(1, "S").source:match("@(.*)$") or ""
  src = src:gsub("\\", "/")
  local plugin_dir = src:match("^(.*)/[^/]+%.lua$")
  if not plugin_dir then return nil end
  local ok, meta = pcall(dofile, plugin_dir .. "/_meta.lua")
  if ok and type(meta) == "table" then return meta end
  return nil
end

-- Radio items come from Api:statusMenuItems() (account exclusive shelves).

local GoodreadsMenu = {}
GoodreadsMenu.__index = GoodreadsMenu

function GoodreadsMenu:new(o)
  return setmetatable(o or {}, self)
end

local function show_error(text)
  UIManager:show(InfoMessage:new {
    text = text,
    icon = "notice-warning",
  })
end

local function show_notification(text)
  UIManager:show(Notification:new {
    text = text,
    timeout = 3,
  })
end

function GoodreadsMenu:maybeConfirm(text, callback)
  if self.settings:menuConfirm() then
    UIManager:show(ConfirmBox:new {
      text = text,
      ok_text = _("Yes"),
      ok_callback = callback,
    })
  else
    callback()
  end
end

function GoodreadsMenu:_linkBook(book_data, done_callback)
  local file = self.ui.document and self.ui.document.file
  if not file then return end

  self.settings:updateBookSetting(file, {
    edition_id    = book_data.edition_id,
    book_id       = book_data.book_id,
    review_id     = book_data.review_id,
    title         = book_data.title,
    authors       = book_data.authors,
    goodreads_url = book_data.goodreads_url,
    pages         = book_data.pages,
    status        = nil,
  })

  local state = Api:get_review_state(book_data.edition_id)
  if state and state.ok then
    self.settings:updateBookSetting(file, {
      status    = state.status ~= nil and state.status or GoodreadsSettings.UNSET,
      shelf     = state.shelf or GoodreadsSettings.UNSET,
      review_id = state.review_id or book_data.review_id,
      rating    = (state.rating and state.rating > 0) and state.rating or nil,
    })
    if self.state then
      self.state.current_status = state.status
      self.state.current_shelf = state.shelf
    end
  end

  logger.info("Goodreads: linked book id=" .. tostring(book_data.edition_id)
    .. " title=" .. tostring(book_data.title))

  show_notification(T(_("Book linked: %1"), book_data.title))

  if done_callback then
    done_callback(book_data)
  end
end

function GoodreadsMenu:linkByGoodreadsId(book_id, done_callback)
  local loading = InfoMessage:new { text = _("Linking by Goodreads id…") }
  UIManager:show(loading)

  UIManager:scheduleIn(0.1, function()
    local book = Api:get_book(book_id)
    UIManager:close(loading)
    if not book then
      return
    end
    self:_linkBook(book, done_callback)
  end)
end

function GoodreadsMenu:linkByIsbn(isbn, done_callback, opts)
  opts = opts or {}
  local loading = InfoMessage:new { text = _("Linking by ISBN…") }
  UIManager:show(loading)

  UIManager:scheduleIn(0.1, function()
    local books = Api:search(isbn)
    UIManager:close(loading)
    if not books or #books == 0 then
      return
    end
    if #books == 1 or opts.autolink then
      self:_linkBook(books[1], done_callback)
      return
    end
    self:_showSearchResults(isbn, books, done_callback)
  end)
end

function GoodreadsMenu:showLinkBookDialog(force_search, done_callback)
  if not force_search then
    local gr_id = Identifiers.getGoodreadsId(self.ui)
    if gr_id then
      self:linkByGoodreadsId(gr_id, done_callback)
      return
    end
    local isbn = Identifiers.getIsbn(self.ui)
    if isbn then
      self:linkByIsbn(isbn, done_callback)
      return
    end
  end

  local props = self.ui.document and self.ui.document:getProps() or {}
  local auto_query = ""
  if props.title and props.title ~= "" then
    auto_query = props.title
    if props.authors and props.authors ~= "" then
      auto_query = auto_query .. " " .. props.authors
    end
  end

  if force_search or auto_query == "" then
    self:_showSearchInput(auto_query, done_callback)
  else
    self:_doSearch(auto_query, done_callback)
  end
end

function GoodreadsMenu:_showSearchInput(initial_query, done_callback)
  local search_dialog
  search_dialog = InputDialog:new {
    title = _("Search book on Goodreads"),
    input = initial_query,
    save_button_text = _("Search"),
    buttons = { {
      {
        text = _("Cancel"),
        callback = function()
          UIManager:close(search_dialog)
        end,
      },
      {
        text = _("Search"),
        is_enter_default = true,
        callback = function()
          local query = search_dialog:getInputText()
          UIManager:close(search_dialog)
          if query and query ~= "" then
            self:_doSearch(query, done_callback)
          end
        end,
      },
    } },
  }
  UIManager:show(search_dialog)
  search_dialog:onShowKeyboard()
end

function GoodreadsMenu:_doSearch(query, done_callback)
  local loading = InfoMessage:new { text = _("Searching on Goodreads…") }
  UIManager:show(loading)

  UIManager:scheduleIn(0.1, function()
    local books = Api:search(query)
    UIManager:close(loading)

    if not books then
      return
    end

    if #books == 0 then
      UIManager:show(ConfirmBox:new {
        text = T(_("Nothing found for \"%1\".\nTry another query?"), query),
        ok_text = _("New query"),
        ok_callback = function()
          self:_showSearchInput(query, done_callback)
        end,
      })
      return
    end

    self:_showSearchResults(query, books, done_callback)
  end)
end

function GoodreadsMenu:_showSearchResults(query, books, done_callback)
  local menu_items = {}
  for _, book in ipairs(books) do
    local display = book.title
    if book.authors and book.authors ~= "" then
      display = display .. "\n" .. book.authors
    end
    if book.rating and book.rating ~= "" then
      display = display .. " [" .. book.rating .. "]"
    end
    table.insert(menu_items, {
      text      = display,
      book_data = book,
    })
  end

  table.insert(menu_items, {
    text = _("↩ New search"),
    is_search = true,
  })

  local results_menu
  results_menu = Menu:new {
    title      = _("Search results"),
    item_table = menu_items,
    fullscreen = true,
    onMenuSelect = function(_, item)
      if item.is_search then
        UIManager:close(results_menu)
        self:_showSearchInput(query, done_callback)
        return
      end
      UIManager:close(results_menu)
      self:_linkBook(item.book_data, done_callback)
    end,
  }
  UIManager:show(results_menu)
end

function GoodreadsMenu:_doSetStatus(item, menu_instance)
  local file = self.ui.document and self.ui.document.file
  if not file then return end

  local edition_id = self.settings:getLinkedEditionId()
  if not edition_id then
    show_error(_("Book is not linked to Goodreads"))
    return
  end

  local status_code = item.code
  local shelf = item.shelf
  local rating = 0
  if (status_code == 1 or shelf == "read") and self.settings:syncRatingEnabled() then
    rating = Api.koreaderToGoodreadsRating(self.settings:getKoreaderRating(file))
  end

  local loading = InfoMessage:new { text = _("Updating status on Goodreads…") }
  UIManager:show(loading)

  UIManager:scheduleIn(0.1, function()
    local result
    if status_code == -2 then
      result = Api:remove_status(
        edition_id,
        self.settings:getLinkedStatus(),
        self.settings:getLinkedShelf()
      )
    else
      result = Api:set_status(edition_id, status_code, nil, rating, shelf)
    end
    UIManager:close(loading)

    if not result or not result.ok then
      return
    end

    local update = {
      status = status_code,
      shelf  = shelf,
    }
    if status_code == -2 then
      update.rating = GoodreadsSettings.UNSET
      update.shelf = GoodreadsSettings.UNSET
      update.date_read = GoodreadsSettings.UNSET
      update.review_id = GoodreadsSettings.UNSET
    elseif status_code == 1 or shelf == "read" then
      update.rating = result.rating or 0
      if result.date_read then
        update.date_read = result.date_read
      end
    end
    self.settings:updateBookSetting(file, update)

    if self.state then
      self.state.current_status = status_code
      self.state.current_shelf = (status_code == -2) and nil or shelf
      self.state.ensure_remote_pending = false
    end

    if (status_code == 2 or shelf == "currently-reading") and self.plugin then
      self.plugin:_sendProgress(file, { force = true })
    end

    local saved_rating = tonumber(result.rating) or 0
    local status_text
    if status_code == -2 then
      status_text = Api:statusText(-2)
    else
      status_text = Api:shelfLabel(shelf) or Api:statusText(status_code)
    end
    if (status_code == 1 or shelf == "read") and saved_rating > 0 then
      status_text = status_text .. " (" .. tostring(saved_rating) .. "★)"
    end
    show_notification(T(_("Goodreads: %1"), status_text))

    if menu_instance and menu_instance.updateItems then
      menu_instance.item_table = self:getStatusSubMenuItems()
      menu_instance:updateItems()
    end
  end)
end

function GoodreadsMenu:getStatusSubMenuItems()
  local current_status = self.state and self.state.current_status
  local current_shelf = self.state and self.state.current_shelf

  if current_status == nil then
    current_status = self.settings:getLinkedStatus()
  end
  if current_status == -2 then
    current_shelf = nil
  elseif current_shelf == nil or current_shelf == "" then
    current_shelf = self.settings:getLinkedShelf()
  end
  if (current_shelf == nil or current_shelf == "") and current_status
      and current_status ~= -2 then
    current_shelf = Api:shelfForStatus(current_status)
  end

  local items = {}
  for _i, item in ipairs(Api:statusMenuItems()) do
    local code  = item.code
    local label = item.label_key and _(item.label_key) or item.label or item.shelf
    table.insert(items, {
      text = label,
      radio = true,
      checked_func = function()
        if current_status == -2 then
          return code == -2
        end
        if code == -2 then
          return not current_shelf
        end
        if item.shelf and current_shelf then
          return current_shelf == item.shelf
        end
        return current_status == code
      end,
      callback = function(menu_instance)
        self:maybeConfirm(
          T(_("Set status \"%1\"?"), label),
          function()
            self:_doSetStatus(item, menu_instance)
          end
        )
      end,
      keep_menu_open = true,
    })
  end

  return items
end

function GoodreadsMenu:getSettingsSubMenuItems()
  return {
    {
      text = _("Session cookies…"),
      keep_menu_open = true,
      callback = function()
        self:_showCookieInput()
      end,
    },
    {
      text = _("Autolink by GOODREADS identifier"),
      checked_func = function()
        return self.settings:autoLinkByGoodreadsId()
      end,
      callback = function()
        self.settings:setAutoLinkByGoodreadsId(not self.settings:autoLinkByGoodreadsId())
      end,
      keep_menu_open = true,
      help_text = _("When a book contains a GOODREADS identifier in its metadata, link it automatically on open (on by default)."),
    },
    {
      text = _("Autolink by ISBN"),
      checked_func = function()
        return self.settings:autoLinkByIsbn()
      end,
      callback = function()
        self.settings:setAutoLinkByIsbn(not self.settings:autoLinkByIsbn())
      end,
      keep_menu_open = true,
      help_text = _("If there is no GOODREADS id, search Goodreads by ISBN and link the first match (on by default). Does not search by title."),
    },
    {
      text = _("Auto-tracking for new books"),
      checked_func = function()
        return self.settings:alwaysSync()
      end,
      callback = function()
        self.settings:setAlwaysSync(not self.settings:alwaysSync())
      end,
      keep_menu_open = true,
      help_text = _("When enabled, auto-tracking is on for linked books without an explicit per-book toggle."),
    },
    {
      text = _("Sync rating (★)"),
      checked_func = function()
        return self.settings:syncRatingEnabled()
      end,
      callback = function()
        self.settings:setSyncRatingEnabled(not self.settings:syncRatingEnabled())
      end,
      keep_menu_open = true,
      help_text = _("When marking Finished, send the KOReader Book Status rating (1–5★)."),
    },
    {
      text = _("Sync reading progress"),
      checked_func = function()
        return self.settings:syncProgressEnabled()
      end,
      callback = function()
        self.settings:setSyncProgressEnabled(not self.settings:syncProgressEnabled())
      end,
      keep_menu_open = true,
      help_text = _("While auto-tracking Currently reading, post percent to Goodreads (at most once a minute). Shows up as a status update. Off if you do not want feed noise."),
    },
    {
      text = _("Enable Wi-Fi on demand"),
      checked_func = function()
        return self.settings:enableWifiOnDemand()
      end,
      callback = function()
        self.settings:setEnableWifiOnDemand(not self.settings:enableWifiOnDemand())
      end,
      keep_menu_open = true,
    },
    {
      text = _("Confirm status changes"),
      checked_func = function()
        return self.settings:menuConfirm()
      end,
      callback = function()
        self.settings:setMenuConfirm(not self.settings:menuConfirm())
      end,
      keep_menu_open = true,
    },
  }
end

function GoodreadsMenu:_showCookieInput()
  local current = self.settings:getCookie()
  local dialog
  dialog = InputDialog:new {
    title = _("goodreads.com session cookies"),
    description = _([[Paste the Cookie request header from a logged-in goodreads.com tab:
DevTools (F12) → Network → reload → any www.goodreads.com request → Request Headers → Cookie.

Need both the Rails session (_session_id2) and Amazon SSO cookies (at-main, session-token, …). Copying the whole header is easiest. jwt_token is stripped automatically (it expires in minutes and breaks requests if stale).]]),
    input = current,
    input_type = "text",
    save_button_text = _("Save"),
    buttons = { {
      {
        text = _("Cancel"),
        callback = function()
          UIManager:close(dialog)
        end,
      },
      {
        text = _("Save"),
        is_enter_default = false,
        callback = function()
          local value = dialog:getInputText()
          UIManager:close(dialog)
          if value and value ~= "" then
            self.settings:setCookie(value)
            local backend = Api:_get_backend()
            if backend.reset_csrf_token then
              backend:reset_csrf_token()
            end
            if self.settings.clearSessionCache then
              self.settings:clearSessionCache()
            end
            show_notification(_("Cookies saved"))
          end
        end,
      },
    } },
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

function GoodreadsMenu:getSubMenuItems()
  local has_book = self.ui and self.ui.document ~= nil
  local items = {}

  if has_book then
    table.insert(items, {
      text_func = function()
        if self.settings:bookLinked() then
          local title = self.settings:getLinkedTitle()
          return T(_("Book: %1"), title or self.settings:getLinkedEditionId())
        else
          return _("Link book…")
        end
      end,
      callback = function(menu_instance)
        local force_search = self.settings:bookLinked()
        self:showLinkBookDialog(force_search, function()
          menu_instance:updateItems()
        end)
      end,
      hold_callback = function(menu_instance)
        if self.settings:bookLinked() then
          local file = self.ui.document.file
          self:maybeConfirm(
            _("Unlink book from Goodreads?"),
            function()
              self.settings:clearBookSettings(file)
              if self.state then
                self.state.current_status = nil
                self.state.current_shelf = nil
              end
              show_notification(_("Link removed"))
              menu_instance:updateItems()
            end
          )
        end
      end,
      keep_menu_open = true,
    })
  end

  if has_book then
    table.insert(items, {
      text = _("Auto-track progress"),
      checked_func = function()
        return self.settings:syncEnabled()
      end,
      enabled_func = function()
        return self.settings:bookLinked()
      end,
      callback = function()
        self.settings:setSync(not self.settings:syncEnabled())
      end,
      help_text = _("Automatically set Currently reading while reading, post percent to Goodreads, and Finished at ~100% / Book Status."),
      keep_menu_open = true,
    })
  end

  if has_book then
    table.insert(items, {
      text = _("Change status"),
      enabled_func = function()
        return self.settings:bookLinked()
      end,
      sub_item_table_func = function()
        return self:getStatusSubMenuItems()
      end,
    })
  end

  if has_book then
    table.insert(items, {
      text_func = function()
        local rating = self.settings:getKoreaderRating()
        if rating and rating > 0 then
          return T(_("Send rating (%1★)"), tostring(rating))
        end
        return _("Send rating")
      end,
      enabled_func = function()
        return self.settings:bookLinked() and self.settings:getKoreaderRating() ~= nil
      end,
      callback = function()
        if self.plugin then
          self.plugin:_withWifi(function()
            self.plugin:syncRatingNow(true)
          end)
        end
      end,
      help_text = _("Take ★ from KOReader Book Status and send to Goodreads (scale 1–5)."),
      keep_menu_open = true,
      separator = true,
    })
  end

  table.insert(items, {
    text = _("Settings"),
    sub_item_table_func = function()
      return self:getSettingsSubMenuItems()
    end,
  })

  table.insert(items, {
    text = _("About"),
    keep_menu_open = true,
    callback = function()
      local meta        = loadPluginMeta()
      local name        = (meta and meta.fullname) or _("Goodreads")
      local version     = (meta and meta.version) or "?"
      local description = (meta and meta.description) or ""
      local github = "github.com/advokatb/goodreads.koplugin"
      local info_text = name .. " v" .. version
        .. "\n\n" .. description
        .. "\n\n" .. github
      UIManager:show(InfoMessage:new {
        text = info_text,
        face = Font:getFace("cfont", 18),
        show_icon = false,
      })
    end,
  })

  return items
end

function GoodreadsMenu:mainMenu()
  return {
    text_func = function()
      if self.ui and self.ui.document and self.settings:bookLinked() then
        return _("Goodreads ✓")
      end
      return _("Goodreads")
    end,
    sub_item_table_func = function()
      return self:getSubMenuItems()
    end,
  }
end

return GoodreadsMenu
