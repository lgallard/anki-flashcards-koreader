-- ElevenLabs TTS audio generator.
-- Synchronous — generates MP3 bytes for a card's phrase + example sentence.
-- Returns raw MP3 data (string) for base64 encoding + AnkiConnect upload.

local https = require("ssl.https")
local http  = require("socket.http")
local ltn12 = require("ltn12")
local json  = require("json")

local BASE_URL      = "https://api.elevenlabs.io/v1/text-to-speech/"
local DEFAULT_VOICE = "JBFqnCBsd6RMkjVDRZzb"  -- Rachel
local DEFAULT_MODEL = "eleven_multilingual_v2"
local OUTPUT_FORMAT = "mp3_22050_32"
local TIMEOUT       = 10

local AudioGenerator = {}

-- Strip cloze markup: "{{c1::revealed}}" → "revealed"
local function strip_cloze(text)
    if not text then return "" end
    return (text:gsub("{{c%d+::(.-)}}", "%1"))
end

-- Download audio from a URL and return raw bytes.
-- Used when AnkiVocab API generates audio server-side.
-- Returns mp3_bytes (string) or nil, error_string.
function AudioGenerator.download_url(url)
    if not url or url == "" then
        return nil, "No audio URL"
    end
    local response = {}
    https.TIMEOUT = TIMEOUT
    local requester = url:find("^https") and https or http
    local ok, code = requester.request {
        url  = url,
        sink = ltn12.sink.table(response),
    }
    if not ok then
        return nil, "Audio download failed: " .. tostring(code)
    end
    if tostring(code) ~= "200" then
        return nil, "Audio download HTTP " .. tostring(code)
    end
    local mp3_bytes = table.concat(response)
    if #mp3_bytes == 0 then
        return nil, "Audio download returned empty data"
    end
    return mp3_bytes
end

-- Generate TTS audio for a card.
-- config: table with elevenlabs_api_key, elevenlabs_voice_id (optional)
-- card:   table with phrase, text fields
-- Returns mp3_bytes (string) or nil, error_string.
function AudioGenerator.generate(config, card)
    local api_key = config and config.elevenlabs_api_key
    if not api_key or api_key == "" or api_key == "YOUR_ELEVENLABS_API_KEY" then
        return nil, "ElevenLabs API key not configured"
    end

    local phrase = card and card.phrase or ""
    if phrase == "" then
        return nil, "No phrase to synthesize"
    end

    -- Build speech text: "phrase ... revealed cloze sentence"
    local sentence = strip_cloze(card.text or "")
    local speech_text = phrase
    if sentence ~= "" then
        speech_text = phrase .. " ... " .. sentence
    end

    local voice_id = config.elevenlabs_voice_id
    if not voice_id or voice_id == "" then
        voice_id = DEFAULT_VOICE
    end

    local url = BASE_URL .. voice_id .. "?output_format=" .. OUTPUT_FORMAT

    local body = json.encode({
        text     = speech_text,
        model_id = DEFAULT_MODEL,
    })

    local response = {}
    https.TIMEOUT = TIMEOUT
    http.TIMEOUT  = TIMEOUT

    local ok, code = https.request {
        url     = url,
        method  = "POST",
        headers = {
            ["xi-api-key"]   = api_key,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(response),
    }

    if not ok then
        return nil, "TTS request failed: " .. tostring(code)
    end
    if tostring(code) ~= "200" then
        local detail = table.concat(response):sub(1, 200)
        return nil, "TTS HTTP " .. tostring(code) .. ": " .. detail
    end

    local mp3_bytes = table.concat(response)
    if #mp3_bytes == 0 then
        return nil, "TTS returned empty audio"
    end

    return mp3_bytes
end

return AudioGenerator
