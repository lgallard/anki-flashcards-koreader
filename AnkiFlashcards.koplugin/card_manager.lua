-- Card Manager: card list (with filter) + separate management submenu.

local ButtonDialog   = require("ui/widget/buttondialog")
local ConfirmBox     = require("ui/widget/confirmbox")
local Menu           = require("ui/widget/menu")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")

local Event          = require("ui/event")
local CardStorage    = require("card_storage")
local AnkiSync       = require("anki_sync")
local CardGenerator  = require("card_generator")
local CardViewer     = require("card_viewer")
local ImageGenerator = require("image_generator")
local NetworkMgr     = require("ui/network/manager")
local SettingsViewer = require("settings_viewer")

local CardManager = {}

local function notify(text)
    UIManager:show(Notification:new { text = text })
end

-- Handles both full CONFIGURATION (with nested .anki) and a flat Anki-only table.
local function effective_config(base)
    local cfg = {}
    local anki_base = (base and type(base.anki) == "table") and base.anki or base
    if anki_base then
        for k, v in pairs(anki_base) do cfg[k] = v end
    end
    local saved = CardStorage.load_anki_settings()
    if saved then
        for k, v in pairs(saved) do cfg[k] = v end
    end
    return cfg
end

local function is_anki_ready(anki_config)
    return anki_config.url
        and anki_config.url ~= ""
        and not anki_config.url:find("192.168.x.x")
end

local function send_one(anki_config, card, tts_config)
    if not is_anki_ready(anki_config) then
        notify(_("Anki URL not set. Use Manage > Anki Settings."))
        return false
    end
    local ok, err = AnkiSync.send_card(anki_config, card, tts_config)
    if ok then
        CardStorage.mark_sent(card.phrase)
        return true
    else
        notify(_("Anki error: ") .. (err or "unknown"))
        return false
    end
end

local function show_stats()
    local all_cards  = CardStorage.load_cards()
    local book_order = {}
    local book_stats = {}
    for _i, card in ipairs(all_cards) do
        local title = (card.book_title and card.book_title ~= "")
                      and card.book_title or _("Unknown book")
        if not book_stats[title] then
            book_stats[title] = { total = 0, sent = 0 }
            table.insert(book_order, title)
        end
        book_stats[title].total = book_stats[title].total + 1
        if card.sent_to_anki then book_stats[title].sent = book_stats[title].sent + 1 end
    end

    local total_all, sent_all = #all_cards, 0
    for _i, card in ipairs(all_cards) do
        if card.sent_to_anki then sent_all = sent_all + 1 end
    end

    local stat_items = {}
    if #book_order == 0 then
        table.insert(stat_items, { text = _("(no cards yet)") })
    end
    for _i, title in ipairs(book_order) do
        local s      = book_stats[title]
        local unsent = s.total - s.sent
        local line   = title .. "  —  " .. tostring(s.total)
                       .. (s.total == 1 and _(" card") or _(" cards"))
                       .. "  +" .. tostring(s.sent) .. " sent"
        if unsent > 0 then
            line = line .. "  -" .. tostring(unsent) .. " unsent"
        end
        table.insert(stat_items, { text = line })
    end

    local title_str = _("Stats — ")
                      .. tostring(total_all)
                      .. (total_all == 1 and _(" card") or _(" cards"))
                      .. "  +" .. tostring(sent_all) .. " sent"
                      .. "  -" .. tostring(total_all - sent_all) .. " unsent"
    UIManager:show(Menu:new { title = title_str, item_table = stat_items })
end

-- ── Management submenu ────────────────────────────────────────────────────────

