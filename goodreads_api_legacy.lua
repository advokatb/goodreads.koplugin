-- goodreads_api_legacy.lua
-- Classic Rails endpoints on www.goodreads.com (no GraphQL/AppSync).
-- Spec: docs/TECH_DOCS.md, confirmed 2026-08-26 via curl + DevTools.

local _  = require("lib/goodreads_i18n").gettext
local T  = require("ffi/util").template
local logger        = require("logger")
local http          = require("socket.http")
local ltn12         = require("ltn12")
local json          = require("json")
local NetworkMgr    = require("ui/network/manager")
local socket        = require("socket")
local socketutil    = require("socketutil")

local GoodreadsParser = require("goodreads_parser")

local BASE_URL = "https://www.goodreads.com"
local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
local PARSE_ERROR = _("Could not parse the Goodreads response. The site may have changed.")

local STATUS_BY_SHELF = {
  ["to-read"]           = 0,
  ["read"]              = 1,
  ["currently-reading"] = 2,
  ["did-not-finish"]    = 3,
}

local COOKIE_ATTR = {
  path = true, domain = true, expires = true, ["max-age"] = true,
  samesite = true, secure = true, httponly = true, partitioned = true,
  version = true,
}

-- Short-lived GraphQL JWT (~5 min). A stale copy in the Cookie header makes
-- goodreads.com reject the whole request instead of ignoring the token.
local COOKIE_DROP = {
  jwt_token = true,
}

local GoodreadsApiLegacy = {
  settings = nil,
  on_error = nil,
  _csrf_token = nil,
  _warned_incomplete_cookie = false,
}

local function urlencode(str)
  if not str then return "" end
  str = tostring(str)
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return str
end

local function encode_form(data)
  local parts = {}
  for k, v in pairs(data) do
    table.insert(parts, urlencode(tostring(k)) .. "=" .. urlencode(tostring(v)))
  end
  return table.concat(parts, "&")
end

local function absolute_url(url)
  if not url or url == "" then return url end
  if url:match("^https?://") then return url end
  if url:sub(1, 2) == "//" then return "https:" .. url end
  if url:sub(1, 1) == "/" then return BASE_URL .. url end
  return BASE_URL .. "/" .. url
end

-- Rails XHR writes (rating stars, some form posts) return 204 No Content.
-- HTTP 202 here is AWS WAF (x-amzn-waf-action: challenge), not success.
local function is_success_code(code)
  return code == 200 or code == 201 or code == 204
end

--- Rebuild a Cookie header, dropping attributes and jwt_token.
function GoodreadsApiLegacy.sanitizeCookie(header)
  if not header or header == "" then return "" end
  local jar = {}
  local order = {}
  for name, value in header:gmatch("([%w_%-%.]+)=([^;]*)") do
    local lname = name:lower()
    if not COOKIE_ATTR[lname] and not COOKIE_DROP[name] and not COOKIE_DROP[lname] then
      value = value:match("^%s*(.-)%s*$") or value
      if value ~= "" then
        if not jar[name] then table.insert(order, name) end
        jar[name] = value
      end
    end
  end
  local parts = {}
  for _, name in ipairs(order) do
    table.insert(parts, name .. "=" .. jar[name])
  end
  return table.concat(parts, "; ")
end

-- LuaSocket comma-folds repeated Set-Cookie headers; Expires values also
-- contain commas. Walk name=value pairs and skip known attributes.
local function merge_set_cookie(cookie_header, set_cookie_value)
  if not set_cookie_value or set_cookie_value == "" then
    return cookie_header
  end
  local jar = {}
  local order = {}
  for name, value in (cookie_header or ""):gmatch("([%w_%-%.]+)=([^;]*)") do
    local lname = name:lower()
    if not COOKIE_ATTR[lname] and not COOKIE_DROP[name] then
      if not jar[name] then table.insert(order, name) end
      jar[name] = value
    end
  end
  for name, value in set_cookie_value:gmatch("([%w_%-%.]+)=([^;,]*)") do
    local lname = name:lower()
    if not COOKIE_ATTR[lname] and not COOKIE_DROP[name] and not COOKIE_DROP[lname] then
      value = value:match("^%s*(.-)%s*$") or value
      if value ~= "" then
        if not jar[name] then table.insert(order, name) end
        jar[name] = value
      end
    end
  end
  local parts = {}
  for _, name in ipairs(order) do
    table.insert(parts, name .. "=" .. jar[name])
  end
  return table.concat(parts, "; ")
