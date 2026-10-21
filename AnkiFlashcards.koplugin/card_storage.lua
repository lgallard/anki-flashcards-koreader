-- Local storage for Anki flashcards.
-- Follows the same pattern as vocab_builder.lua from AI_Dictionary.

local DataStorage = require("datastorage")
local json        = require("json")

local CARDS_FILE    = DataStorage:getDataDir() .. "/anki_flashcards.json"
local SETTINGS_FILE = DataStorage:getDataDir() .. "/anki_flashcards_settings.json"
local EXPORT_PREFIX = DataStorage:getDataDir() .. "/anki_flashcards_export_"

local CardStorage = {}

local function normalize(phrase)
    return (phrase or ""):lower():match("^%s*(.-)%s*$")
end

-- Naive English stemmer: strip common inflectional suffixes.
local function stem(word)
    local w = normalize(word)
    -- Order matters — try longest suffixes first.
    w = w:gsub("ies$", "y")       -- "stories" → "story"
    w = w:gsub("ying$", "y")      -- "studying" → "study" (approximate)
    w = w:gsub("ving$", "ve")     -- "having" → "have"
    w = w:gsub("ting$", "t")      -- "sitting" → "sit" (approximate)
    w = w:gsub("ning$", "n")      -- "running" → "run"
    w = w:gsub("ging$", "g")      -- "nagging" → "nag"
    w = w:gsub("ding$", "d")      -- "adding" → "add"
    w = w:gsub("bing$", "b")      -- "rubbing" → "rub"
    w = w:gsub("ping$", "p")      -- "tapping" → "tap"
    w = w:gsub("ming$", "m")      -- "swimming" → "swim"
    w = w:gsub("zing$", "z")      -- "buzzing" → "buz" (close enough)
    w = w:gsub("sing$", "s")      -- "missing" → "mis" (approximate)
    w = w:gsub("ing$", "")        -- "taxing" → "tax"
    w = w:gsub("ied$", "y")       -- "studied" → "study"
    w = w:gsub("ved$", "ve")      -- "moved" → "move"
    w = w:gsub("ced$", "ce")      -- "danced" → "dance"
    w = w:gsub("sed$", "se")      -- "closed" → "close"
    w = w:gsub("ted$", "t")       -- "dotted" → "dot"
    w = w:gsub("ned$", "n")       -- "planned" → "plan"
    w = w:gsub("ged$", "g")       -- "nagged" → "nag"
    w = w:gsub("ded$", "d")       -- "added" → "add"
    w = w:gsub("bed$", "b")       -- "rubbed" → "rub"
    w = w:gsub("ped$", "p")       -- "tapped" → "tap"
    w = w:gsub("med$", "m")       -- "trimmed" → "trim"
    w = w:gsub("ed$", "")         -- "walked" → "walk"
    w = w:gsub("es$", "")         -- "cogs" won't match but "boxes" → "box"
    w = w:gsub("s$", "")          -- "cogs" → "cog"
    w = w:gsub("ly$", "")         -- "quickly" → "quick"
    w = w:gsub("er$", "")         -- "bigger" → "bigg" (approximate)
    w = w:gsub("est$", "")        -- "biggest" → "bigg"
    return w
end

local function load_raw()
    local f = io.open(CARDS_FILE, "r")
    if not f then return {} end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then return data end
    return {}
end

local function save_raw(entries)
    local ok, encoded = pcall(json.encode, entries)
    if not ok then return false end

    -- Never truncate the live database until a complete replacement is ready.
    -- The temporary file is beside CARDS_FILE so rename stays on one filesystem.
    local temp_path = CARDS_FILE .. ".tmp-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 2147483646))
    local f = io.open(temp_path, "w")
    if not f then return false end
    local wrote, write_result = pcall(f.write, f, encoded)
    if not wrote or not write_result then
        pcall(f.close, f)
        os.remove(temp_path)
        return false
    end
    local closed, close_result = pcall(f.close, f)
    if not closed or not close_result then
        os.remove(temp_path)
        return false
    end
    if not os.rename(temp_path, CARDS_FILE) then
        os.remove(temp_path)
        return false
    end
    return true
