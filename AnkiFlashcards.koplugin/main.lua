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

    -- ── Entry 4: Anki Card (primary action, registered last = bottom) ───────────
    self.ui.highlight:addToHighlightDialog("ankiflashcards_4", function(rhi)
        return {
            text    = _("Anki Card"),
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

                -- Highlighted text, position, and surrounding context.
                local sel = rhi.selected_text
                local highlighted = extract_text(sel or "")
                local phrase      = capitalize_first(clean_str(highlighted, MAX_HL))
                local highlight_pos0 = sel and sel.pos0
                local highlight_pos1 = sel and sel.pos1
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

                -- Save the selection as a document highlight before
                -- closing (onClose clears the selection state).
                -- Skip if a highlight already exists at the same position.
                local already_highlighted = false
                local anns = (ui.annotation and ui.annotation.annotations) or {}
                for _, ann in ipairs(anns) do
                    if ann.drawer and ann.pos0 == highlight_pos0 and ann.pos1 == highlight_pos1 then
                        already_highlighted = true
                        break
                    end
                end
                if not already_highlighted then
                    rhi:saveHighlight()
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

                    card.source         = cambridge_url(card.phrase)
                    card.book_title     = title
                    card.book_author    = author
                    card.highlight_pos0 = highlight_pos0
                    card.highlight_pos1 = highlight_pos1

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
                                -- Close whichever viewer is currently showing
                                -- (may differ from v after an async update).
                                local cur = viewer_ref[1] or v
                                UIManager:close(cur)
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
                                local ok, err = AnkiSync.send_card(get_anki_config(), c, CONFIGURATION)
                                if ok then CardStorage.save_card(c) end
                                return ok, err
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
                                    new_card.source         = cambridge_url(new_card.phrase)
                                    new_card.book_title     = title
                                    new_card.book_author    = author
                                    new_card.highlight_pos0 = highlight_pos0
                                    new_card.highlight_pos1 = highlight_pos1
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

                            on_regen_text = function()
                                if viewer_ref[1] then UIManager:close(viewer_ref[1]) end
                                local loading3 = Notification:new {
                                    text    = _("Regenerating sentence…"),
                                    timeout = 30,
                                }
                                UIManager:show(loading3)
                                NetworkMgr:runWhenOnline(function()
                                    UIManager:scheduleIn(0.05, function()
                                        UIManager:close(loading3)
                                        local new_text, new_prompt = CardGenerator.generate_text(CONFIGURATION, c.phrase)
                                        if not new_text then
                                            UIManager:show(Notification:new {
                                                text    = _("Regen failed: ") .. (new_prompt or "unknown"),
                                                timeout = 5,
                                            })
                                            viewer_ref[1] = make_viewer(c, true)
                                            return
                                        end
                                        c.text         = new_text
                                        c.image_prompt = new_prompt
                                        viewer_ref[1] = make_viewer(c, true)
                                        -- Kick off image generation with new prompt.
                                        if new_prompt then
                                            ImageGenerator.generate_async(
                                                CONFIGURATION,
                                                new_prompt,
                                                c.phrase,
                                                function(img_path)
                                                    c.image_path = img_path
                                                    CardStorage.update_image_path(c.phrase, img_path)
                                                    if viewer_ref[1] then
                                                        viewer_ref[1] = viewer_ref[1]:update(c)
                                                    end
                                                end,
                                                nil
                                            )
                                        end
                                    end)
                                end)
                            end,

                            on_regen_image = function()
                                if not c.image_prompt or c.image_prompt == "" then
                                    UIManager:show(Notification:new {
                                        text    = _("No image prompt available"),
                                        timeout = 3,
                                    })
                                    return
                                end
                                local old_image = c.image_path
                                UIManager:show(Notification:new {
                                    text    = _("Regenerating image…"),
                                    timeout = 60,
                                })
                                ImageGenerator.generate_async(
                                    CONFIGURATION,
                                    c.image_prompt,
                                    c.phrase,
                                    function(img_path)
                                        -- Clean up old image file.
                                        if old_image and old_image ~= "" then
                                            os.remove(old_image)
                                        end
                                        c.image_path = img_path
                                        CardStorage.update_image_path(c.phrase, img_path)
                                        if viewer_ref[1] then
                                            viewer_ref[1] = viewer_ref[1]:update(c)
                                        end
                                        UIManager:setDirty(nil, "full")
                                        UIManager:show(Notification:new {
                                            text    = _("New image loaded!"),
                                            timeout = 3,
                                        })
                                    end,
                                    function(err)
                                        UIManager:show(Notification:new {
                                            text    = _("Image regen failed: ") .. (err or "unknown"),
                                            timeout = 5,
                                        })
                                    end
                                )
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

    -- ── Entry 2: Anki Manage (includes Anki Inbox) ───────────────────────────
    self.ui.highlight:addToHighlightDialog("ankiflashcards_2", function(_rhi)
        return {
            text    = _("Anki Manage"),
            enabled = true,
            callback = function()
                local ui = self.ui
                self.ui.highlight:onClose()
                CardManager.show_manage(CONFIGURATION, {
                    on_inbox = function()
                        HighlightInbox.show(ui, CONFIGURATION)
                    end,
                })
            end,
        }
    end)

    -- ── Entry 3: My Cards ─────────────────────────────────────────────────────
    self.ui.highlight:addToHighlightDialog("ankiflashcards_3", function(_rhi)
        return {
            text    = _("My Cards"),
            enabled = true,
            callback = function()
                local book_title = clean_str(self.ui.document:getProps().title, MAX_TITLE)
                self.ui.highlight:onClose()
                CardManager.show(CONFIGURATION, book_title, self.ui)
            end,
        }
    end)

    -- ── Tap-to-Show Flashcard ─────────────────────────────────────────────────
    -- Short tap on a highlight with a saved card → show card viewer directly.
    -- No saved card → fall through to original highlight menu.
    local highlight_module = self.ui.highlight
    local orig_onTap = highlight_module.onTap
    local plugin_self = self

    highlight_module.onTap = function(hl_self, arg, ges)
        -- Pass through if mid-hold or no gesture
        if hl_self.hold_pos or not ges then
            return orig_onTap(hl_self, arg, ges)
        end
        local visible = hl_self.view and hl_self.view.highlight
                        and hl_self.view.highlight.visible_boxes
        if not visible or #visible == 0 then
            return orig_onTap(hl_self, arg, ges)
        end
        local pos = hl_self.view:screenToPageTransform(ges.pos)
        if not pos then
            return orig_onTap(hl_self, arg, ges)
        end

        -- Find tapped highlight and check for a saved card
        for _, box in ipairs(visible) do
            local r = box.rect
            if r and pos.x >= r.x and pos.y >= r.y
               and pos.x <= r.x + r.w and pos.y <= r.y + r.h then
                local ann = hl_self.ui.annotation.annotations[box.index]
                if ann then
                    local card = CardStorage.find_by_position(ann.pos0, ann.pos1)
                                 or (ann.text and CardStorage.find_by_phrase_fuzzy(ann.text))
                    if card then
                        local viewer_ref = {}
                        local function make_viewer(show_back)
                            local v
                            v = CardViewer:new {
                                card      = card,
                                show_back = show_back,
                                read_only = false,
                                on_show_answer = function()
                                    UIManager:close(v)
                                    viewer_ref[1] = make_viewer(true)
                                end,
                                on_save = function()
                                    return nil, _("Already saved")
                                end,
                                on_send = function()
                                    return AnkiSync.send_card(get_anki_config(), card, CONFIGURATION)
                                end,
                            }
                            UIManager:show(v)
                            return v
                        end
                        viewer_ref[1] = make_viewer(false)
                        return true
                    end
                end
                break  -- only check first hit; fall through to original
            end
        end
        return orig_onTap(hl_self, arg, ges)
    end

    -- ── Auto-Send on WiFi ────────────────────────────────────────────────────
    -- Polls every 60s. When WiFi is on and auto_send_wifi is enabled,
    -- flushes all unsent cards to AnkiConnect in the background.
    local AUTO_SEND_INTERVAL = 60
    local function auto_send_tick()
        UIManager:scheduleIn(AUTO_SEND_INTERVAL, auto_send_tick)
        local cfg = get_anki_config()
        if not cfg.auto_send_wifi then return end
        if not cfg.url or cfg.url == "" then return end
        if not NetworkMgr:isOnline() then return end

        local cards = CardStorage.load_cards()
        local sent = 0
        for _, card in ipairs(cards) do
            if not card.sent_to_anki then
                local ok = AnkiSync.send_card(cfg, card, CONFIGURATION)
                if ok then
                    CardStorage.mark_sent(card.phrase)
                    sent = sent + 1
                end
            end
        end
        if sent > 0 then
            UIManager:show(Notification:new {
                text    = sent .. _(" card(s) sent to Anki"),
                timeout = 3,
            })
        end
    end
    -- First check after 30s to let KOReader settle on startup.
    UIManager:scheduleIn(30, auto_send_tick)

end

return AnkiFlashcards
