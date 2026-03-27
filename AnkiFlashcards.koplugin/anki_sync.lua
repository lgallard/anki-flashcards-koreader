-- AnkiConnect HTTP client.
-- Uses socket.http + ltn12, bundled in KOReader.
-- The AnkiConnect URL must be the LAN IP of the device running Anki (e.g. http://192.168.x.x:8765),
-- not localhost — the Kobo cannot reach the host via localhost.

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

-- Build the Anki deck name for a card.
-- Uses English::<book_title> when book_title is present, preserving the
-- top-level deck configured by the user (e.g. "English" from "English::Koreader").
-- Falls back to config.deck or "English::Koreader" when no title is available.
local function build_deck_name(config, card)
    local base = (config and config.deck and config.deck ~= "")
                 and config.deck or "English::Koreader"
    local title = card and card.book_title and card.book_title ~= "" and card.book_title
    if not title then return base end
    -- Replace colons (Anki hierarchy separator) and trim.
    local safe = title:gsub(":", " -"):match("^%s*(.-)%s*$")
    if safe == "" then return base end
    -- Derive the top-level deck (everything before the first "::").
    local parent = base:match("^([^:]+)") or base
    return parent .. "::" .. safe
end

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
        local reason = tostring(code)
        if reason == "timeout" or reason:find("unreachable") or reason:find("refused") then
            return nil, "Cannot reach Anki. Check URL in Anki Settings."
        end
        return nil, "HTTP error: " .. reason
    end
    local ok2, result = pcall(json.decode, table.concat(response))
    if not ok2 then return nil, "JSON decode error" end
    return result
end

-- Store a media file in Anki's media folder. Returns stored filename or nil + err.
local function store_media_file(url, filename, b64_data)
    local result, err = post(url, "storeMediaFile", {
        filename = filename,
        data     = b64_data,
    })
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    return result.result or filename
end

-- Check that AnkiConnect is reachable. Returns true or nil + error.
function AnkiSync.test_connection(url)
    local result, err = post(url, "requestPermission", {})
    if not result then return nil, err end
    return true
end

-- Send a full flashcard to Anki.
-- config:     { url, deck, model, tags, tts_enabled, elevenlabs_voice_id }
-- card:       { phrase, ipa, definition, synonyms, text, source }
-- tts_config: full CONFIGURATION table (optional — provides elevenlabs_api_key)
-- Returns true or nil + error string.
function AnkiSync.send_card(config, card, tts_config)
    if not config or not config.url or config.url == "" then
        return nil, "Anki URL not configured"
    end

    local model = config.model or "Vocabulary"

    local fields = {
        ["Phrase"]     = card.phrase     or "",
        ["IPA"]        = card.ipa        or "",
        ["Definition"] = card.definition or "",
        ["Synonyms"]   = card.synonyms   or "",
        ["Text"]       = card.text       or "",
        ["Source"]     = card.source     or "",
    }

    local note = {
        deckName  = build_deck_name(config, card),
        modelName = model,
        fields    = fields,
        options   = {
            allowDuplicate = false,
            duplicateScope = "deck",
        },
        tags = config.tags or { "KOReader" },
    }

    -- Store image via storeMediaFile and reference it in ImageFront/ImageBack fields.
    if card.image_path then
        pcall(function()
            local f = io.open(card.image_path, "rb")
            if not f then return end
            local raw = f:read("*a")
            f:close()
            local b64         = base64_encode(raw)
            local phrase_slug = (card.phrase or "card"):gsub("[^%w]", "_"):lower()
            local fname       = phrase_slug .. "_" .. tostring(os.time()) .. ".png"
            local stored      = store_media_file(config.url, fname, b64)
            if stored then
                local img_ref        = '<img src="' .. stored .. '">'
                fields["ImageFront"] = img_ref
                fields["ImageBack"]  = img_ref
            end
        end)
    end

    -- Attach TTS audio.  Priority:
    --   1. Pre-downloaded bytes (card._audio_bytes)
    --   2. AnkiVocab server-generated audio (card._audio_url)
    --   3. ElevenLabs TTS fallback
    local mp3_bytes
    if card._audio_bytes then
        mp3_bytes = card._audio_bytes
    elseif type(card._audio_url) == "string" and card._audio_url ~= "" then
        pcall(function()
            local AudioGenerator = require("audio_generator")
            mp3_bytes = AudioGenerator.download_url(card._audio_url)
        end)
    end
    if not mp3_bytes then
        local tts_api_key = tts_config and tts_config.elevenlabs_api_key
        local tts_on      = (config and config.tts_enabled)
                          or (tts_config and tts_config.tts_enabled)
        if tts_on and tts_api_key and tts_api_key ~= "" then
            pcall(function()
                local AudioGenerator = require("audio_generator")
                local tts_cfg = {
                    elevenlabs_api_key  = tts_api_key,
                    elevenlabs_voice_id = config.elevenlabs_voice_id
                                          or (tts_config and tts_config.elevenlabs_voice_id),
                }
                mp3_bytes = AudioGenerator.generate(tts_cfg, card)
            end)
        end
    end
    if mp3_bytes then
        pcall(function()
            local b64         = base64_encode(mp3_bytes)
            local phrase_slug = (card.phrase or "card"):gsub("[^%w]", "_"):lower()
            local fname       = phrase_slug .. "_" .. tostring(os.time()) .. ".mp3"
            local stored      = store_media_file(config.url, fname, b64)
            if stored then
                fields["Sound"] = "[sound:" .. stored .. "]"
            end
        end)
    end

    local params = { note = note }

    local result, err = post(config.url, "addNote", params)
    if not result then return nil, err end
    if type(result.error) == "string" then return nil, result.error end
    return true
end

return AnkiSync
