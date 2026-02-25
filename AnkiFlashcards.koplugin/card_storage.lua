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
        image_path  = card.image_path  or "",
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

-- Update image_path on an already-saved card (called after async generation).
function CardStorage.update_image_path(phrase, path)
    local key     = normalize(phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            e.image_path = path
            save_raw(entries)
            return true
        end
    end
    return false
end

-- Update editable fields of an already-saved card (matched by original phrase).
-- Does not touch book metadata, image_path, date or sent_to_anki.
function CardStorage.update_card(original_phrase, new_card)
    local key     = normalize(original_phrase)
    local entries = load_raw()
    for _, e in ipairs(entries) do
        if normalize(e.phrase) == key then
            e.phrase     = new_card.phrase     or ""
            e.ipa        = new_card.ipa        or ""
            e.definition = new_card.definition or ""
            e.synonyms   = new_card.synonyms   or ""
            e.text       = new_card.text       or ""
            e.source     = new_card.source     or ""
            save_raw(entries)
            return true
        end
    end
    return false
end

-- Remove card by 1-based index; also deletes its image file if present.
function CardStorage.delete_card(idx)
    local entries = load_raw()
    local card    = entries[idx]
    if card and card.image_path and card.image_path ~= "" then
        os.remove(card.image_path)
    end
    table.remove(entries, idx)
    save_raw(entries)
end

-- Empty the entire card list and delete all associated image files.
function CardStorage.clear_all()
    local entries = load_raw()
    for _, card in ipairs(entries) do
        if card.image_path and card.image_path ~= "" then
            os.remove(card.image_path)
        end
    end
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
