-- goodreads_parser.lua
-- Parse Goodreads HTML/JSON/JS fragments.
-- Search results are JSON (no HTML card parsing). CSRF, user id, shelf
-- status and og:title are extracted with Lua patterns.

local logger = require("logger")

local GoodreadsParser = {}

function GoodreadsParser.decode_entities(s)
  if not s then return "" end
  return s
    :gsub("&amp;",  "&")
    :gsub("&lt;",   "<")
    :gsub("&gt;",   ">")
    :gsub("&quot;", '"')
    :gsub("&#39;",  "'")
    :gsub("&apos;", "'")
    :gsub("&nbsp;", " ")
    :gsub("&#(%d+);", function(n)
      local code = tonumber(n)
      if code and code < 128 then
        return string.char(code)
      end
      return ""
    end)
end

--- CSRF token from a classic Rails HTML page.
function GoodreadsParser.parse_csrf_token(html)
  if not html or html == "" then return nil end
  local token = html:match('<meta%s+name=["\']csrf%-token["\']%s+content=["\']([^"\']+)["\']')
  if not token then
    token = html:match('<meta%s+content=["\']([^"\']+)["\']%s+name=["\']csrf%-token["\']')
  end
  if token and token ~= "" then
    return GoodreadsParser.decode_entities(token)
  end
  token = html:match('name="authenticity_token"%s+value="([^"]+)"')
  if token and token ~= "" then
    return GoodreadsParser.decode_entities(token)
  end
  return nil
end

--- Numeric user id from a Location header or HTML body.
function GoodreadsParser.parse_user_id(text)
  if not text or text == "" then return nil end
  local id = text:match("/review/list/(%d+)")
  if id then return id end
  id = text:match("/user/show/(%d+)")
  if id then return id end
  id = text:match("gr_user_id['\"]?%s*[:=]%s*['\"]?(%d+)")
  return id
end

--- Exclusive-shelf name from add_to_shelf JS or review/edit HTML.
-- add_to_shelf wraps the snippet in a JS string, so quotes are often escaped: \"to-read\"
-- Match `var read_status = ...` only — not `if (read_status === "read")`.
function GoodreadsParser.parse_read_status(js_body)
  if not js_body or js_body == "" then return nil end
  local status = js_body:match('var%s+read_status%s*=%s*\\*"([^"\\]+)')
  if not status then
    status = js_body:match("var%s+read_status%s*=%s*\\*'([^'\\]+)")
  end
  if not status or status == "" then return nil end
  return status
end

--- Exclusive shelf currently selected in ShelfChooser (`chosen` ∩ `exclusive`).
function GoodreadsParser.parse_chosen_exclusive(html)
  local exclusive = GoodreadsParser.parse_exclusive_shelves(html)
  if not exclusive then return nil end
  local have = {}
  for _i, name in ipairs(exclusive) do
    have[name] = true
  end
  local block = html:match("chosen:%s*%[([^%]]+)%]")
  if not block then return nil end
  for name in block:gmatch('"([^"]+)"') do
    if have[name] then return name end
  end
  return nil
end

--- Exclusive shelf names from ShelfChooser config on classic Rails pages.
function GoodreadsParser.parse_exclusive_shelves(html)
  if not html or html == "" then return nil end
  local block = html:match("exclusive:%s*%[([^%]]+)%]")
  if not block then return nil end
  local list = {}
  local seen = {}
  for name in block:gmatch('"([^"]+)"') do
    if name ~= "all" and not seen[name] then
      seen[name] = true
      table.insert(list, name)
    end
  end
  if #list == 0 then return nil end
  return list
end

--- Current shelf, rating, review_id from GET /review/edit/{book_id}.
function GoodreadsParser.parse_review_edit(html)
  if not html or html == "" then return nil end
  local rating = html:match('data%-rating="(%d+)"')
  local review_id = html:match('id="form_review_(%d+)"')
  if not review_id then
    review_id = html:match("/review/show/(%d+)")
  end
  local session_count = html:match("data%-count=['\"](%d+)['\"][^>]-id=['\"]readingSessionsCount['\"]")
  if not session_count then
    session_count = html:match("id=['\"]readingSessionsCount['\"][^>]-data%-count=['\"](%d+)['\"]")
  end
  local review_text = html:match("name=['\"]review%[review%]['\"][^>]*>(.-)</textarea>")
  local notes = html:match("name=['\"]review%[notes%]['\"][^>]*>(.-)</textarea>")
  -- /review/new (no existing review) still contains ShelfChooser JS with a default
  -- read_status; only a real review form means the book is on an exclusive shelf.
  local shelf = nil
  if review_id then
    shelf = GoodreadsParser.parse_chosen_exclusive(html)
      or GoodreadsParser.parse_read_status(html)
  end
  return {
    shelf             = shelf,
    rating            = rating and tonumber(rating) or 0,
    review_id         = review_id,
    exclusive_shelves = GoodreadsParser.parse_exclusive_shelves(html),
    session_count     = tonumber(session_count) or 0,
    review_text       = review_text or "",
    notes             = notes or "",
  }