end

local function new_storage_id(entries)
    local prefix = tostring(os.time()) .. "-"
    local suffix = math.random(1, 2147483646)
    local id = prefix .. suffix
    local exists = true
    while exists do
        exists = false
        for _, entry in ipairs(entries) do
            if entry._storage_id == id then
                exists = true
                suffix = suffix + 1
                id = prefix .. suffix
                break
            end
        end
    end
    return id
end

-- Prefer a stable per-generation identity when available. Phrase is retained as
-- a fallback for cards written before identities were introduced.
local function find_entry(entries, target)
    if type(target) == "table" and target._storage_id then
        for _, entry in ipairs(entries) do
            if entry._storage_id == target._storage_id then
                return entry
            end
        end
        return nil
    end
    local phrase = type(target) == "table" and target.phrase or target
    local key = normalize(phrase)
    for _, entry in ipairs(entries) do
        if normalize(entry.phrase) == key then
            return entry
        end
    end
    return nil
end

-- Records written before stable identities were introduced are safe for
-- synchronous phrase operations, but async callbacks must never keep using a
-- phrase-only identity. Persist an id before the caller starts its mutation and
-- copy it to the in-memory card used by that callback.
local function ensure_entry_identity(entries, entry, target)
    if entry._storage_id then
        if type(target) == "table" then target._storage_id = entry._storage_id end
        return true
    end
    entry._storage_id = new_storage_id(entries)
    if not save_raw(entries) then
        entry._storage_id = nil
        return false
    end
    if type(target) == "table" then target._storage_id = entry._storage_id end
    return true
end

