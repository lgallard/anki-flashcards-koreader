-- AI flashcard generator — makes a single non-streaming LLM call and
-- returns a structured card table.
--
-- Supported text providers (config.text_provider):
--   dashscope  (default) — Qwen via DashScope (OpenAI-compatible)
--   gemini               — Google Gemini Flash
--   openrouter           — OpenRouter gateway (any model)

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
        -- DashScope / OpenRouter / OpenAI-compatible
        local api_key, endpoint, model
        if provider == "openrouter" then
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

-- Sentence-only regeneration prompt: returns text (cloze) + image_prompt.
local TEXT_REGEN_PROMPT = [[You are an English flashcard generator.
Phrase: "{phrase}"

Return ONLY a valid JSON object, no other text:
{
  "text": "<example sentence at B2–C1 level: use simple grammar and everyday vocabulary — the phrase must be the ONLY challenging word; create a FRESH scenario — invent new characters and a new situation; conjugate the phrase NATURALLY to fit the sentence grammar (correct tense, person, number); {{c1::...}} must wrap ONLY the phrase as it naturally appears in this sentence — it MAY differ from the canonical form above (e.g. canonical 'batter someone' might appear as {{c1::battered}} in past tense); do NOT force the neutralized/canonical form into the sentence; no extra words around it inside the cloze>",
  "image_prompt": "<vivid scene description from the example sentence above, suitable for anime-style illustration, widescreen 16:9, no text or words in the scene>"
}]]

-- ── Offline dictionary fallback ───────────────────────────────────────────

-- Look up a word in KOReader's installed StarDict dictionaries via sdcv.
-- Returns {definition, dict} or nil.
local function dictionary_lookup(word)
    if not word or word == "" then return nil end
    -- Shell-safe: single quotes with inner quotes escaped.
    local safe = word:gsub("'", "'\\''")
    local dict_dir = os.getenv("STARDICT_DATA_DIR") or "data/dict"
    local handle = io.popen("./sdcv --json-output --utf8-input --exact-search"
                            .. " --data-dir '" .. dict_dir .. "'"
                            .. " '" .. safe .. "' 2>/dev/null")
    if not handle then return nil end
    local output = handle:read("*a")
    handle:close()
    if not output or output == "" then return nil end
    local ok, results = pcall(json.decode, output)
    if not ok or type(results) ~= "table" then return nil end
    for _i, entry in ipairs(results) do
        if entry.definition and entry.definition ~= "" then
            -- Strip HTML tags for plain-text display.
            local def = entry.definition:gsub("<[^>]+>", "")
            -- Collapse whitespace and trim.
            def = def:gsub("%s+", " "):match("^%s*(.-)%s*$")
            if def ~= "" then
                return { definition = def, dict = entry.dict or "" }
            end
        end
    end
    return nil
end

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

-- ── Public API ────────────────────────────────────────────────────────────

-- Generate a flashcard. Returns (card_table, nil) or (nil, error_string).
-- card_table fields: phrase, ipa, definition, synonyms, text
-- source/book_title/book_author are added by main.lua.
function CardGenerator.generate(config, phrase, context, title, author)
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

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        -- Offline — try local dictionary for a partial card.
        local entry = dictionary_lookup(phrase)
        if entry then
            return {
                phrase     = (phrase or ""):lower(),
                ipa        = "",
                definition = entry.definition,
                synonyms   = "",
                text       = "",
            }
        end
        return nil, "Offline — no local dictionary entry found"
    end

    local raw_text, err = call_llm(config, prompt)
    if not raw_text then return nil, err end
    return parse_response(raw_text)
end

-- Regenerate only the example sentence and image prompt for a phrase.
-- Returns (text, image_prompt) or (nil, error_string).
function CardGenerator.generate_text(config, phrase)
    local p = escape_for_prompt(phrase or "")
    local prompt = TEXT_REGEN_PROMPT
        :gsub("{phrase}", function() return p end)

    local raw_text, err = call_llm(config, prompt)
    if not raw_text then return nil, err end
    local card = parse_response(raw_text)
    if card then
        return card.text, card.image_prompt
    end
    return nil, "Unexpected API response"
end

-- Generate IPA only for a given phrase. Returns (ipa_string, nil) or (nil, error).
function CardGenerator.generate_ipa(config, phrase)
    local prompt = 'Return ONLY the American English IPA for: "'
                   .. (phrase or "")
                   .. '"\nReply with just the IPA notation, nothing else. Example: /ɪɡˈzæmpəl/'

    local raw_text, err = call_llm(config, prompt)
    if not raw_text then return nil, err end
    return raw_text:match("^%s*(.-)%s*$")  -- trim whitespace
end

-- Quick lookup: IPA + short definition only (for purple highlight tap).
-- Falls back to local StarDict dictionaries when offline or on LLM failure.
-- Returns ({ipa, definition}, nil) or (nil, error_string).
function CardGenerator.generate_quick_lookup(config, phrase)
    local NetworkMgr = require("ui/network/manager")

    -- If online, try the LLM first.
    if NetworkMgr:isOnline() then
        local p = escape_for_prompt(phrase or "")
        local prompt = 'You are an English dictionary. Return ONLY valid JSON for: "' .. p .. '"\n'
                    .. '{"ipa": "<American English IPA, e.g. /ɪɡˈzæmpəl/>", '
                    .. '"definition": "<simple, clear definition in everyday English, max 15 words>"}'
        local raw_text = call_llm(config, prompt)
        if raw_text then
            local result = parse_response(raw_text)
            if result and result.ipa and result.definition then
                return result
            end
        end
    end

    -- Offline or LLM failed — fall back to local dictionary.
    local entry = dictionary_lookup(phrase)
    if entry then
        return { ipa = "", definition = entry.definition }
    end
    return nil, NetworkMgr:isOnline()
        and "No definition found"
        or  "Offline — no local dictionary entry found"
end

return CardGenerator