end

--- Row id from GET /reading_sessions/new?book_id= (HTML table row fragment).
function GoodreadsParser.parse_new_session_rowid(html)
  if not html or html == "" then return nil end
  return html:match("data%-rowid=['\"]([^'\"]+)['\"]")
end

--- POST /user_status.json success body.
-- { updatedAt, finalPosition, currentPosition, positionType = "page"|"percent" }
-- 422: { errors = "Provide either page or percent..." }
function GoodreadsParser.parse_user_status(decoded)
  if type(decoded) ~= "table" then return nil end
  if decoded.errors then return nil end
  local current = tonumber(decoded.currentPosition)
  local position_type = decoded.positionType
  if not current then return nil end
  return {
    current        = current,
    final          = tonumber(decoded.finalPosition),
    position_type  = position_type,
    updated_at     = decoded.updatedAt,
  }
end

--- schema.org/Book JSON-LD on /book/show/{id} (title/author/cover).
function GoodreadsParser.parse_ldjson_book(html)
  if not html or html == "" then return nil end
  local block = html:match('<script[^>]-type=["\']application/ld%+json["\'][^>]*>(.-)</script>')
  if not block then return nil end
  local title = block:match('"name"%s*:%s*"(.-)"')
  if not title then return nil end
  local image = block:match('"image"%s*:%s*"(.-)"')
  local author = block:match('"author"%s*:%s*%[%s*{"@type"%s*:%s*"Person"%s*,%s*"name"%s*:%s*"(.-)"')
  local pages = tonumber(block:match('"numberOfPages"%s*:%s*(%d+)'))
  return {
    title  = GoodreadsParser.decode_entities(title),
    image  = image,
    author = author and GoodreadsParser.decode_entities(author) or nil,
    pages  = pages,
  }
end

function GoodreadsParser.parse_num_pages(html)
  if not html or html == "" then return nil end
  local n = tonumber(html:match('"numPages"%s*:%s*(%d+)'))
  if n and n > 0 then return n end
  return nil
end

function GoodreadsParser.parse_og_title(html)
  if not html or html == "" then return nil end
  local title = html:match('<meta%s+property=["\']og:title["\']%s+content=["\']([^"\']+)["\']')
  if not title then
    title = html:match('<meta%s+content=["\']([^"\']+)["\']%s+property=["\']og:title["\']')
  end
  if not title then
    title = html:match("<title>(.-)</title>")
    if title then
      title = title:gsub("%s*%|%s*Goodreads%s*$", "")
    end
  end
  if title and title ~= "" then
    return GoodreadsParser.decode_entities(title):match("^%s*(.-)%s*$")
  end
  return nil
end

function GoodreadsParser.parse_og_image(html)
  if not html or html == "" then return nil end
  local url = html:match('<meta%s+property=["\']og:image["\']%s+content=["\']([^"\']+)["\']')
  if not url then
    url = html:match('<meta%s+content=["\']([^"\']+)["\']%s+property=["\']og:image["\']')
  end
  return url and GoodreadsParser.decode_entities(url) or nil
end

--- Map one /book/auto_complete JSON object to the plugin book table.
function GoodreadsParser.map_autocomplete_item(item)
  if type(item) ~= "table" then return nil end
  local book_id = item.bookId and tostring(item.bookId) or nil
  if not book_id or book_id == "" then return nil end

  local title = item.bookTitleBare or item.title or ""
  if title == "" then return nil end

  local author_name = ""
  if type(item.author) == "table" then
    author_name = item.author.name or ""
  elseif type(item.author) == "string" then
    author_name = item.author
  end

  local book_url = item.bookUrl or ("/book/show/" .. book_id)
  if book_url:sub(1, 4) ~= "http" then
    book_url = "https://www.goodreads.com" .. book_url
  end

  local rating = item.avgRating and tostring(item.avgRating) or ""

  return {
    edition_id    = book_id,
    book_id       = book_id,
    work_id       = item.workId and tostring(item.workId) or nil,
    title         = title,
    authors       = author_name,
    cover_url     = item.imageUrl,
    rating        = rating,
    goodreads_url = book_url,
    contributions = { { author = { name = author_name } } },
    cached_image  = item.imageUrl and { url = item.imageUrl } or nil,
    book_series   = {},
  }
end

--- Parse /book/auto_complete JSON array.
-- @return array of book tables, or nil on unparseable payload
function GoodreadsParser.parse_search_results(decoded)
  if type(decoded) ~= "table" then
    return nil
  end

  local results = {}
  local seen = {}

  -- JSON array (ipairs) or a wrapper object with a list field
  local list = decoded
  if decoded.results and type(decoded.results) == "table" then
    list = decoded.results
  end

  for _, item in ipairs(list) do
    local mapped = GoodreadsParser.map_autocomplete_item(item)
    if mapped and not seen[mapped.book_id] then
      seen[mapped.book_id] = true
      table.insert(results, mapped)
    end
  end

  logger.info("Goodreads parser: found " .. #results .. " books in search results")
  return results
end

return GoodreadsParser
