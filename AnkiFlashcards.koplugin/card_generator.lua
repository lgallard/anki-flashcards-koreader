-- AI flashcard generator — makes a single non-streaming LLM call and
-- returns a structured card table.
--
-- Supported text providers (config.text_provider):
--   dashscope  (default) — Qwen via DashScope (OpenAI-compatible)
--   gemini               — Google Gemini Flash
--   openrouter           — OpenRouter gateway (any model)
--   openai               — OpenAI (GPT-4o-mini, GPT-4o, etc.)
--   ankivocab            — AnkiVocab Gateway (server-side generation)

local https  = require("ssl.https")
local http   = require("socket.http")
local ltn12  = require("ltn12")
local json   = require("json")

local TIMEOUT = 20
https.TIMEOUT = TIMEOUT
http.TIMEOUT  = TIMEOUT

local CardGenerator = {}

-- ── Shared LLM helper ────────────────────────────────────────────────────

local GEMINI_BASE_URL =
    "https://generativelanguage.googleapis.com/v1beta/models/"

-- Send a prompt to the configured LLM provider and return the text response.
-- Returns (text, nil) or (nil, error_string).
local function call_llm(config, prompt)
    local provider = config.text_provider or "dashscope"
    local response_body = {}

    if provider == "gemini" then
        local api_key = config.gemini_api_key
        if not api_key or api_key == "" then
            return nil, "Gemini API key not configured"
        end
        local model = config.gemini_text_model or "gemini-2.5-flash"
        local url = GEMINI_BASE_URL .. model .. ":generateContent?key=" .. api_key
        local body = json.encode({
            contents = {{ parts = {{ text = prompt }} }},
        })
        https.TIMEOUT = TIMEOUT
        local _, code = https.request {
            url     = url,
            method  = "POST",
            headers = {
                ["Content-Type"]  = "application/json",
                ["Content-Length"] = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink   = ltn12.sink.table(response_body),
        }
        if tostring(code) ~= "200" then
            local detail = table.concat(response_body):sub(1, 300)
            return nil, "HTTP " .. tostring(code) .. ": " .. detail
        end
        local ok, data = pcall(json.decode, table.concat(response_body))
        if not ok or not data then return nil, "JSON decode error" end
        if data.candidates and data.candidates[1]
           and data.candidates[1].content
           and data.candidates[1].content.parts then
            for _i, part in ipairs(data.candidates[1].content.parts) do
                if part.text then return part.text end
            end
        end
        return nil, "No text in Gemini response"
    else
        -- DashScope / OpenRouter / OpenAI / OpenAI-compatible
        local api_key, endpoint, model
        if provider == "openai" then
            api_key  = config.openai_api_key or ""
            endpoint = "https://api.openai.com/v1/chat/completions"
            model    = config.openai_model or "gpt-4o-mini"
        elseif provider == "openrouter" then
            api_key  = config.openrouter_api_key or ""
            endpoint = "https://openrouter.ai/api/v1/chat/completions"
            model    = config.openrouter_model or "anthropic/claude-3-haiku"
        else
            api_key  = config.dashscope_api_key or config.api_key or ""
            endpoint = config.provider or ""
            model    = config.model or "qwen-plus"
        end
        if api_key == "" then return nil, "API key not configured" end
        if endpoint == "" then
            endpoint = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
        end
        local body = json.encode({
            model    = model,
            messages = {{ role = "user", content = prompt }},
        })
        https.TIMEOUT = TIMEOUT
        local _, code = https.request {
            url     = endpoint,
            method  = "POST",
            headers = {
                ["Content-Type"]  = "application/json",
                ["Authorization"] = "Bearer " .. api_key,
                ["Content-Length"] = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink   = ltn12.sink.table(response_body),
        }
        if tostring(code) ~= "200" then
            local detail = table.concat(response_body):sub(1, 300)
            return nil, "HTTP " .. tostring(code) .. ": " .. detail
        end
        local ok, decoded = pcall(json.decode, table.concat(response_body))
        if ok and decoded
           and decoded.choices
           and decoded.choices[1]
           and decoded.choices[1].message then
            return decoded.choices[1].message.content
        end
        return nil, "Unexpected API response format"
    end
end

-- ── Prompt templates ──────────────────────────────────────────────────────

-- Single-call prompt: returns raw JSON, no markdown fences.
-- {language} is replaced at call time with config.target_language.
local PROMPT_TEMPLATE = [[You are a {language} flashcard generator for an advanced learner reading "{title}" by "{author}".
Highlighted: "{phrase}"
Context: "...{context}..."

IMPORTANT: The highlighted text "{phrase}" is your PRIMARY input. Generate a card for THIS phrase only.
Do NOT extract a different word or expression from the Context — it is provided ONLY to help you
understand the meaning of the highlighted text.

Return ONLY a valid JSON object, no other text:
{
  "phrase": "<canonical form of EXACTLY the highlighted text, all lowercase: (1) use infinitive/base form — e.g. 'cranked up' → 'crank up'; (2) replace specific pronouns with generic equivalents as appropriate; NEVER substitute a different phrase from the context>",
  "ipa": "<pronunciation notation for the canonical phrase — use IPA for European languages, pinyin for Mandarin, romaji for Japanese, or the standard phonetic notation for {language}>",
  "definition": "<context-aware definition using simple everyday {language} words, max 20 words; the definition itself must NOT contain difficult or rare vocabulary>",
  "synonyms": "<up to 3 common, high-frequency synonyms in {language} for the canonical phrase, comma-separated; avoid rare or literary words>",
  "text": "<SHORT example sentence in {language} (max 15 words) at intermediate level: use simple grammar and everyday vocabulary — the highlighted phrase must be the ONLY challenging word; create a FRESH scenario completely unrelated to the book — do NOT borrow wording, subjects, or settings from the Context; invent new characters and a new situation; conjugate the phrase NATURALLY to fit the sentence grammar (correct tense, person, number); {{c1::...}} must wrap ONLY the phrase as it naturally appears in this sentence — it MAY differ from the canonical form above; do NOT force the neutralized/canonical form into the sentence; no extra words around it inside the cloze>",
  "image_prompt": "<vivid scene description from the example sentence above, suitable for anime-style illustration, widescreen 16:9, no text or words in the scene>"
}]]

-- Sentence-only regeneration prompt: returns text (cloze) + image_prompt.
local TEXT_REGEN_PROMPT = [[You are a {language} flashcard generator.
Phrase: "{phrase}"

Return ONLY a valid JSON object, no other text:
{
  "text": "<SHORT example sentence in {language} (max 15 words) at intermediate level: use simple grammar and everyday vocabulary — the phrase must be the ONLY challenging word; create a FRESH scenario — invent new characters and a new situation; conjugate the phrase NATURALLY to fit the sentence grammar (correct tense, person, number); {{c1::...}} must wrap ONLY the phrase as it naturally appears in this sentence — it MAY differ from the canonical form above; do NOT force the neutralized/canonical form into the sentence; no extra words around it inside the cloze>",
  "image_prompt": "<vivid scene description from the example sentence above, suitable for anime-style illustration, widescreen 16:9, no text or words in the scene>"
}]]

-- ── Helpers ───────────────────────────────────────────────────────────────

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

-- ── AnkiVocab Gateway provider ────────────────────────────────────────────

-- Call the AnkiVocab API to generate a card server-side.
-- Returns (card_table, nil) or (nil, error_string).
local function generate_ankivocab(config, phrase, context, title, author)
    local api_url = config.ankivocab_url
    if not api_url or api_url == "" then
        return nil, "AnkiVocab URL not configured"
    end
    local api_key = config.ankivocab_api_key
    if not api_key or api_key == "" then
        return nil, "AnkiVocab API key not configured"
    end

    -- Strip trailing slash from URL.
    api_url = api_url:gsub("/$", "")
    local endpoint = api_url .. "/v1/cards/generate"

    local lang = config.target_language or "English"
    -- Map language name to ISO code for target_lang.
    local lang_codes = {
        english = "en", spanish = "es", french = "fr", german = "de",
        italian = "it", portuguese = "pt", chinese = "zh", japanese = "ja",
        korean = "ko", russian = "ru", arabic = "ar", dutch = "nl",
        swedish = "sv", turkish = "tr", polish = "pl",
    }
    local target_lang = lang_codes[lang:lower()] or "en"

    local include_image = config.image_provider == "ankivocab"
    local include_audio = config.tts_enabled or false

    local body = json.encode({
        word          = phrase,
        context       = context,
        target_lang   = target_lang,
        include_image = include_image,
        include_audio = include_audio,
    })

    local response_body = {}
    local requester = endpoint:find("^https") and https or http
    requester.TIMEOUT = 60
    local _, code = requester.request {
        url     = endpoint,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["X-API-Key"]      = api_key,
            ["Content-Length"]  = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(response_body),
    }

    if tostring(code) ~= "200" then
        local detail = table.concat(response_body):sub(1, 300)
        return nil, "AnkiVocab HTTP " .. tostring(code) .. ": " .. detail
    end

    local ok, data = pcall(json.decode, table.concat(response_body))
    if not ok or not data then return nil, "AnkiVocab JSON decode error" end

    -- Map API response fields to plugin card format.
    local card = {
        phrase       = data.phrase or phrase:lower(),
        ipa          = data.ipa or "",
        definition   = data.definition or "",
        synonyms     = data.synonyms or "",
        text         = data.text_cloze or "",
        image_prompt = data.image_prompt or "",
        source       = data.source or "",
        -- Media URLs for later download by image/audio generators.
        _image_url   = data.image_url,
        _audio_url   = data.audio_url,
    }

    return card
end

-- ── Public API ────────────────────────────────────────────────────────────

-- Generate a flashcard. Returns (card_table, nil) or (nil, error_string).
-- card_table fields: phrase, ipa, definition, synonyms, text
-- source/book_title/book_author are added by main.lua.
function CardGenerator.generate(config, phrase, context, title, author)
    -- AnkiVocab gateway: delegate entire generation to the server.
    local provider = config.text_provider or "dashscope"
    if provider == "ankivocab" then
        return generate_ankivocab(config, phrase, context, title, author)
    end

    -- Use function-form replacement to prevent % in values being treated as
    -- gsub pattern specials (e.g. book text containing "100%").
    local lang = config.target_language or "English"
    local t = escape_for_prompt(title   or "Unknown")
    local a = escape_for_prompt(author  or "Unknown")
    local p = escape_for_prompt(phrase  or "")
    local c = escape_for_prompt(context or "")
    local prompt = PROMPT_TEMPLATE
        :gsub("{language}", function() return lang end)
        :gsub("{title}",    function() return t end)
        :gsub("{author}",   function() return a end)
        :gsub("{phrase}",   function() return p end)
        :gsub("{context}",  function() return c end)

    local raw_text, err = call_llm(config, prompt)
    if not raw_text then return nil, err end
    return parse_response(raw_text)
end

-- Regenerate only the example sentence and image prompt for a phrase.
-- Returns (text, image_prompt) or (nil, error_string).
function CardGenerator.generate_text(config, phrase)
    local lang = config.target_language or "English"
    local p = escape_for_prompt(phrase or "")
    local prompt = TEXT_REGEN_PROMPT
        :gsub("{language}", function() return lang end)
        :gsub("{phrase}",   function() return p end)

    local raw_text, err = call_llm(config, prompt)
    if not raw_text then return nil, err end
    local card = parse_response(raw_text)
    if card then
        return card.text, card.image_prompt
    end
    return nil, "Unexpected API response"
end

-- Generate pronunciation only for a given phrase. Returns (string, nil) or (nil, error).
function CardGenerator.generate_ipa(config, phrase)
    local lang = config.target_language or "English"
    local prompt = 'Return ONLY the pronunciation notation for the '
                   .. lang .. ' phrase: "' .. (phrase or "")
                   .. '"\nUse IPA for European languages, pinyin for Mandarin, '
                   .. 'romaji for Japanese, or the standard notation for ' .. lang
                   .. '.\nReply with just the notation, nothing else. Example: /ɪɡˈzæmpəl/'

    local raw_text, err = call_llm(config, prompt)
    if not raw_text then return nil, err end
    return raw_text:match("^%s*(.-)%s*$")  -- trim whitespace
end

-- Quick lookup: pronunciation + short definition only (for purple highlight tap).
-- Returns ({ipa, definition}, nil) or (nil, error_string).
function CardGenerator.generate_quick_lookup(config, phrase)
    local lang = config.target_language or "English"
    local p = escape_for_prompt(phrase or "")
    local prompt = 'You are a ' .. lang .. ' dictionary. Return ONLY valid JSON for: "' .. p .. '"\n'
                .. '{"ipa": "<pronunciation notation — IPA for European languages, '
                .. 'pinyin for Mandarin, romaji for Japanese, or standard for ' .. lang .. '>", '
                .. '"definition": "<simple, clear definition in everyday ' .. lang .. ', max 15 words>"}'

    local raw_text, err = call_llm(config, prompt)
    if not raw_text then return nil, err end
    local result = parse_response(raw_text)
    if result and result.ipa and result.definition then
        return result
    end
    return nil, "Unexpected API response"
end

return CardGenerator