end

local function make_headers(self, extra, method)
  local cookie = GoodreadsApiLegacy.sanitizeCookie(
    self.settings and self.settings:getCookie() or ""
  )
  local is_post = method == "POST"
  local headers
  if is_post then
    headers = {
      ["User-Agent"]      = USER_AGENT,
      ["Accept"]          = "*/*",
      ["Accept-Language"] = "en-US,en;q=0.9",
      ["Origin"]          = BASE_URL,
      ["Referer"]         = BASE_URL .. "/",
      ["Cookie"]          = cookie,
      ["Sec-Fetch-Site"]  = "same-origin",
      ["Sec-Fetch-Mode"]  = "cors",
      ["Sec-Fetch-Dest"]  = "empty",
    }
  else
    -- Real browsers never send Origin on a navigation GET. Sending it (or
    -- omitting Referer / Sec-Fetch-*) can trap goodreads.com in a self-redirect.
    headers = {
      ["User-Agent"]                 = USER_AGENT,
      ["Accept"]                     = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      ["Accept-Language"]            = "en-US,en;q=0.9",
      ["Referer"]                    = BASE_URL .. "/",
      ["Cookie"]                     = cookie,
      ["Sec-Fetch-Site"]             = "same-origin",
      ["Sec-Fetch-Mode"]             = "navigate",
      ["Sec-Fetch-Dest"]             = "document",
      ["Sec-Fetch-User"]             = "?1",
      ["Upgrade-Insecure-Requests"]  = "1",
    }
  end
  if extra then
    for k, v in pairs(extra) do headers[k] = v end
  end
  return headers
end

local function report_error(self, err)
  logger.warn("Goodreads API error:", err)
  if self.quiet then return end
  if self.on_error then self.on_error(err) end
end

function GoodreadsApiLegacy:_update_cookies_from_response(set_cookie_header)
  if not set_cookie_header or not self.settings then return end
  local current_cookie = self.settings:getCookie()
  if not current_cookie or current_cookie == "" then return end
  local merged = merge_set_cookie(current_cookie, set_cookie_header)
  merged = GoodreadsApiLegacy.sanitizeCookie(merged)
  if merged ~= "" and merged ~= GoodreadsApiLegacy.sanitizeCookie(current_cookie) then
    self.settings:setCookie(merged)
    -- authenticity_token is bound to the Rails session. A rotated _session_id2
    -- with a cached CSRF makes POSTs 404 until we fetch a new meta token.
    self:reset_csrf_token()
    logger.info("Goodreads: cookies rotated, CSRF cache cleared")
  end
end

function GoodreadsApiLegacy:_is_session_expired(code, body, headers)
  if code == 401 or code == 403 then return true end
  if headers then
    local loc = headers.location or headers.Location
    if loc and loc:find("/user/sign_in", 1, true) then
      return true
    end
  end
  if body then
    if body:find("something wrong with your Goodreads cookie", 1, true) then
      return true
    end
    if body:find("/user/sign_in", 1, true) and body:find("name=\"email\"") then
      return true
    end
  end
  return false
end

-- AWS WAF interstitial: HTTP 202 + x-amzn-waf-action (often "challenge").
-- Must not be reported as a generic "Network error: 202".
function GoodreadsApiLegacy:_is_waf_challenge(code, headers)
  if code == 202 then return true end
  if not headers then return false end
  local waf = headers["x-amzn-waf-action"] or headers["X-Amzn-Waf-Action"]
  return waf ~= nil and tostring(waf) ~= ""
end

function GoodreadsApiLegacy:_auth_error(code, body, headers)
  if self:_is_waf_challenge(code, headers) then
    return "waf_challenge"
  end
  if self:_is_session_expired(code, body, headers) then
    return "session_expired"
  end
  return nil
end

function GoodreadsApiLegacy:_is_csrf_invalid(code, body)
  -- Goodreads XHR often returns 404 (empty/HTML) for a stale authenticity_token
  -- instead of 422 + "Can't verify CSRF token authenticity".
  if code == 422 or code == 404 then return true end
  if not body then return false end
  if body:find("Can't verify CSRF token authenticity", 1, true) then return true end
  if body:find("InvalidAuthenticityToken", 1, true) then return true end
  if body:find("invalid authenticity token", 1, true) then return true end
  return false
