-- AI flashcard generator — makes a single non-streaming call to Qwen via DashScope
-- and returns a structured card table.

local https  = require("ssl.https")
local http   = require("socket.http")
local ltn12  = require("ltn12")
local json   = require("json")

local TIMEOUT = 20
https.TIMEOUT = TIMEOUT
http.TIMEOUT  = TIMEOUT

local CardGenerator = {}

-- Single-call prompt: returns raw JSON, no markdown fences.
local PROMPT_TEMPLATE = [[You are an English flashcard generator for an advanced learner reading "{title}" by "{author}".
Highlighted: "{phrase}"
Context: "...{context}..."

Return ONLY a valid JSON object, no other text:
{
  "phrase": "<phrase as highlighted, title-cased if a single word>",
  "ipa": "<American English IPA transcription, e.g. /ˈwɜːrd/>",
  "definition": "<context-aware definition, max 20 words>",
  "synonyms": "<3-4 synonyms, comma-separated>",
  "text": "<natural example sentence using the phrase in the SAME meaning but different situation, with {{c1::phrase}} wrapping the key word>",
  "image_prompt": "<vivid scene description from the example sentence above, suitable for anime-style illustration, widescreen 16:9, no text or words in the scene>"
}]]

local function escape_for_prompt(s)
    if not s then return "" end
    return s:gsub('"', '\\"')
end

local function parse_response(raw)
    if not raw then return nil, "empty response" end
    -- Strip markdown fences if present
    local s = raw:gsub("```json%s*", ""):gsub("```%s*", "")
    -- Extract the outermost {...} block
    local block = s:match("(%b{})")
    if not block then return nil, "No JSON object found in response" end
    local ok, card = pcall(json.decode, block)
    if not ok then return nil, "JSON parse failed: " .. tostring(card) end
    if type(card) ~= "table" then return nil, "Decoded value is not a table" end
    return card
end

-- Generate a flashcard. Returns (card_table, nil) or (nil, error_string).
-- card_table fields: phrase, ipa, definition, synonyms, text
-- source/book_title/book_author are added by main.lua.
function CardGenerator.generate(config, phrase, context, title, author)
    local api_key = config and (config.dashscope_api_key or config.api_key) or ""
    if api_key == "" then
        return nil, "API key not configured"
    end

    -- Use function-form replacement to prevent % in values being treated as
    -- gsub pattern specials (e.g. book text containing "100%").
    local t = escape_for_prompt(title   or "Unknown")
    local a = escape_for_prompt(author  or "Unknown")
    local p = escape_for_prompt(phrase  or "")
    local c = escape_for_prompt(context or "")
    local prompt = PROMPT_TEMPLATE
        :gsub("{title}",   function() return t end)
        :gsub("{author}",  function() return a end)
        :gsub("{phrase}",  function() return p end)
        :gsub("{context}", function() return c end)

    local request_body = json.encode({
        model    = config.model or "qwen-plus",
        messages = {{ role = "user", content = prompt }},
    })

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
    }

    local provider = config.provider
    if not provider or provider == "" then
        provider = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
    end

    local response_body = {}
    local ok, code = https.request {
        url     = provider,
        method  = "POST",
        headers = headers,
        source  = ltn12.source.string(request_body),
        sink    = ltn12.sink.table(response_body),
    }

    if tostring(code) ~= "200" then
        local err_body = table.concat(response_body)
        return nil, "HTTP " .. tostring(code) .. ": " .. err_body:sub(1, 300)
    end

    local raw_text
    local ok2, decoded = pcall(json.decode, table.concat(response_body))
    if ok2 and decoded
       and decoded.choices
       and decoded.choices[1]
       and decoded.choices[1].message then
        raw_text = decoded.choices[1].message.content
    end

    if not raw_text then
        return nil, "Unexpected API response format"
    end

    return parse_response(raw_text)
end

return CardGenerator
