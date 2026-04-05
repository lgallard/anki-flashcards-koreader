-- AnkiFlashcards KOReader plugin.
-- Adds two entries to the highlight dialog:
--   📖 Anki Card  — generates a full Anki flashcard via AI and shows a card viewer
--   📚 My Cards   — opens the card manager (list of saved cards)

local Device         = require("device")
local InfoMessage    = require("ui/widget/infomessage")
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
local CardSync         = require("card_sync")
local HighlightInbox   = require("highlight_inbox")
local ImageGenerator   = require("image_generator")
local AudioGenerator   = require("audio_generator")

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
        -- Promote plugin-level settings from saved anki settings to top level.
        for _, key in ipairs({
            "target_language",
            "text_provider",
            "image_provider",
            "dashscope_api_key",
            "gemini_api_key",
            "openai_api_key",
            "openrouter_api_key",
            "openrouter_model",
            "elevenlabs_api_key",
            "ankivocab_api_key",
        }) do
            if saved_anki[key] and saved_anki[key] ~= "" then
                CONFIGURATION[key] = saved_anki[key]
            end
        end
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
    local lang = CONFIGURATION and CONFIGURATION.target_language or "English"
    if lang ~= "English" then return nil end
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

-- Build an image-generator config for a card.  When the image provider is
-- "ankivocab", copies CONFIGURATION and adds the keys the generator needs
-- to poll the API for the image URL.
local function make_image_config(card)
    local cfg = CONFIGURATION
    if CONFIGURATION.image_provider == "ankivocab" then
        cfg = {}
        for k, v in pairs(CONFIGURATION) do cfg[k] = v end
        cfg.image_provider = "ankivocab"
        if type(card._image_url) == "string" and card._image_url ~= "" then
            cfg._ankivocab_image_url = card._image_url
        end
        -- Use the original word sent to the API (persisted on card), falling
        -- back to the canonical phrase.  The API indexes by original word, so
        -- polling with the canonical form may not find the cached image.
        cfg._ankivocab_word = card._ankivocab_word or card.phrase
    end
    return cfg
end

-- Return true if the card has enough info to kick off image generation.
-- For ankivocab, only trigger if the card was actually created via AnkiVocab
-- (_ankivocab_word is set), not just because the current provider is ankivocab.
local function can_generate_image(card, img_cfg)
    local has_prompt = card.image_prompt and card.image_prompt ~= ""
    local is_ankivocab_card = img_cfg.image_provider == "ankivocab"
                          and card._ankivocab_word and card._ankivocab_word ~= ""
    return has_prompt or is_ankivocab_card
end

-- ── Quick Lookup cache + popup (purple highlights) ──────────────────────────
local quick_lookup_cache = {}

local PTF_BOLD_ON  = "\xEF\xBF\xB2"
local PTF_BOLD_OFF = "\xEF\xBF\xB3"

