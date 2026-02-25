-- AnkiFlashcards KOReader plugin.
-- Adds two entries to the highlight dialog:
--   📖 Anki Card  — generates a full Anki flashcard via AI and shows a card viewer
--   📚 My Cards   — opens the card manager (list of saved cards)

local Device         = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr     = require("ui/network/manager")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")

local get_selection_in_context = require("selection_context")

local CardGenerator    = require("card_generator")
local CardViewer       = require("card_viewer")
local CardStorage      = require("card_storage")
local AnkiSync         = require("anki_sync")
local CardManager      = require("card_manager")
local HighlightInbox   = require("highlight_inbox")
local ImageGenerator   = require("image_generator")

local MAX_HL    = 2000
local MAX_TITLE = 100

-- Load configuration from configuration.lua; saved anki settings (from the
-- settings UI) are merged on top at startup and at send time.
local CONFIGURATION = nil
do
    local ok, conf = pcall(require, "configuration")
    if ok then CONFIGURATION = conf end
    local saved_anki = CardStorage.load_anki_settings()
    if saved_anki then
        CONFIGURATION = CONFIGURATION or {}
        CONFIGURATION.anki = saved_anki
    end
end

local AnkiFlashcards = InputContainer:new {
    name        = "ankiflashcards",
    is_doc_only = true,
}

-- Strip control chars, normalise whitespace, and truncate.
local function clean_str(s, max_len)
    if not s then return "" end
    s = s:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
    if max_len and #s > max_len then s = s:sub(1, max_len) end
    return s
end

local function capitalize_first(s)
    return (s:gsub("^%l", string.upper))
end

local function cambridge_url(phrase)
    local slug = (phrase or ""):lower():gsub("%s+", "-")
    return "https://dictionary.cambridge.org/dictionary/english/" .. slug
end