-- Save a new card. Returns true on success or false + reason string.
function CardStorage.save_card(card)
    local key     = normalize(card.phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            return false, "already_saved"
        end
    end
    local entry = {
        _storage_id    = new_storage_id(entries),
        phrase         = card.phrase         or "",
        ipa            = card.ipa            or "",
        definition     = card.definition     or "",
        synonyms       = card.synonyms       or "",
        text           = card.text           or "",
        source         = card.source         or "",
        book_title     = card.book_title     or "",
        book_author    = card.book_author    or "",
        image_path     = card.image_path     or "",
        image_prompt   = card.image_prompt   or "",
        _audio_url     = card._audio_url     or "",
        _ankivocab_word = card._ankivocab_word or "",
        highlight_pos0 = card.highlight_pos0,
        highlight_pos1 = card.highlight_pos1,
        date           = os.date("%Y-%m-%d"),
        updated_at     = os.time(),
        sent_to_anki   = false,
    }
    table.insert(entries, entry)
    if not save_raw(entries) then return false, "write_failed" end
    card._storage_id = entry._storage_id
    card.sent_to_anki = entry.sent_to_anki
    return true
end

-- Returns the full list of saved cards.
function CardStorage.load_cards()
    return load_raw()
end

-- ── Card export ─────────────────────────────────────────────────────────────

local function escape_export_cell(value, delimiter)
    value = tostring(value or "")
    -- Spreadsheet applications may evaluate cells that begin with formula
    -- markers, including after leading whitespace. Prefix an apostrophe so the
    -- original value is imported as literal text.
    if value:match("^%s*[=+%-@]") then
        value = "'" .. value
    end
    if value:find('"', 1, true)
       or value:find(delimiter, 1, true)
       or value:find("\r", 1, true)
       or value:find("\n", 1, true) then
        return '"' .. value:gsub('"', '""') .. '"'
    end
    return value
end

local function image_filename(path)
    if not path or path == "" then return "" end
    return path:match("([^/\\]+)$") or path
end

local function export_path(format)
    local stamp = os.date("%Y%m%d-%H%M%S")
    local path = EXPORT_PREFIX .. stamp .. "." .. format
    local suffix = 2
    local existing = io.open(path, "r")
    while existing do
        existing:close()
        path = EXPORT_PREFIX .. stamp .. "_" .. tostring(suffix) .. "." .. format
        suffix = suffix + 1
        existing = io.open(path, "r")
    end
    return path
end

-- Export cards as CSV or TSV. Images are represented by filename only.
-- Returns output path and count, or nil, 0, and an error code.
function CardStorage.export_cards(cards, format)
    if format ~= "csv" and format ~= "tsv" then
        return nil, 0, "unsupported_format"
    end
    if not cards or #cards == 0 then
        return nil, 0, "no_cards"
    end

    local delimiter = format == "csv" and "," or "\t"
    local path = export_path(format)
    local temp_path = path .. ".tmp"
    local file = io.open(temp_path, "w")
    if not file then return nil, 0, "write_failed" end

    local fields = { "Phrase", "IPA", "Definition", "Synonyms", "Text", "Source", "Image" }
    if not file:write(table.concat(fields, delimiter), "\r\n") then
        file:close()
        os.remove(temp_path)
        return nil, 0, "write_failed"
    end
    for _, card in ipairs(cards) do
        card = card or {}
        local row = {
            tostring(card.phrase or ""),
            tostring(card.ipa or ""),
            tostring(card.definition or ""),
            tostring(card.synonyms or ""),
            tostring(card.text or ""),
            tostring(card.source or ""),
            tostring(image_filename(card.image_path) or ""),
        }
        for i = 1, #row do
            row[i] = escape_export_cell(row[i], delimiter)
        end
        if not file:write(table.concat(row, delimiter), "\r\n") then
            file:close()
            os.remove(temp_path)
            return nil, 0, "write_failed"
        end
    end
    if not file:close() then
        os.remove(temp_path)
        return nil, 0, "write_failed"
    end

    if not os.rename(temp_path, path) then
        os.remove(temp_path)
        return nil, 0, "write_failed"
    end
    return path, #cards
end

-- Update image_path on an already-saved card (called after async generation).
-- target may be a card table, so delayed work follows its generation identity
-- instead of a phrase that may have been edited or regenerated.
function CardStorage.update_image_path(target, path)
    local entries = load_raw()
    local e = find_entry(entries, target)
    if e then
        if not ensure_entry_identity(entries, e, target) then return false end
        e.image_path = path
        return save_raw(entries)
    end
    return false
end

-- Update _audio_url on an already-saved card (called after async polling).
function CardStorage.update_audio_url(target, url)
    local entries = load_raw()
    local e = find_entry(entries, target)
    if e then
        if not ensure_entry_identity(entries, e, target) then return false end
        e._audio_url = url
        return save_raw(entries)
    end
    return false
end

-- Update editable fields of an already-saved card (matched by original phrase
-- or stable identity). Does not touch book metadata, image_path, date or sent_to_anki.
function CardStorage.update_card(target, new_card)
    local entries = load_raw()
    local e = find_entry(entries, target)
    if e then
        if not ensure_entry_identity(entries, e, target) then return false end
        e.phrase       = new_card.phrase       or ""
        e.ipa          = new_card.ipa          or ""
        e.definition   = new_card.definition   or ""
        e.synonyms     = new_card.synonyms     or ""
        e.text         = new_card.text         or ""
        e.source       = new_card.source       or ""
        e.image_prompt = new_card.image_prompt or e.image_prompt or ""
        e.updated_at   = os.time()
        if not save_raw(entries) then return false end
        new_card._storage_id = e._storage_id
        new_card.sent_to_anki = e.sent_to_anki
        return true
    end
    return false
end

-- Replace a saved card after a full regeneration. The replacement deliberately
-- gets a new identity so delayed image/audio callbacks for the previous
-- generation cannot overwrite it. Local metadata and Anki send state survive.
function CardStorage.replace_card(target, new_card)
    local entries = load_raw()
    local e = find_entry(entries, target)
    if not e then return false, "not_saved" end
    if not ensure_entry_identity(entries, e, target) then return false, "write_failed" end

    local sent_to_anki = e.sent_to_anki
    local date = e.date
    e._storage_id     = new_storage_id(entries)
    e.phrase          = new_card.phrase          or ""
    e.ipa             = new_card.ipa             or ""
    e.definition      = new_card.definition      or ""
    e.synonyms        = new_card.synonyms        or ""
    e.text            = new_card.text            or ""
    e.source          = new_card.source          or ""
    e.book_title      = new_card.book_title      or e.book_title or ""
    e.book_author     = new_card.book_author     or e.book_author or ""
    e.image_path      = new_card.image_path      or ""
    e.image_prompt    = new_card.image_prompt    or ""
    e._audio_url      = new_card._audio_url      or ""
    e._ankivocab_word = new_card._ankivocab_word or ""
    e.highlight_pos0  = new_card.highlight_pos0 ~= nil and new_card.highlight_pos0 or e.highlight_pos0
    e.highlight_pos1  = new_card.highlight_pos1 ~= nil and new_card.highlight_pos1 or e.highlight_pos1
    e.date            = date
    e.updated_at      = os.time()
    e.sent_to_anki    = sent_to_anki
    if not save_raw(entries) then return false, "write_failed" end
    new_card._storage_id = e._storage_id
    new_card.sent_to_anki = sent_to_anki
    return true
end

-- Remove card by 1-based index. Persist the revised list before deleting its
-- image so a failed write cannot leave a saved card pointing at a missing asset.
function CardStorage.delete_card(idx)
    local entries = load_raw()
    local card    = entries[idx]
    if not card then return false, "not_saved" end

    table.remove(entries, idx)
    if not save_raw(entries) then return false, "write_failed" end

    if card.image_path and card.image_path ~= "" then
        os.remove(card.image_path)
    end
    return true
end

-- Empty the entire card list and delete all associated image files. Persist the
-- empty list first so a write failure leaves every saved record and asset intact.
function CardStorage.clear_all()
    local entries = load_raw()
    if not save_raw({}) then return false, "write_failed" end

    for _, card in ipairs(entries) do
        if card.image_path and card.image_path ~= "" then
            os.remove(card.image_path)
        end
    end
    return true
end

-- Find and return a saved card by phrase (case-insensitive, trimmed).
-- Returns the card table or nil.
function CardStorage.find_by_phrase(phrase)
    local key     = normalize(phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            return e
        end
    end
    return nil
end

-- Find a saved card by phrase with fuzzy stem matching.
-- Tries exact (normalized) match first, then falls back to stem comparison.
-- Returns the card table or nil.
function CardStorage.find_by_phrase_fuzzy(phrase)
    local exact = CardStorage.find_by_phrase(phrase)
    if exact then return exact end
    local key     = stem(phrase)
    if key == "" then return nil end
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if stem(e.phrase) == key then
            return e
        end
    end
    return nil
end

-- Find a saved card by highlight position.
-- Returns the card table or nil.
function CardStorage.find_by_position(pos0, pos1)
    if not pos0 then return nil end
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if e.highlight_pos0 == pos0 then
            return e
        end
    end
    return nil
end

-- Returns true if phrase is already saved (case-insensitive, trimmed).
function CardStorage.is_saved(phrase)
    local key     = normalize(phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            return true
        end
    end
    return false
end

-- Mark a phrase as sent to Anki.
function CardStorage.mark_sent(phrase)
    local key     = normalize(phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            e.sent_to_anki = true
            return save_raw(entries)
        end
    end
    return false
end

-- Persist Anki connection settings (override configuration.lua at runtime).
function CardStorage.save_anki_settings(settings)
    local f = io.open(SETTINGS_FILE, "w")
    if not f then return false end
    local ok, encoded = pcall(json.encode, settings)
    if not ok then f:close(); return false end
    f:write(encoded)
    f:close()
    return true
end

-- Load saved Anki settings. Returns a table or nil if not yet set.
function CardStorage.load_anki_settings()
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then return data end
    return nil
end

return CardStorage
