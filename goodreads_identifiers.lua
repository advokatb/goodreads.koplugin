-- goodreads_identifiers.lua
-- Extract a Goodreads book id from document metadata or EPUB OPF.
--
-- KOReader creengine already surfaces OPF identifiers via getProps().identifiers
-- as a multiline string of "scheme:value" lines, e.g.:
--   goodreads:256017244
--   isbn:9785699067367
-- Custom opf:scheme="GOODREADS" is included (lowercased). If that field is
-- missing (PDF/FB2/MOBI, or a CRE build that drops unknown schemes), fall back
-- to reading META-INF/container.xml + content.opf from the EPUB zip.

local logger = require("logger")

local GoodreadsIdentifiers = {}

local function trim(s)
  return s and s:match("^%s*(.-)%s*$") or ""
end

--- Parse a KOReader identifiers string or table into { scheme_lower = value }.
function GoodreadsIdentifiers.parse(identifiers)
  local result = {}
  if identifiers == nil then return result end

  if type(identifiers) == "table" then
    for k, v in pairs(identifiers) do
      if type(k) == "string" and v ~= nil then
        result[k:lower()] = trim(tostring(v))
      end
    end
    return result
  end

  if type(identifiers) ~= "string" or identifiers == "" then
    return result
  end

  for line in identifiers:gmatch("[^\r\n]+") do
    line = trim(line)
    if line ~= "" then
      local scheme, value = line:match("^([^:]+):%s*(%S+)")
      if scheme and value then
        result[scheme:lower()] = value
      end
    end
  end
  return result
end

function GoodreadsIdentifiers.goodreadsIdFromMap(map)
  if not map then return nil end
  local id = map.goodreads or map["goodreads-id"] or map.gr
  if id and id:match("^%d+$") then
    return id
  end
  return nil
end

local function digits_only(s)
  return (tostring(s or ""):gsub("[%s%-]", ""))
end

--- ISBN-13 preferred, else ISBN-10. Hyphens/spaces stripped.
function GoodreadsIdentifiers.isbnFromMap(map)
  if not map then return nil end
  local candidates = {
    map.isbn13, map["isbn-13"], map.isbn_13,
    map.isbn, map.isbn10, map["isbn-10"], map.isbn_10,
  }
  for _, raw in ipairs(candidates) do
    local n = digits_only(raw)
    if n:match("^%d{13}$") or n:match("^%d{9}[%dXx]$") or n:match("^%d{10}$") then
      return n
    end
  end
  return nil
end

local function identifiersFromDocument(ui)
  if not ui then return nil end

  if ui.document and ui.document.getProps then
    local ok, props = pcall(function() return ui.document:getProps() end)
    if ok and props and props.identifiers then
      return props.identifiers
    end
  end

  if ui.doc_settings then
    local doc_props = ui.doc_settings:readSetting("doc_props")
    if doc_props and doc_props.identifiers then
      return doc_props.identifiers
    end
  end

  return nil
end

local function isEpubPath(path)
  if not path or path == "" then return false end
  local lower = path:lower()
  return lower:match("%.epub$") or lower:match("%.epub%.zip$")
end

local function findArchiveEntry(arc, wanted)
  local wanted_lower = wanted:lower():gsub("\\", "/")
  for _, entry in ipairs(arc.entries or {}) do
    if type(entry) == "table" and entry.path then
      local p = entry.path:gsub("\\", "/"):lower()
      if p == wanted_lower or p:sub(-#wanted_lower) == wanted_lower then
        return entry.path
      end
    end
  end
  return nil
end

local function readZipEntry(filepath, inner_path)
  local ok, Archiver = pcall(require, "ffi/archiver")
  if not ok or not Archiver or not Archiver.Reader then
    logger.dbg("Goodreads: ffi/archiver not available")
    return nil
  end

  local arc = Archiver.Reader:new()
  if not arc:open(filepath) then
    logger.dbg("Goodreads: failed to open EPUB zip: " .. tostring(filepath))
    return nil
  end

  for _ in arc:iterate() do end

  local key = findArchiveEntry(arc, inner_path) or inner_path
  local content = arc:extractToMemory(key)
  arc:close()
  return content
end

local function parseOpfIdentifiers(opf_xml)
  local map = {}
  if not opf_xml or opf_xml == "" then return map end

  for tag in opf_xml:gmatch("<dc:identifier[^>]*>.-</dc:identifier>") do
    local inner = tag:match(">(.-)<") or ""
    local value = trim(inner:gsub("%s+", " "):gsub("<[^>]+>", ""))
    if value ~= "" then
      local scheme = tag:match('[sS]cheme=["\']([^"\']+)["\']')
      if not scheme then
        scheme = tag:match('%sid=["\']([^"\']+)["\']')
      end
      if scheme then
        map[scheme:lower()] = value
      end
      local prefixed_scheme, prefixed_value = value:match("^([%w_%-]+):(%S+)$")
      if prefixed_scheme and prefixed_value then
        map[prefixed_scheme:lower()] = prefixed_value
      end
    end
  end
  return map
end

function GoodreadsIdentifiers.fromOpf(filepath)
  if not isEpubPath(filepath) then return nil end

  local container = readZipEntry(filepath, "META-INF/container.xml")
  if not container then return nil end

  local opf_path = container:match('full%-path=["\']([^"\']+)["\']')
  if not opf_path or opf_path == "" then
    logger.dbg("Goodreads: container.xml has no rootfile path")
    return nil
  end

  local opf = readZipEntry(filepath, opf_path)
  if not opf then
    logger.dbg("Goodreads: failed to read OPF " .. opf_path)
    return nil
  end

  return parseOpfIdentifiers(opf)
end

--- Return the numeric Goodreads book id for the currently open document, or nil.
function GoodreadsIdentifiers.getGoodreadsId(ui)
  local raw = identifiersFromDocument(ui)
  local id = GoodreadsIdentifiers.goodreadsIdFromMap(GoodreadsIdentifiers.parse(raw))
  if id then return id end

  local file = ui and ui.document and ui.document.file
  if not file then return nil end

  local opf_map = GoodreadsIdentifiers.fromOpf(file)
  id = GoodreadsIdentifiers.goodreadsIdFromMap(opf_map)
  if id then
    logger.info("Goodreads: read book id " .. id .. " from EPUB OPF")
  end
  return id
end

--- ISBN-13/10 from identifiers, doc_props.isbn, or EPUB OPF.
function GoodreadsIdentifiers.getIsbn(ui)
  local raw = identifiersFromDocument(ui)
  local isbn = GoodreadsIdentifiers.isbnFromMap(GoodreadsIdentifiers.parse(raw))
  if isbn then return isbn end

  if ui and ui.document and ui.document.getProps then
    local ok, props = pcall(function() return ui.document:getProps() end)
    if ok and props then
      isbn = GoodreadsIdentifiers.isbnFromMap({
        isbn = props.isbn or props.ISBN,
        isbn13 = props.isbn13 or props.isbn_13,
        isbn10 = props.isbn10 or props.isbn_10,
      })
      if isbn then return isbn end
    end
  end

  local file = ui and ui.document and ui.document.file
  if not file then return nil end
  local opf_map = GoodreadsIdentifiers.fromOpf(file)
  isbn = GoodreadsIdentifiers.isbnFromMap(opf_map)
  if isbn then
    logger.info("Goodreads: read ISBN " .. isbn .. " from EPUB OPF")
  end
  return isbn
end

return GoodreadsIdentifiers
