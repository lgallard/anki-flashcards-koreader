-- AnkiConnect HTTP client.
-- Uses socket.http + ltn12, bundled in KOReader.
-- The AnkiConnect URL must be the Mac's LAN IP (e.g. http://192.168.x.x:8765),
-- not localhost — the Kobo cannot reach the Mac via localhost.

local http  = require("socket.http")
local ltn12 = require("ltn12")
local json  = require("json")

-- Pure-Lua base64 encoder (avoids mime streaming-filter pitfalls).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64_encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        b = b or 0; c = c or 0
        local n = a * 65536 + b * 256 + c
        out[#out+1] = B64:sub(math.floor(n/262144)%64+1, math.floor(n/262144)%64+1)
        out[#out+1] = B64:sub(math.floor(n/4096)%64+1,   math.floor(n/4096)%64+1)
        out[#out+1] = (i+1 <= #data) and B64:sub(math.floor(n/64)%64+1, math.floor(n/64)%64+1) or "="
        out[#out+1] = (i+2 <= #data) and B64:sub(n%64+1, n%64+1) or "="
    end
    return table.concat(out)
end

local TIMEOUT = 5  -- fail fast on offline/unreachable host

local AnkiSync = {}

local function post(url, action, params)
    local body     = json.encode({ action = action, version = 6, params = params or {} })
    local response = {}
    http.TIMEOUT = TIMEOUT
    local ok, code = http.request {
        url     = url,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(response),
    }
    if not ok or tostring(code) ~= "200" then
        return nil, "HTTP error: " .. tostring(code)
    end
    local ok2, result = pcall(json.decode, table.concat(response))
    if not ok2 then return nil, "JSON decode error" end
    return result
end

-- Cache first-field name per model for the session.
local first_field_cache = {}

local function get_first_field(url, model)
    if first_field_cache[model] then
        return first_field_cache[model]
    end
    local result = post(url, "modelFieldNames", { modelName = model })
    if result and result.result and result.result[1] then
        first_field_cache[model] = result.result[1]
        return result.result[1]
    end
    return nil
end

-- Check that AnkiConnect is reachable. Returns true or nil + error.
function AnkiSync.test_connection(url)
    local result, err = post(url, "requestPermission", {})
    if not result then return nil, err end
    return true
end

-- Send a full flashcard to Anki.
-- config: { url, deck, model, tags }
-- card:   { phrase, ipa, definition, synonyms, text, source }
-- Returns true or nil + error string.
function AnkiSync.send_card(config, card)
    if not config or not config.url or config.url == "" then
        return nil, "Anki URL not configured"
    end

    local model = config.model or "English"

    local fields = {
        ["Phrase"]     = card.phrase     or "",
        ["IPA"]        = card.ipa        or "",
        ["Definition"] = card.definition or "",
        ["Synonyms"]   = card.synonyms   or "",
        ["Text"]       = card.text       or "",
        ["Source"]     = card.source     or "",
    }

    -- Anki rejects notes whose first field is empty.
    -- Auto-detect the first field of the model and fill it with phrase.
    local first = get_first_field(config.url, model)
    if first and (not fields[first] or fields[first] == "") then
        fields[first] = card.phrase or ""
    end

    local note = {
        deckName  = config.deck or "English::Koreader",
        modelName = model,
        fields    = fields,
        options   = {
            allowDuplicate = false,
            duplicateScope = "deck",
        },
        tags = config.tags or { "KOReader" },
    }

    -- Attach image if available (base64-encoded for AnkiConnect).
    if card.image_path then
        pcall(function()
            local f = io.open(card.image_path, "rb")
            if not f then return end
            local raw   = f:read("*a")
            f:close()
            local b64   = base64_encode(raw)
            local fname = card.image_path:match("[^/]+$") or "card_image.png"
            note.picture = {{
                data     = b64,
                filename = fname,
                fields   = { "Image" },
            }}
        end)
    end

    local params = { note = note }

    local result, err = post(config.url, "addNote", params)
    if not result then return nil, err end
    if result.error  then return nil, result.error end
    return true
end

return AnkiSync
