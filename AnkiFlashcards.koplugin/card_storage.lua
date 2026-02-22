-- Local storage for Anki flashcards.
-- Follows the same pattern as vocab_builder.lua from AI_Dictionary.

local DataStorage = require("datastorage")
local json        = require("json")

local CARDS_FILE    = DataStorage:getDataDir() .. "/anki_flashcards.json"
local SETTINGS_FILE = DataStorage:getDataDir() .. "/anki_flashcards_settings.json"

local CardStorage = {}

local function normalize(phrase)
    return (phrase or ""):lower():match("^%s*(.-)%s*$")
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
    local f = io.open(CARDS_FILE, "w")
    if not f then return false end
    local ok, encoded = pcall(json.encode, entries)
    if not ok then f:close(); return false end
    f:write(encoded)
    f:close()
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
    table.insert(entries, {
        phrase      = card.phrase      or "",
        ipa         = card.ipa         or "",
        definition  = card.definition  or "",
        synonyms    = card.synonyms    or "",
        text        = card.text        or "",
        source      = card.source      or "",
        book_title  = card.book_title  or "",
        book_author = card.book_author or "",
        date        = os.date("%Y-%m-%d"),
        sent_to_anki = false,
    })
    save_raw(entries)
    return true
end

-- Returns the full list of saved cards.
function CardStorage.load_cards()
    return load_raw()
end

-- Remove card by 1-based index.
function CardStorage.delete_card(idx)
    local entries = load_raw()
    table.remove(entries, idx)
    save_raw(entries)
end

-- Empty the entire card list.
function CardStorage.clear_all()
    save_raw({})
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
            break
        end
    end
    save_raw(entries)
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