local function show_quick_lookup_popup(phrase, lookup, on_delete)
    local Blitbuffer      = require("ffi/blitbuffer")
    local ButtonTable     = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Geom            = require("ui/geometry")
    local GestureRange    = require("ui/gesturerange")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local Size            = require("ui/size")
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")

    local screen_w = Device.screen:getWidth()
    local screen_h = Device.screen:getHeight()
    local popup_w  = math.floor(screen_w * 0.82)
    local pad      = Size.padding.large

    local COLOR_BLUE = Blitbuffer.ColorRGB32(0x00, 0x3A, 0x75, 0xFF)
    local COLOR_RED  = Blitbuffer.ColorRGB32(0xBB, 0x00, 0x00, 0xFF)

    local inner_w = popup_w - pad * 2

    local phrase_w = TextBoxWidget:new {
        text      = capitalize_first(phrase),
        face      = Font:getFace("cfont", 24),
        fgcolor   = COLOR_BLUE,
        width     = inner_w,
        alignment = "center",
        bold      = true,
    }
    local ipa_w = TextBoxWidget:new {
        text      = lookup.ipa or "",
        face      = Font:getFace("cfont", 20),
        fgcolor   = COLOR_RED,
        width     = inner_w,
        alignment = "center",
    }
    local def_w = TextBoxWidget:new {
        text      = lookup.definition or "",
        face      = Font:getFace("cfont", 20),
        width     = inner_w,
        alignment = "center",
    }

    local content = VerticalGroup:new {
        align = "center",
        phrase_w,
        VerticalSpan:new { width = Size.padding.default },
        ipa_w,
        VerticalSpan:new { width = Size.padding.default },
        def_w,
    }

    -- Add a "Delete Highlight" button if a delete callback is provided.
    -- popup_ref is set after the popup widget is created (below).
    local popup_ref = {}
    if on_delete then
        local btn_table = ButtonTable:new {
            width = inner_w,
            buttons = {{
                {
                    text     = _("Delete Highlight"),
                    callback = function()
                        if popup_ref[1] then UIManager:close(popup_ref[1]) end
                        on_delete()
                    end,
                },
            }},
            zero_sep = true,
        }
        content[#content + 1] = VerticalSpan:new { width = Size.padding.large }
        content[#content + 1] = btn_table
    end

    local frame = FrameContainer:new {
        background   = Blitbuffer.COLOR_WHITE,
        bordersize   = Size.border.window,
        radius       = Size.radius.window,
        padding      = pad,
        content,
    }

    local popup
    popup = InputContainer:new {
        ges_events = {
            TapClose = {
                GestureRange:new {
                    ges   = "tap",
                    range = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h },
                },
            },
        },
        CenterContainer:new {
            dimen = Geom:new { w = screen_w, h = screen_h },
            frame,
        },
    }
    function popup:onTapClose()
        UIManager:close(self)
        return true
    end
    function popup:onAnyKeyPressed()
        UIManager:close(self)
        return true
    end

    popup_ref[1] = popup
    UIManager:show(popup)
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
                        UIManager:show(InfoMessage:new {
                            text    = _("Card generation failed: ") .. (err or "unknown"),
                            timeout = 5,
                        })
                        return
                    end

                    -- AnkiVocab returns its own source URL; other providers use Cambridge.
                    if not card.source or card.source == "" then
                        card.source = cambridge_url(card.phrase)
                    end
                    card.book_title     = title
                    card.book_author    = author
                    card.highlight_pos0 = highlight_pos0
                    card.highlight_pos1 = highlight_pos1

                    -- Keep _audio_url so AnkiConnect can download and attach
                    -- the server-generated audio when sending to Anki.

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
                                        UIManager:show(InfoMessage:new {
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
                                            UIManager:show(InfoMessage:new {
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
                                        UIManager:show(InfoMessage:new {
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
                    local img_config = make_image_config(card)
                    card._image_url = nil
                    if can_generate_image(card, img_config) then
                        ImageGenerator.generate_async(
                            img_config,
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

                    -- Poll for audio URL in background when AnkiVocab
                    -- generated it asynchronously (audio_status = "pending").
                    if card._audio_status == "pending"
                       and card._ankivocab_word and card._ankivocab_word ~= "" then
                        AudioGenerator.poll_ankivocab_async(
                            CONFIGURATION,
                            card._ankivocab_word,
                            function(audio_url)
                                card._audio_url = audio_url
                                CardStorage.update_audio_url(card.phrase, audio_url)
                            end,
                            nil  -- audio polling errors are non-fatal
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
        for _i, box in ipairs(visible) do
            local r = box.rect
            if r and pos.x >= r.x and pos.y >= r.y
               and pos.x <= r.x + r.w and pos.y <= r.y + r.h then
                local ann = hl_self.ui.annotation.annotations[box.index]
                if ann then
                    local card = CardStorage.find_by_position(ann.pos0, ann.pos1)
                                 or (ann.text and CardStorage.find_by_phrase_fuzzy(ann.text))
                    if card then
                        local hl_index = box.index
                        local viewer_ref = {}
                        local function make_viewer(show_back)
                            local v
                            v = CardViewer:new {
                                card      = card,
                                show_back = show_back,
                                read_only = false,
                                on_show_answer = function()
                                    -- Close whichever viewer is currently showing
                                    -- (may differ from v after an async image update).
                                    local cur = viewer_ref[1] or v
                                    UIManager:close(cur)
                                    viewer_ref[1] = make_viewer(true)
                                end,
                                on_save = function()
                                    return nil, _("Already saved")
                                end,
                                on_send = function()
                                    return AnkiSync.send_card(get_anki_config(), card, CONFIGURATION)
                                end,
                                on_regen_image = function()
                                    if not card.image_prompt or card.image_prompt == "" then
                                        UIManager:show(Notification:new {
                                            text    = _("No image prompt available"),
                                            timeout = 3,
                                        })
                                        return
                                    end
                                    local old_image = card.image_path
                                    UIManager:show(Notification:new {
                                        text    = _("Regenerating image…"),
                                        timeout = 60,
                                    })
                                    ImageGenerator.generate_async(
                                        CONFIGURATION,
                                        card.image_prompt,
                                        card.phrase,
                                        function(img_path)
                                            if old_image and old_image ~= "" then
                                                os.remove(old_image)
                                            end
                                            card.image_path = img_path
                                            CardStorage.update_image_path(card.phrase, img_path)
                                            if viewer_ref[1] then
                                                viewer_ref[1] = viewer_ref[1]:update(card)
                                            end
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
                                on_highlight_dialog = function()
                                    hl_self:showHighlightDialog(hl_index)
                                end,
                            }
                            UIManager:show(v)
                            return v
                        end
                        viewer_ref[1] = make_viewer(false)
                        -- Auto-regenerate image if missing (e.g. synced card).
                        local saved_img_cfg = make_image_config(card)
                        if (not card.image_path or card.image_path == "")
                           and can_generate_image(card, saved_img_cfg)
                           and NetworkMgr:isOnline() then
                            ImageGenerator.generate_async(
                                saved_img_cfg,
                                card.image_prompt,
                                card.phrase,
                                function(img_path)
                                    card.image_path = img_path
                                    CardStorage.update_image_path(card.phrase, img_path)
                                    if viewer_ref[1] then
                                        viewer_ref[1] = viewer_ref[1]:update(card)
                                    end
                                end,
                                nil  -- silent on error
                            )
                        end
                        return true
                    end

                    -- ── Quick Lookup for purple highlights ───────────────
                    if ann.color == "purple" and ann.text and ann.text ~= "" then
                        local phrase_text = ann.text
                        local ann_ref     = ann
                        local ui_ref      = hl_self.ui
                        local hl_idx      = box.index

                        -- Delete callback: removes the highlight via KOReader's API.
                        local function delete_highlight()
                            hl_self:deleteHighlight(hl_idx)
                        end

                        -- Check annotation note for a previously saved lookup.
                        if ann_ref.note and ann_ref.note:match("^%[IPA%]") then
                            local ipa = ann_ref.note:match("%[IPA%] (.-) | ")
                            local def = ann_ref.note:match("| (.+)$")
                            if ipa and def then
                                show_quick_lookup_popup(phrase_text, { ipa = ipa, definition = def }, delete_highlight)
                                return true
                            end
                        end

                        -- Check session cache.
                        if quick_lookup_cache[phrase_text] then
                            show_quick_lookup_popup(phrase_text, quick_lookup_cache[phrase_text], delete_highlight)
                            return true
                        end

                        if not NetworkMgr:isOnline() then
                            -- Offline: fall through to normal highlight menu.
                            break
                        end
                        local loading = Notification:new {
                            text    = _("Looking up: ") .. phrase_text,
                            timeout = 15,
                        }
                        UIManager:show(loading)
                        UIManager:scheduleIn(0.05, function()
                            UIManager:close(loading)
                            local result, err = CardGenerator.generate_quick_lookup(
                                CONFIGURATION, phrase_text
                            )
                            if result then
                                quick_lookup_cache[phrase_text] = result
                                -- Persist to annotation note for offline access.
                                ann_ref.note = "[IPA] " .. (result.ipa or "")
                                            .. " | " .. (result.definition or "")
                                local Event = require("ui/event")
                                ui_ref:handleEvent(Event:new("AnnotationsModified",
                                    { ann_ref, nb_highlights_added = 0, nb_notes_added = 1 }))
                                show_quick_lookup_popup(phrase_text, result, delete_highlight)
                            else
                                UIManager:show(InfoMessage:new {
                                    text    = _("Lookup failed: ") .. (err or "unknown"),
                                    timeout = 3,
                                })
                            end
                        end)
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

    -- ── Auto-Sync on Startup ──────────────────────────────────────────────
    -- One-shot silent cloud sync 45s after startup.
    UIManager:scheduleIn(45, function()
        local cfg = get_anki_config()
        if cfg.sync_server and NetworkMgr:isOnline() then
            CardSync.run_sync(cfg.sync_server, true)
        end
    end)

end

return AnkiFlashcards