end

function GoodreadsApiLegacy:reset_csrf_token()
  self._csrf_token = nil
end

function GoodreadsApiLegacy:_request(method, url, body, extra_headers, opts)
  opts = opts or {}
  if not NetworkMgr:isConnected() then return nil, nil, nil end

  local cookie = GoodreadsApiLegacy.sanitizeCookie(
    self.settings and self.settings:getCookie() or ""
  )
  if cookie == "" then
    logger.dbg("Goodreads: skip request — no session cookie")
    return nil, nil, nil
  end
  if not self._warned_incomplete_cookie then
    local has_session = cookie:find("_session_id2=", 1, true)
    local has_amazon = cookie:find("at-main=", 1, true) or cookie:find("session-token=", 1, true)
    if not has_session or not has_amazon then
      self._warned_incomplete_cookie = true
      logger.warn("Goodreads: cookie bundle incomplete (need _session_id2 plus Amazon SSO cookies)")
    end
  end

  local sink = {}
  socketutil:set_timeout(15, 30)

  local headers = make_headers(self, extra_headers, method)
  if opts._cookie_override and opts._cookie_override ~= "" then
    headers["Cookie"] = opts._cookie_override
  end
  if method == "POST" then
    if not headers["Content-Type"] then
      headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    end
    headers["Content-Length"] = tostring(body and #body or 0)
  end

  local request_params = {
    url      = url,
    method   = method or "GET",
    headers  = headers,
    sink     = ltn12.sink.table(sink),
    source   = body and ltn12.source.string(body) or nil,
    redirect = false,
  }

  logger.info("Goodreads: " .. method .. " " .. url)
  local _, code, resp_headers, _ = http.request(request_params)
  socketutil:reset_timeout()

  local response_body = table.concat(sink)
  local code_num = tonumber(code)

  local set_cookie = resp_headers and (resp_headers["set-cookie"] or resp_headers["Set-Cookie"])
  if set_cookie then
    self:_update_cookies_from_response(set_cookie)
  end

  local waf = resp_headers and (resp_headers["x-amzn-waf-action"] or resp_headers["X-Amzn-Waf-Action"])
  if waf then
    logger.warn("Goodreads: AWS WAF challenge (" .. tostring(waf)
      .. ") — refresh cookies from a logged-in browser")
  end

  local retries = opts._retries or 0
  if (code_num == 429 or (code_num and code_num >= 500 and code_num <= 599)) and retries < 2 then
    local wait = retries + 1
    logger.info("Goodreads: HTTP " .. tostring(code_num) .. ", retry in " .. wait .. "s")
    pcall(function() socket.sleep(wait) end)
    opts._retries = retries + 1
    return self:_request(method, url, body, extra_headers, opts)
  end

  local follow = opts.follow_redirects
  local hops = opts._redirect_hops or 0
  if follow and hops < 5 and (code_num == 301 or code_num == 302 or code_num == 303
      or code_num == 307 or code_num == 308) then
    local loc = resp_headers and (resp_headers.location or resp_headers.Location)
    if loc and loc ~= "" then
      local next_opts = {}
      for k, v in pairs(opts) do next_opts[k] = v end
      next_opts._redirect_hops = hops + 1
      -- Rails session bootstrap issues _session_id2 on a same-URL 302; the next
      -- hop must present that cookie or the redirect repeats forever.
      if set_cookie then
        local hop_cookie = opts._cookie_override or cookie
        next_opts._cookie_override = merge_set_cookie(hop_cookie, set_cookie)
      end
      return self:_request("GET", absolute_url(loc), nil, extra_headers, next_opts)
    end
  end

  return code_num, response_body, resp_headers
end

function GoodreadsApiLegacy:_csrf_urls()
  local urls = {}
  local user_id = self.settings and self.settings:getUserId()
  -- /review/list is classic Rails and is less often WAF-challenged than GET /.
  if user_id then
    table.insert(urls, BASE_URL .. "/review/list/" .. user_id .. "?shelf=read")
  end
  table.insert(urls, BASE_URL .. "/review/list")
  table.insert(urls, BASE_URL .. "/")
  return urls
end

function GoodreadsApiLegacy:_absorb_session_page(body)
  if not body or body == "" then return nil end
  local discovered = GoodreadsParser.parse_user_id(body)
  if discovered and self.settings then
    self.settings:setUserId(discovered)
  end
  local exclusive = GoodreadsParser.parse_exclusive_shelves(body)
  if exclusive and self.settings then
    self.settings:setExclusiveShelves(exclusive)
  end
  return GoodreadsParser.parse_csrf_token(body)
end

function GoodreadsApiLegacy:_ensure_csrf_token(force)
  if self._csrf_token and not force then
    return self._csrf_token
  end

  local html_headers = {
    ["Accept"]           = "text/html,application/xhtml+xml",
    ["X-Requested-With"] = nil,
  }

  local token
  for _, url in ipairs(self:_csrf_urls()) do
    local code, body, resp_headers = self:_request(
      "GET", url, nil, html_headers, { follow_redirects = true }
    )
    if not code then
      report_error(self, _("No network connection"))
      return nil
    end
    local auth_err = self:_auth_error(code, body, resp_headers)
    if auth_err then
      self:reset_csrf_token()
      report_error(self, auth_err)
      return nil
    end
    if code == 200 then
      token = self:_absorb_session_page(body or "")
      if token then break end
    end
  end

  if not token then
    report_error(self, PARSE_ERROR)
    return nil
  end

  self._csrf_token = token
  logger.info("Goodreads: cached CSRF token")
  return token
end

--- Check cookies against GET /review/list. Does not use on_error (caller shows UI).
function GoodreadsApiLegacy:test_session()
  local cookie = GoodreadsApiLegacy.sanitizeCookie(
    self.settings and self.settings:getCookie() or ""
  )
  if cookie == "" then
    return { ok = false, error = "no_cookies" }
  end
  if not NetworkMgr:isConnected() then
    return { ok = false, error = "no_network" }
  end

  local html_headers = {
    ["Accept"]           = "text/html,application/xhtml+xml",
    ["X-Requested-With"] = nil,
  }
  local last_err
  for _, url in ipairs(self:_csrf_urls()) do
    local code, body, resp_headers = self:_request(
      "GET", url, nil, html_headers, { follow_redirects = true }
    )
    if not code then
      return { ok = false, error = "no_network" }
    end
    local auth_err = self:_auth_error(code, body, resp_headers)
    if auth_err then
      self:reset_csrf_token()
      return { ok = false, error = auth_err }
    end
    if code == 200 then
      local token = self:_absorb_session_page(body or "")
      if token then
        self._csrf_token = token
        return {
          ok      = true,
          user_id = self.settings and self.settings:getUserId() or nil,
        }
      end
    else
      last_err = T(_("Network error: %1"), tostring(code))
    end
  end
  return { ok = false, error = last_err or PARSE_ERROR }
end

function GoodreadsApiLegacy:_with_csrf(callback)
  local token = self:_ensure_csrf_token(false)
  if not token then return nil end

  local result = callback(token)
  if result and result._retry_csrf then
    self:reset_csrf_token()
    token = self:_ensure_csrf_token(true)
    if not token then return nil end
    result = callback(token)
  end
  if result and result._retry_csrf then
    report_error(self, PARSE_ERROR)
    return nil
  end
  return result
end

-- ─── API interface ───────────────────────────────────────────────────────────

function GoodreadsApiLegacy:search(query)
  if not query or query == "" then return {} end

  return self:_with_csrf(function(token)
    local url = BASE_URL .. "/book/auto_complete?format=json&q=" .. urlencode(query)
    local extra = {
      ["Accept"]           = "*/*",
      ["X-Requested-With"] = "XMLHttpRequest",
      ["X-CSRF-Token"]     = token,
      ["Referer"]          = BASE_URL .. "/",
    }
    local code, response, headers = self:_request("GET", url, nil, extra)
    if not code then
      report_error(self, _("No network connection"))
      return nil
    end
    local auth_err = self:_auth_error(code, response, headers)
    if auth_err then
      report_error(self, auth_err)
      return nil
    end
    if self:_is_csrf_invalid(code, response) then
      return { _retry_csrf = true }
    end
    if code ~= 200 then
      report_error(self, T(_("Network error: %1"), tostring(code)))
      return nil
    end

    if not response or response:match("^%s*<") then
      report_error(self, PARSE_ERROR)
      return nil
    end

    local ok, decoded = pcall(json.decode, response)
    if not ok or decoded == nil then
      report_error(self, PARSE_ERROR)
      return nil
    end

    local books = GoodreadsParser.parse_search_results(decoded)
    if books == nil then
      report_error(self, PARSE_ERROR)
      return nil
    end
    return books
  end)
end

--- Look up a book by numeric Goodreads legacy id (autolink, skip search UI).
function GoodreadsApiLegacy:get_book(book_id)
  book_id = book_id and tostring(book_id)
  if not book_id or not book_id:match("^%d+$") then
    return nil
  end

  local books = self:search(book_id)
  if books then
    for _, book in ipairs(books) do
      if tostring(book.book_id) == book_id then
        return book
      end
    end
  end

  local extra = {
    ["Accept"] = "text/html,application/xhtml+xml",
  }
  local code, body, headers = self:_request(
    "GET",
    BASE_URL .. "/book/show/" .. book_id,
    nil,
    extra,
    { follow_redirects = true }
  )
  if not code then
    report_error(self, _("No network connection"))
    return nil
  end
  local auth_err = self:_auth_error(code, body, headers)
  if auth_err then
    report_error(self, auth_err)
    return nil
  end
  if code ~= 200 then
    report_error(self, T(_("Network error: %1"), tostring(code)))
    return nil
  end

  local ld = GoodreadsParser.parse_ldjson_book(body or "")
  local title = (ld and ld.title) or GoodreadsParser.parse_og_title(body or "")
  if not title then
    -- Still link by id: the identifier is an explicit signal.
    title = "Goodreads #" .. book_id
  end

  return {
    edition_id    = book_id,
    book_id       = book_id,
    title         = title,
    authors       = (ld and ld.author) or "",
    cover_url     = (ld and ld.image) or GoodreadsParser.parse_og_image(body or ""),
    rating        = "",
    pages         = ld and ld.pages or GoodreadsParser.parse_num_pages(body or ""),
    goodreads_url = BASE_URL .. "/book/show/" .. book_id,
  }
end

local function shelf_for_status(status)
  if status == 0 then return "to-read" end
  if status == 1 then return "read" end
  if status == 2 then return "currently-reading" end
  if status == 3 then return "did-not-finish" end
  return nil
end

function GoodreadsApiLegacy:get_review_state(book_id)
  book_id = book_id and tostring(book_id)
  if not book_id or not book_id:match("^%d+$") then
    return nil
  end

  local extra = {
    ["Accept"] = "text/html,application/xhtml+xml",
  }
  local code, body, headers = self:_request(
    "GET",
    BASE_URL .. "/review/edit/" .. book_id,
    nil,
    extra,
    { follow_redirects = true }
  )
  if not code then
    report_error(self, _("No network connection"))
    return nil
  end
  local auth_err = self:_auth_error(code, body, headers)
  if auth_err then
    report_error(self, auth_err)
    return nil
  end
  if code ~= 200 then
    report_error(self, T(_("Network error: %1"), tostring(code)))
    return nil
  end

  local parsed = GoodreadsParser.parse_review_edit(body or "")
  if not parsed then
    report_error(self, PARSE_ERROR)
    return nil
  end

  if parsed.exclusive_shelves and self.settings then
    self.settings:setExclusiveShelves(parsed.exclusive_shelves)
  end

  return {
    ok             = true,
    shelf          = parsed.shelf,
    status         = parsed.shelf and STATUS_BY_SHELF[parsed.shelf] or nil,
    rating         = parsed.rating or 0,
    review_id      = parsed.review_id,
    session_count  = parsed.session_count or 0,
    review_text    = parsed.review_text or "",
    notes          = parsed.notes or "",
  }
end

function GoodreadsApiLegacy:_add_to_shelf(book_id, shelf_name, action)
  return self:_with_csrf(function(token)
    local url = BASE_URL .. "/shelf/add_to_shelf"
    local extra = {
      ["Accept"]           = "*/*",
      ["X-Requested-With"] = "XMLHttpRequest",
      ["Referer"]          = BASE_URL .. "/review/edit/" .. tostring(book_id),
      ["Origin"]           = BASE_URL,
    }
    local body = encode_form({
      book_id            = tostring(book_id),
      name               = shelf_name,
      a                  = action or "",
      authenticity_token = token,
    })
    local code, response, headers = self:_request("POST", url, body, extra)
    if not code then
      local msg = _("No network connection")
      report_error(self, msg)
      return { ok = false, error_text = msg }
    end
    local auth_err = self:_auth_error(code, response, headers)
    if auth_err then
      report_error(self, auth_err)
      return { ok = false, error_text = auth_err }
    end
    if self:_is_csrf_invalid(code, response) then
      return { _retry_csrf = true }
    end
    if code ~= 200 then
      local msg = T(_("Network error: %1"), tostring(code))
      report_error(self, msg)
      return { ok = false, error_text = msg }
    end

    local read_status = GoodreadsParser.parse_read_status(response or "")
    if action ~= "remove" and not read_status then
      report_error(self, PARSE_ERROR)
      return { ok = false, error_text = "parse_error" }
    end

    return { ok = true, read_status = read_status }
  end)
end

function GoodreadsApiLegacy:set_status(book_id, status, rating, shelf_name)
  if not book_id then
    return { ok = false, error_text = "book_id is nil" }
  end

  if status == -2 then
    return self:remove_status(book_id, nil)
  end

  local shelf = shelf_name or shelf_for_status(status)
  if not shelf then
    return { ok = false, error_text = "unknown status" }
  end

  local result = self:_add_to_shelf(book_id, shelf, "")
  if not result or not result.ok then
    return result or { ok = false }
  end

  if status == 1 or shelf == "read" then
    local date_result = self:set_date_finished(book_id)
    if date_result and date_result.ok and date_result.date_read then
      result.date_read = date_result.date_read
    end
  end

  local rating_value = tonumber(rating) or 0
  if (status == 1 or shelf == "read") and rating_value >= 1 then
    local rate_result = self:set_rating(book_id, rating_value)
    if rate_result and rate_result.ok then
      result.rating = rate_result.rating
    else
      result.rating = 0
      result.error_text = rate_result and rate_result.error_text or _("Error updating rating")
    end
  end

  return result
end

--- Date finished for Reading Challenge: add a completed reading session
-- via GET /reading_sessions/new + POST /review/update/{book_id}.
-- Skips if the review already has a finished session. Does not post to the
-- update feed. Start date is left unset (year finished is what counts).
function GoodreadsApiLegacy:set_date_finished(book_id, when)
  book_id = book_id and tostring(book_id)
  if not book_id or not book_id:match("^%d+$") then
    return { ok = false, error_text = "book_id is nil" }
  end

  local t = when or os.date("*t")
  local year  = tostring(t.year)
  local month = tostring(t.month)
  local day   = tostring(t.day)
  local iso   = string.format("%04d-%02d-%02d", t.year, t.month, t.day)

  local extra_html = {
    ["Accept"] = "text/html,application/xhtml+xml",
  }
  local code, body, headers = self:_request(
    "GET",
    BASE_URL .. "/review/edit/" .. book_id,
    nil,
    extra_html,
    { follow_redirects = true }
  )
  if not code then
    return { ok = false, error_text = _("No network connection") }
  end
  local auth_err = self:_auth_error(code, body, headers)
  if auth_err then
    report_error(self, auth_err)
    return { ok = false, error_text = auth_err }
  end
  if code ~= 200 then
    return { ok = false, error_text = T(_("Network error: %1"), tostring(code)) }
  end

  local parsed = GoodreadsParser.parse_review_edit(body or "")
  if not parsed then
    return { ok = false, error_text = PARSE_ERROR }
  end
  if (parsed.session_count or 0) > 0 then
    logger.info("Goodreads: date finished already set, skip")
    return { ok = true, skipped = true }
  end

  local token = GoodreadsParser.parse_csrf_token(body or "") or self._csrf_token
  if token then
    self._csrf_token = token
  end
  if not token then
    return { ok = false, error_text = PARSE_ERROR }
  end

  local extra_xhr = {
    ["Accept"]           = "text/html",
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Referer"]          = BASE_URL .. "/review/edit/" .. book_id,
  }
  local ncode, nrow, nheaders = self:_request(
    "GET",
    BASE_URL .. "/reading_sessions/new?book_id=" .. book_id,
    nil,
    extra_xhr
  )
  if not ncode then
    return { ok = false, error_text = _("No network connection") }
  end
  local nauth = self:_auth_error(ncode, nrow, nheaders)
  if nauth then
    report_error(self, nauth)
    return { ok = false, error_text = nauth }
  end
  if ncode ~= 200 then
    return { ok = false, error_text = T(_("Network error: %1"), tostring(ncode)) }
  end

  local rowid = GoodreadsParser.parse_new_session_rowid(nrow or "")
  if not rowid or rowid == "" then
    report_error(self, PARSE_ERROR)
    return { ok = false, error_text = PARSE_ERROR }
  end

  local prefix = "readingSessionDatePicker" .. rowid
  local form = {
    utf8                 = "\226\156\147",
    authenticity_token   = token,
    ["review[review]"]   = parsed.review_text or "",
    ["review[spoiler_flag]"] = "0",
    ["review[notes]"]    = parsed.notes or "",
    ["review[sell_flag]"] = "0",
    readingEditsMade     = "true",
    source               = "form",
    next                 = "Post",
    [prefix .. "[delete]"] = "false",
    [prefix .. "[merge]"]  = "false",
    [prefix .. "[merge_edition_id]"] = "-1",
    [prefix .. "[date_picker_id]"] = prefix,
    [prefix .. "[end][year]"]  = year,
    [prefix .. "[end][month]"] = month,
    [prefix .. "[end][day]"]   = day,
  }

  local extra = {
    ["Accept"]  = "text/html,application/xhtml+xml",
    ["Referer"] = BASE_URL .. "/review/edit/" .. book_id,
    ["Origin"]  = BASE_URL,
  }
  local pcode, _, pheaders = self:_request(
    "POST",
    BASE_URL .. "/review/update/" .. book_id,
    encode_form(form),
    extra
  )
  if not pcode then
    local msg = _("No network connection")
    report_error(self, msg)
    return { ok = false, error_text = msg }
  end
  local pauth = self:_auth_error(pcode, nil, pheaders)
  if pauth then
    report_error(self, pauth)
    return { ok = false, error_text = pauth }
  end
  if not is_success_code(pcode) and pcode ~= 302 and pcode ~= 303 then
    local msg = T(_("Network error: %1"), tostring(pcode))
    report_error(self, msg)
    return { ok = false, error_text = msg }
  end
  logger.info("Goodreads: date finished=" .. iso .. " session=" .. rowid)
  return { ok = true, date_read = iso }
end

function GoodreadsApiLegacy:set_rating(book_id, rating)
  book_id = book_id and tostring(book_id)
  local rating_value = tonumber(rating) or 0
  rating_value = math.floor(rating_value + 0.5)
  if rating_value < 1 then rating_value = 1 end
  if rating_value > 5 then rating_value = 5 end

  if not book_id then
    return { ok = false, error_text = "book_id is nil" }
  end

  return self:_with_csrf(function(token)
    local url = BASE_URL .. "/review/rate/" .. book_id
      .. "?no_lightbox=true&queue=false&stars_click=true&rating="
      .. tostring(rating_value) .. "&ref=undefined"
    local extra = {
      ["Accept"]           = "*/*",
      ["X-Requested-With"] = "XMLHttpRequest",
      ["X-CSRF-Token"]     = token,
      ["Referer"]          = BASE_URL .. "/review/edit/" .. book_id,
      ["Origin"]           = BASE_URL,
      ["Content-Type"]     = "application/x-www-form-urlencoded; charset=UTF-8",
    }
    local code, response, headers = self:_request("POST", url, "", extra)
    if not code then
      local msg = _("No network connection")
      report_error(self, msg)
      return { ok = false, error_text = msg }
    end
    local auth_err = self:_auth_error(code, response, headers)
    if auth_err then
      report_error(self, auth_err)
      return { ok = false, error_text = auth_err }
    end
    if self:_is_csrf_invalid(code, response) then
      return { _retry_csrf = true }
    end
    -- Site returns 204 No Content; empty body is success, not a network error.
    if not is_success_code(code) then
      local msg = T(_("Network error: %1"), tostring(code))
      report_error(self, msg)
      return { ok = false, error_text = msg }
    end
    logger.info("Goodreads: rated book_id=" .. book_id .. " rating=" .. tostring(rating_value))
    return { ok = true, rating = rating_value }
  end)
end

--- Reading progress via POST /user_status.json.
-- Send either percent or page, never both (422). Prefer percent from KOReader.
-- Empty `body` is omitted so this is a location ping, not a feed note.
-- GET /user_status and GET /user_status.json are 404 — POST only. Live 2026-08-27.
function GoodreadsApiLegacy:set_progress(book_id, percent)
  book_id = book_id and tostring(book_id)
  if not book_id or not book_id:match("^%d+$") then
    return { ok = false, error_text = "book_id is nil" }
  end

  local pct = tonumber(percent)
  if not pct then
    return { ok = false, error_text = "percent is nil" }
  end
  pct = math.floor(pct + 0.5)
  if pct < 1 then pct = 1 end
  if pct > 100 then pct = 100 end

  return self:_with_csrf(function(token)
    local extra = {
      ["Accept"]           = "application/json",
      ["X-Requested-With"] = "XMLHttpRequest",
      ["X-CSRF-Token"]     = token,
      ["Referer"]          = BASE_URL .. "/",
      ["Origin"]           = BASE_URL,
    }
    local body = encode_form({
      authenticity_token       = token,
      ["user_status[book_id]"] = book_id,
      ["user_status[percent]"] = tostring(pct),
    })
    local code, response, headers = self:_request(
      "POST",
      BASE_URL .. "/user_status.json",
      body,
      extra
    )
    if not code then
      logger.warn("Goodreads: progress post failed — no network")
      return { ok = false, error_text = _("No network connection") }
    end
    local auth_err = self:_auth_error(code, response, headers)
    if auth_err then
      report_error(self, auth_err)
      return { ok = false, error_text = auth_err }
    end
    if self:_is_csrf_invalid(code, response) then
      return { _retry_csrf = true }
    end
    if not is_success_code(code) then
      logger.warn("Goodreads: progress post HTTP " .. tostring(code))
      return { ok = false, error_text = T(_("Network error: %1"), tostring(code)) }
    end

    local parsed
    if response and response ~= "" then
      local ok, decoded = pcall(json.decode, response)
      if ok then
        parsed = GoodreadsParser.parse_user_status(decoded)
      end
    end
    local sent = parsed and parsed.current or pct
    logger.info("Goodreads: progress book_id=" .. book_id .. " percent=" .. tostring(sent))
    return { ok = true, percent = sent, position_type = parsed and parsed.position_type or "percent" }
  end)
end

function GoodreadsApiLegacy:remove_status(book_id, _current_status, _current_shelf)
  book_id = book_id and tostring(book_id)
  if not book_id or not book_id:match("^%d+$") then
    return { ok = false, error_text = "book_id is nil" }
  end

  -- Exclusive shelves cannot be cleared with add_to_shelf a=remove (404).
  -- The site uses "Remove from my books": POST /review/destroy/{book_id}.
  return self:_with_csrf(function(token)
    local extra = {
      ["Accept"]           = "text/html,application/xhtml+xml",
      ["X-Requested-With"] = "XMLHttpRequest",
      ["X-CSRF-Token"]     = token,
      ["Referer"]          = BASE_URL .. "/review/edit/" .. book_id,
      ["Origin"]           = BASE_URL,
    }
    local body = encode_form({
      authenticity_token = token,
    })
    local code, response, headers = self:_request(
      "POST",
      BASE_URL .. "/review/destroy/" .. book_id,
      body,
      extra
    )
    if not code then
      local msg = _("No network connection")
      report_error(self, msg)
      return { ok = false, error_text = msg }
    end
    local auth_err = self:_auth_error(code, response, headers)
    if auth_err then
      report_error(self, auth_err)
      return { ok = false, error_text = auth_err }
    end
    if self:_is_csrf_invalid(code, response) then
      return { _retry_csrf = true }
    end
    -- No review yet (never added, or already removed) → already clear locally.
    if code == 404 then
      logger.info("Goodreads: review already absent, treat destroy as success")
      return { ok = true, skipped = true }
    end
    if not is_success_code(code) and code ~= 302 and code ~= 303 then
      local msg = T(_("Network error: %1"), tostring(code))
      report_error(self, msg)
      return { ok = false, error_text = msg }
    end
    logger.info("Goodreads: removed from my books book_id=" .. book_id)
    return { ok = true }
  end)
end

return GoodreadsApiLegacy