function CardManager.show_manage(base_config, opts)
    local anki_config = effective_config(base_config)
    local manage_menu

    local item_table = {
        {
            text = _("Anki Settings"),
            bold = true,
            callback = function()
                SettingsViewer.show(base_config, function(new_cfg)
                    for k, v in pairs(new_cfg) do anki_config[k] = v end
                    -- Promote plugin-level settings to the top-level config.
                    for _, key in ipairs({
                        "text_provider",
                        "image_provider",
                        "dashscope_api_key",
                        "gemini_api_key",
                        "elevenlabs_api_key",
                    }) do
                        if new_cfg[key] then
                            base_config[key] = new_cfg[key]
                        end
                    end
                end)
            end,
        },
        {
            text = _("Send All Unsent to Anki"),
            bold = true,
            callback = function()
                local fresh        = CardStorage.load_cards()
                local sent, failed = 0, 0
                for _, card in ipairs(fresh) do
                    if not card.sent_to_anki then
                        if send_one(anki_config, card, base_config) then
                            sent = sent + 1
                        else
                            failed = failed + 1
                        end
                    end
                end
                local msg = tostring(sent) .. _(" sent")
                if failed > 0 then msg = msg .. ", " .. tostring(failed) .. _(" failed") end
                notify(msg)
            end,
        },
        {
            text = _("Stats by Book"),
            bold = true,
            callback = function() show_stats() end,
        },
        {
            text     = _("Highlights to Anki Cards"),
            bold     = true,
            callback = function()
                if manage_menu then UIManager:close(manage_menu) end
                if opts and opts.on_inbox then opts.on_inbox() end
            end,
        },
        {
            text = _("Clear All Cards"),
            bold = true,
            callback = function()
                UIManager:show(ConfirmBox:new {
                    text        = _("Delete all saved cards? This cannot be undone."),
                    ok_text     = _("Clear All"),
                    ok_callback = function()
                        CardStorage.clear_all()
                        notify(_("All cards cleared"))
                        if manage_menu then UIManager:close(manage_menu) end
                    end,
                })
            end,
        },
    }

    manage_menu = Menu:new {
        title      = _("Manage"),
        item_table = item_table,
    }
    UIManager:show(manage_menu)
end

-- ── Card list with optional book filter ───────────────────────────────────────

