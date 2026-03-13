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

IMPORTANT: The highlighted text "{phrase}" is your PRIMARY input. Generate a card for THIS phrase only.
Do NOT extract a different word or expression from the Context — it is provided ONLY to help you
understand the meaning of the highlighted text.

Return ONLY a valid JSON object, no other text:
{
  "phrase": "<canonical form of EXACTLY the highlighted text, all lowercase: (1) use infinitive/base form — e.g. 'cranked up' → 'crank up'; (2) replace specific pronouns (him, her, them, me, us, it) with 'someone' or 'something' as appropriate; NEVER substitute a different phrase from the context>",
  "ipa": "<American English IPA of the canonical phrase, e.g. /ˈwɜːrd/>",
  "definition": "<context-aware definition using simple everyday words (B2–C1 level), max 20 words; the definition itself must NOT contain difficult or rare vocabulary>",
  "synonyms": "<3-4 common, high-frequency synonyms for the canonical phrase, comma-separated; avoid rare or literary words>",
  "text": "<example sentence at B2–C1 level: use simple grammar and everyday vocabulary — the highlighted phrase must be the ONLY challenging word; create a FRESH scenario completely unrelated to the book — do NOT borrow wording, subjects, or settings from the Context; invent new characters and a new situation; conjugate the phrase NATURALLY to fit the sentence grammar (correct tense, person, number); {{c1::...}} must wrap ONLY the phrase as it naturally appears in this sentence — it MAY differ from the canonical form above (e.g. canonical 'batter someone' might appear as {{c1::battered}} in past tense); do NOT force the neutralized/canonical form into the sentence; no extra words around it inside the cloze>",
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
    -- Normalise phrase to all-lowercase.
    if type(card.phrase) == "string" then
        card.phrase = card.phrase:lower()
    end
    -- Cloze content is left as-is — the AI conjugates naturally for the sentence.
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

-- Sentence-only regeneration prompt: returns text (cloze) + image_prompt.
local TEXT_REGEN_PROMPT = [[You are an English flashcard generator.
Phrase: "{phrase}"

Return ONLY a valid JSON object, no other text:
{
  "text": "<example sentence at B2–C1 level: use simple grammar and everyday vocabulary — the phrase must be the ONLY challenging word; create a FRESH scenario — invent new characters and a new situation; conjugate the phrase NATURALLY to fit the sentence grammar (correct tense, person, number); {{c1::...}} must wrap ONLY the phrase as it naturally appears in this sentence — it MAY differ from the canonical form above (e.g. canonical 'batter someone' might appear as {{c1::battered}} in past tense); do NOT force the neutralized/canonical form into the sentence; no extra words around it inside the cloze>",
  "image_prompt": "<vivid scene description from the example sentence above, suitable for anime-style illustration, widescreen 16:9, no text or words in the scene>"
}]]

-- Regenerate only the example sentence and image prompt for a phrase.
-- Returns (text, image_prompt) or (nil, error_string).
function CardGenerator.generate_text(config, phrase)
    local api_key = config and (config.dashscope_api_key or config.api_key) or ""
    if api_key == "" then return nil, "API key not configured" end

    local p = escape_for_prompt(phrase or "")
    local prompt = TEXT_REGEN_PROMPT
        :gsub("{phrase}", function() return p end)

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
        return nil, "HTTP " .. tostring(code)
    end

    local ok2, decoded = pcall(json.decode, table.concat(response_body))
    if ok2 and decoded
       and decoded.choices
       and decoded.choices[1]
       and decoded.choices[1].message then
        local card = parse_response(decoded.choices[1].message.content)
        if card then
            return card.text, card.image_prompt
        end
    end
    return nil, "Unexpected API response"
end

-- Generate IPA only for a given phrase. Returns (ipa_string, nil) or (nil, error).
function CardGenerator.generate_ipa(config, phrase)
    local api_key = config and (config.dashscope_api_key or config.api_key) or ""
    if api_key == "" then return nil, "API key not configured" end

    local prompt = 'Return ONLY the American English IPA for: "'
                   .. (phrase or "")
                   .. '"\nReply with just the IPA notation, nothing else. Example: /ɪɡˈzæmpəl/'

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
        return nil, "HTTP " .. tostring(code)
    end

    local ok2, decoded = pcall(json.decode, table.concat(response_body))
    if ok2 and decoded
       and decoded.choices
       and decoded.choices[1]
       and decoded.choices[1].message then
        local ipa = decoded.choices[1].message.content
        if ipa then
            return ipa:match("^%s*(.-)%s*$")  -- trim whitespace
        end
    end
    return nil, "Unexpected API response"
end

-- Quick lookup: IPA + short definition only (for purple highlight tap).
-- Returns ({ipa, definition}, nil) or (nil, error_string).
function CardGenerator.generate_quick_lookup(config, phrase)
    local api_key = config and (config.dashscope_api_key or config.api_key) or ""
    if api_key == "" then return nil, "API key not configured" end

    local p = escape_for_prompt(phrase or "")
    local prompt = 'You are an English dictionary. Return ONLY valid JSON for: "' .. p .. '"\n'
                .. '{"ipa": "<American English IPA, e.g. /ɪɡˈzæmpəl/>", '
                .. '"definition": "<simple, clear definition in everyday English, max 15 words>"}'

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
        return nil, "HTTP " .. tostring(code)
    end

    local ok2, decoded = pcall(json.decode, table.concat(response_body))
    if ok2 and decoded
       and decoded.choices
       and decoded.choices[1]
       and decoded.choices[1].message then
        local result = parse_response(decoded.choices[1].message.content)
        if result and result.ipa and result.definition then
            return result
        end
    end
    return nil, "Unexpected API response"
end

return CardGenerator