-- Safely unwrap rhi.selected_text which may be a string, a table with a
-- .text field, or a nested structure depending on the KOReader backend.
local function extract_text(sel)
    if type(sel) == "string" then return sel end
    if type(sel) ~= "table"  then return "" end
    if type(sel.text) == "string" then return sel.text end
    -- Nested spans/lines: collect string leaves
    local parts = {}
    local function collect(t)
        for _, v in ipairs(t) do
            if type(v) == "string" then
                parts[#parts + 1] = v
            elseif type(v) == "table" then
                if type(v.text) == "string" then parts[#parts + 1] = v.text end
                if v.spans    then collect(v.spans)    end
                if v.segments then collect(v.segments) end
                if v.lines    then collect(v.lines)    end
            end
        end
    end
    collect(sel)
    return table.concat(parts)
end

-- Build the effective Anki config by merging saved settings on top of
-- the config table loaded at startup.
local function get_anki_config()
    local cfg  = {}
    local base = CONFIGURATION and CONFIGURATION.anki
    if base then
        for k, v in pairs(base) do cfg[k] = v end
    end
    local fresh = CardStorage.load_anki_settings()
    if fresh then
        for k, v in pairs(fresh) do cfg[k] = v end
    end
    return cfg
end

function AnkiFlashcards:init()

    -- ── Entry 1: 📖 Anki Card ─────────────────────────────────────────────────
    self.ui.highlight:addToHighlightDialog("ankiflashcards_1", function(rhi)
        return {
            text    = _("📖 Anki Card"),
            enabled = Device:hasClipboard(),
            callback = function()
                local ui = self.ui

                -- Capture book metadata.
                local title  = clean_str(ui.document:getProps().title, MAX_TITLE)
                local author = ui.document:getProps().authors
                if type(author) == "table" then
                    author = table.concat(author, ", ")
                end
                author = clean_str(
                    (author and author ~= "") and author or "Unknown Author",
                    MAX_TITLE
                )

                -- Highlighted text and surrounding context.
                local highlighted = extract_text(rhi.selected_text or "")
                local phrase      = capitalize_first(clean_str(highlighted, MAX_HL))
                local context     = clean_str(
                    get_selection_in_context(ui.document, highlighted, 10),
                    MAX_HL
                )

                -- Source string shown in the Source field of the card.
                local source
                if title ~= "" and author ~= "" then
                    source = title .. " — " .. author
                elseif title ~= "" then
                    source = title
                else
                    source = author
                end

                ui.highlight:onClose()

                -- Show a loading notification while the AI call runs.
                local loading = Notification:new {
                    text    = _("Generating flashcard for: ") .. phrase,
                    timeout = 30,
                }
                UIManager:show(loading)

                -- Schedule the AI call so the UI can render the notification first.
                -- Retries up to 2 times on HTTP 429 (rate limit), waiting 5s between attempts.
                local function do_generate(attempts_left)
                    UIManager:close(loading)
                    local card, err = CardGenerator.generate(
                        CONFIGURATION, phrase, context, title, author
                    )
                    if not card then
                        if err and err:find("429") and attempts_left > 0 then
                            local rn = Notification:new {
                                text    = _("Rate limited — retrying in 5 s…"),
                                timeout = 6,
                            }
                            UIManager:show(rn)
                            UIManager:scheduleIn(5, function()
                                UIManager:close(rn)
                                do_generate(attempts_left - 1)
                            end)
                            return
                        end
                        UIManager:show(Notification:new {
                            text    = _("Card generation failed: ") .. (err or "unknown"),
                            timeout = 5,
                        })
                        return
                    end

                    card.source      = cambridge_url(card.phrase)
                    card.book_title  = title
                    card.book_author = author

                    -- viewer_ref[1] always holds the currently visible CardViewer.
                    local viewer_ref = {}

                    -- make_viewer creates a CardViewer for card c.
                    -- show_back=false → front (question) side.
                    local function make_viewer(c, show_back_flag)
                        local v
                        v = CardViewer:new {
                            card      = c,
                            show_back = show_back_flag or false,

                            on_show_answer = function()
                                UIManager:close(v)
                                local nv = make_viewer(c, true)
                                viewer_ref[1] = nv
                            end,

                            on_save = function()
                                local ok2, save_err = CardStorage.save_card(c)
                                if ok2 then
                                    return true
                                else
                                    local msg = (save_err == "already_saved")
                                                and _("Already saved")
                                                or  _("Could not save")
                                    return nil, msg
                                end
                            end,

                            on_send = function()
                                return AnkiSync.send_card(get_anki_config(), c)
                            end,

                            on_regenerate = function()
                                if viewer_ref[1] then
                                    UIManager:close(viewer_ref[1])
                                end
                                local loading2 = Notification:new {
                                    text    = _("Regenerating…"),
                                    timeout = 30,
                                }
                                UIManager:show(loading2)
                                UIManager:scheduleIn(0.05, function()
                                    UIManager:close(loading2)
                                    local new_card, new_err = CardGenerator.generate(
                                        CONFIGURATION, phrase, context, title, author
                                    )
                                    if not new_card then
                                        UIManager:show(Notification:new {
                                            text    = _("Regenerate failed: ") .. (new_err or "unknown"),
                                            timeout = 5,
                                        })
                                        return
                                    end
                                    new_card.source      = cambridge_url(new_card.phrase)
                                    new_card.book_title  = title
                                    new_card.book_author = author
                                    -- Regenerated card starts on front again.
                                    local nv = make_viewer(new_card, false)
                                    viewer_ref[1] = nv
                                    -- Kick off new image generation.
                                    if new_card.image_prompt then
                                        ImageGenerator.generate_async(
                                            CONFIGURATION,
                                            new_card.image_prompt,
                                            new_card.phrase,
                                            function(img_path)
                                                new_card.image_path = img_path
                                                CardStorage.update_image_path(new_card.phrase, img_path)
                                                if viewer_ref[1] then
                                                    local nv2 = viewer_ref[1]:update(new_card)
                                                    viewer_ref[1] = nv2
                                                end
                                            end,
                                            nil  -- image errors are non-fatal
                                        )
                                    end
                                end)
                            end,
                        }
                        UIManager:show(v)
                        return v
                    end

                    -- Open on the front side.
                    local initial_viewer = make_viewer(card, false)
                    viewer_ref[1] = initial_viewer

                    -- Start image generation in background.
                    if card.image_prompt then
                        ImageGenerator.generate_async(
                            CONFIGURATION,
                            card.image_prompt,
                            card.phrase,
                            function(img_path)
                                card.image_path = img_path
                                CardStorage.update_image_path(card.phrase, img_path)
                                -- Refresh whichever side is showing.
                                if viewer_ref[1] then
                                    local nv = viewer_ref[1]:update(card)
                                    viewer_ref[1] = nv
                                end
                            end,
                            nil  -- image errors are non-fatal
                        )
                    end
                end

                NetworkMgr:runWhenOnline(function()
                    UIManager:scheduleIn(0.05, function() do_generate(2) end)
                end)
            end,
        }
    end)

    -- ── Entry 2: 📚 My Cards ──────────────────────────────────────────────────
    self.ui.highlight:addToHighlightDialog("ankiflashcards_2", function(_rhi)
        return {
            text    = _("📚 My Cards"),
            enabled = true,
            callback = function()
                self.ui.highlight:onClose()
                CardManager.show(CONFIGURATION and CONFIGURATION.anki)
            end,
        }
    end)

    -- ── Entry 3: 📥 Highlight Inbox ───────────────────────────────────────────
    self.ui.highlight:addToHighlightDialog("ankiflashcards_3", function(_rhi)
        return {
            text     = _("📥 Highlight Inbox"),
            enabled  = true,
            callback = function()
                self.ui.highlight:onClose()
                HighlightInbox.show(self.ui, CONFIGURATION)
            end,
        }
    end)
end

return AnkiFlashcards