function CardManager.show(base_config, filter_book, ui)
    local anki_config = effective_config(base_config)
    local menu_instance

    local function refresh()
        if menu_instance then UIManager:close(menu_instance) end
        CardManager.show(base_config, filter_book, ui)
    end

    local all_cards  = CardStorage.load_cards()
    local item_table = {}

    -- ── Filter entry ──────────────────────────────────────────────────────────
    local filter_label = filter_book
                         and (_("Filter: ") .. filter_book .. _(" (tap to clear)"))
                         or  _("Filter: All Books")
    table.insert(item_table, {
        text = filter_label,
        bold = true,
        callback = function()
            if filter_book then
                -- Clear filter.
                if menu_instance then UIManager:close(menu_instance) end
                CardManager.show(base_config, nil)
                return
            end
            -- Build book picker from stored cards.
            local books, seen = {}, {}
            for _i, card in ipairs(all_cards) do
                local t = (card.book_title and card.book_title ~= "")
                          and card.book_title or _("Unknown book")
                if not seen[t] then seen[t] = true; table.insert(books, t) end
            end
            local picker
            local book_buttons = {}
            for _i, b in ipairs(books) do
                local bref = b
                table.insert(book_buttons, {{ text = bref, callback = function()
                    UIManager:close(picker)
                    if menu_instance then UIManager:close(menu_instance) end
                    CardManager.show(base_config, bref)
                end }})
            end
            table.insert(book_buttons, {{ text = _("Cancel"),
                callback = function() UIManager:close(picker) end }})
            picker = ButtonDialog:new {
                title   = _("Filter by Book"),
                buttons = book_buttons,
            }
            UIManager:show(picker)
        end,
    })

    -- ── Filtered card list ────────────────────────────────────────────────────
    local cards = {}
    for _i, card in ipairs(all_cards) do
        if not filter_book or card.book_title == filter_book then
            table.insert(cards, card)
        end
    end

    if #cards == 0 then
        table.insert(item_table, {
            text = filter_book and _("(no cards for this book)")
                               or  _("(no saved cards yet)"),
        })
    end

    for i, card in ipairs(cards) do
        local idx    = i
        local prefix = card.sent_to_anki and "+ " or ""
        local book   = (card.book_title and card.book_title ~= "")
                       and card.book_title or _("Unknown book")
        local label  = prefix
                       .. (card.phrase or "") .. "  —  "
                       .. book .. "  (" .. (card.date or "") .. ")"

        local function open_viewer()
            local viewer_ref = {}
            local card_ref   = { phrase = card.phrase }
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
                        return AnkiSync.send_card(anki_config, card, base_config)
                    end,
                    on_navigate_to_source = (ui and card.highlight_pos0) and function()
                        local cur = viewer_ref[1]
                        if cur then UIManager:close(cur) end
                        if menu_instance then UIManager:close(menu_instance) end
                        local event_name = ui.paging and "GotoPage" or "GotoXPointer"
                        ui:handleEvent(Event:new(event_name, card.highlight_pos0))
                    end or nil,
                    on_update = function(updated_card)
                        CardStorage.update_card(card_ref.phrase, updated_card)
                        card_ref.phrase = updated_card.phrase
                    end,
                    on_regen_text = function()
                        if viewer_ref[1] then UIManager:close(viewer_ref[1]) end
                        local loading_t = Notification:new {
                            text    = _("Regenerating sentence…"),
                            timeout = 30,
                        }
                        UIManager:show(loading_t)
                        NetworkMgr:runWhenOnline(function()
                            UIManager:scheduleIn(0.05, function()
                                UIManager:close(loading_t)
                                local new_text, new_prompt = CardGenerator.generate_text(base_config, card.phrase)
                                if not new_text then
                                    notify(_("Regen failed: ") .. (new_prompt or "unknown"))
                                    viewer_ref[1] = make_viewer(true)
                                    return
                                end
                                card.text         = new_text
                                card.image_prompt = new_prompt
                                CardStorage.update_card(card_ref.phrase, card)
                                viewer_ref[1] = make_viewer(true)
                                -- Kick off image generation with new prompt.
                                if new_prompt then
                                    ImageGenerator.generate_async(
                                        base_config,
                                        new_prompt,
                                        card.phrase,
                                        function(img_path)
                                            card.image_path = img_path
                                            CardStorage.update_image_path(card.phrase, img_path)
                                            if viewer_ref[1] then
                                                viewer_ref[1] = viewer_ref[1]:update(card)
                                            end
                                        end,
                                        nil
                                    )
                                end
                            end)
                        end)
                    end,
                    on_regen_image = function()
                        if not card.image_prompt or card.image_prompt == "" then
                            notify(_("No image prompt available"))
                            return
                        end
                        local old_image = card.image_path
                        notify(_("Regenerating image…"))
                        ImageGenerator.generate_async(
                            base_config,
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
                                UIManager:setDirty(nil, "full")
                                notify(_("New image loaded!"))
                            end,
                            function(err)
                                notify(_("Image regen failed: ") .. (err or "unknown"))
                            end
                        )
                    end,
                    on_regen_ipa = function(new_phrase, updated_card, new_viewer)
                        NetworkMgr:runWhenOnline(function()
                            UIManager:scheduleIn(0.05, function()
                                local ipa, err = CardGenerator.generate_ipa(base_config, new_phrase)
                                if ipa then
                                    updated_card.ipa = ipa
                                    CardStorage.update_card(updated_card.phrase, updated_card)
                                    local still_shown = false
                                    for w in UIManager:topdown_widgets_iter() do
                                        if w == new_viewer then still_shown = true; break end
                                    end
                                    if still_shown then new_viewer:update() end
                                    notify(_("IPA updated"))
                                else
                                    notify(_("IPA regen failed: ") .. (err or "unknown"))
                                end
                            end)
                        end)
                    end,
                }
                UIManager:show(v)
                return v
            end
            viewer_ref[1] = make_viewer(false)
            -- Auto-regenerate image if missing (e.g. synced card).
            if (not card.image_path or card.image_path == "")
               and card.image_prompt and card.image_prompt ~= ""
               and NetworkMgr:isOnline() then
                ImageGenerator.generate_async(
                    config,
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
        end

        local function open_context_menu()
            local dialog
            dialog = ButtonDialog:new {
                title   = card.phrase or "",
                buttons = {
                    {{ text = _("Send to Anki"), callback = function()
                        UIManager:close(dialog)
                        if send_one(anki_config, card, base_config) then
                            notify(_("Sent!"))
                            refresh()
                        end
                    end }},
                    {{ text = _("Delete"), callback = function()
                        UIManager:close(dialog)
                        UIManager:show(ConfirmBox:new {
                            text        = _("Delete '") .. (card.phrase or "") .. _("'?"),
                            ok_text     = _("Delete"),
                            ok_callback = function()
                                CardStorage.delete_card(idx)
                                refresh()
                            end,
                        })
                    end }},
                    {{ text = _("Cancel"), callback = function()
                        UIManager:close(dialog)
                    end }},
                },
            }
            UIManager:show(dialog)
        end

        table.insert(item_table, {
            text          = label,
            callback      = open_viewer,
            hold_callback = open_context_menu,
        })
    end

    local count_label = #cards == 1
                        and _("1 card")
                        or  (tostring(#cards) .. _(" cards"))
    if filter_book then count_label = count_label .. _(" (filtered)") end

    menu_instance = Menu:new {
        title      = _("My Cards (") .. count_label .. ")",
        item_table = item_table,
        onMenuHold = function(self, item)
            if item and item.hold_callback then item.hold_callback() end
        end,
    }
    UIManager:show(menu_instance)
end

return CardManager
