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

local InfoMessage   = require("ui/widget/infomessage")

local CardManager = {}
-- This is an internal key, not a display label. A localized "Unknown book"
-- title is therefore always distinct from cards with missing book metadata.
local MISSING_BOOK = {}

local function notify(text)
    UIManager:show(Notification:new { text = text })
end

local function notify_error(text)
    UIManager:show(InfoMessage:new { text = text, timeout = 5 })
end

local function cards_for_book(cards, book_key)
    local filtered = {}
    local is_missing_book = book_key == MISSING_BOOK
    for _, card in ipairs(cards) do
        if (is_missing_book and (not card.book_title or card.book_title == ""))
           or (not is_missing_book and card.book_title == book_key) then
            table.insert(filtered, card)
        end
    end
    return filtered
end

local function close_for_replacement(viewer)
    if viewer then viewer._updating = true; UIManager:close(viewer) end
end

local function invalidate_card_content(session)
    session.content_version = (session.content_version or 0) + 1
    session.image_version = (session.image_version or 0) + 1
end

local function invalidate_viewer_session(session)
    session.open = false
    session.viewer = nil
    invalidate_card_content(session)
end

local function begin_image_request(config, card, session, after_success, on_error)
    -- Migrate legacy records before scheduling. Once a callback is in flight,
    -- it must identify its generation only by this persisted id.
    if not CardStorage.ensure_identity(card) then return false end
    session.image_version = (session.image_version or 0) + 1
    local version = session.image_version
    local content_version = session.content_version or 0
    local storage_id = card._storage_id
    ImageGenerator.generate_async(config, card.image_prompt, card.phrase, function(image_path)
        if not session.open or session.image_version ~= version
           or session.content_version ~= content_version
           or card._storage_id ~= storage_id then
            CardStorage.remove_image_if_unreferenced(image_path)
            return
        end
        if not CardStorage.update_image_path(card, image_path) then
            CardStorage.remove_image_if_unreferenced(image_path)
            return
        end
        if not session.open or session.image_version ~= version
           or session.content_version ~= content_version then
            CardStorage.remove_image_if_unreferenced(image_path)
            return
        end
        card.image_path = image_path
        if session.viewer then session.viewer = session.viewer:update(card) end
        if after_success then after_success() end
    end, on_error)
    return true
end

local function apply_async_audio(card, session, audio_url, storage_id, content_version, word)
    if not session.open or session.content_version ~= content_version
       or card._storage_id ~= storage_id or card._ankivocab_word ~= word then
        return false
    end
    if not CardStorage.update_audio_url(card, audio_url) then return false end
    if not session.open or session.content_version ~= content_version
       or card._storage_id ~= storage_id or card._ankivocab_word ~= word then
        return false
    end
    card._audio_url = audio_url
    return true
end

local function poll_pending_audio(config, card, session)
    if card._audio_status ~= "pending"
       or not card._ankivocab_word or card._ankivocab_word == "" then
        return false
    end
    if not CardStorage.ensure_identity(card) then return false end
    local storage_id = card._storage_id
    local content_version = session.content_version or 0
    local word = card._ankivocab_word
    require("audio_generator").poll_ankivocab_async(config, word, function(audio_url)
        apply_async_audio(card, session, audio_url, storage_id, content_version, word)
    end, nil)
    return true
end

local function copy_card(card)
    local copy = {}
    for key, value in pairs(card) do copy[key] = value end
    return copy
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
        for k, v in pairs(saved) do
            if k == "anki_model" then
                cfg.model = v
            elseif k == "model" and not saved.anki_model then
                cfg.model = v
            elseif k ~= "model" and k ~= "image_model"
               and k ~= "gemini_text_model" and k ~= "gemini_image_model"
               and k ~= "openai_model" and k ~= "openai_image_model"
               and k ~= "openrouter_model" and k ~= "openrouter_image_model" then
                cfg[k] = v
            end
        end
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
        notify_error(_("Anki URL not set. Use Manage > Anki Settings."))
        return false
    end
    local ok, err = AnkiSync.send_card(anki_config, card, tts_config)
    if ok then
        if not CardStorage.mark_sent(card.phrase) then
            notify_error(_("Anki accepted the card, but its sent state could not be saved"))
            return false
        end
        return true
    else
        notify_error(_("Anki error: ") .. (err or "unknown"))
        return false
    end
end

local function show_stats()
    local all_cards  = CardStorage.load_cards()
    local book_order = {}
    local book_stats = {}
    for _i, card in ipairs(all_cards) do
        local book_key = (card.book_title and card.book_title ~= "")
                         and card.book_title or MISSING_BOOK
        if not book_stats[book_key] then
            book_stats[book_key] = {
                total = 0,
                sent = 0,
                label = book_key == MISSING_BOOK and _("Unknown book") or book_key,
            }
            table.insert(book_order, book_key)
        end
        book_stats[book_key].total = book_stats[book_key].total + 1
        if card.sent_to_anki then book_stats[book_key].sent = book_stats[book_key].sent + 1 end
    end

    local total_all, sent_all = #all_cards, 0
    for _i, card in ipairs(all_cards) do
        if card.sent_to_anki then sent_all = sent_all + 1 end
    end

    local stats_menu
    local function refresh_stats()
        if stats_menu then UIManager:close(stats_menu) end
        show_stats()
    end
    local function delete_book(book_key, label)
        local current_cards = cards_for_book(CardStorage.load_cards(), book_key)
        if #current_cards == 0 then
            notify(_("No cards for this book"))
            refresh_stats()
            return
        end
        UIManager:show(ConfirmBox:new {
            text = _("Delete all ") .. tostring(#current_cards)
                   .. (#current_cards == 1 and _(" local card for '") or _(" local cards for '"))
                   .. label .. _("'? This cannot be undone. Cards already sent to Anki will not be deleted from Anki."),
            ok_text = _("Delete all cards for this book"),
            cancel_callback = function() end,
            ok_callback = function()
                local deleted, count_or_err = CardStorage.delete_cards_for_book(
                    book_key == MISSING_BOOK and nil or book_key,
                    book_key == MISSING_BOOK)
                if not deleted then
                    notify_error(_("Could not delete cards: local persistence failed"))
                    return
                end
                if count_or_err == 0 then
                    notify(_("No cards for this book"))
                else
                    notify(_("Deleted ") .. tostring(count_or_err)
                           .. (count_or_err == 1 and _(" local card for '") or _(" local cards for '"))
                           .. label .. _("'"))
                end
                refresh_stats()
            end,
        })
    end

    local stat_items = {}
    if #book_order == 0 then
        table.insert(stat_items, { text = _("(no cards yet)") })
    end
    for _i, book_key in ipairs(book_order) do
        local s      = book_stats[book_key]
        local unsent = s.total - s.sent
        local line   = s.label .. "  —  " .. tostring(s.total)
                       .. (s.total == 1 and _(" card") or _(" cards"))
                       .. "  +" .. tostring(s.sent) .. " sent"
        if unsent > 0 then
            line = line .. "  -" .. tostring(unsent) .. " unsent"
        end
        local selected_key, selected_label = book_key, s.label
        table.insert(stat_items, {
            text = line,
            hold_callback = function()
                local actions
                actions = ButtonDialog:new {
                    title = selected_label,
                    buttons = {
                        {{ text = _("Delete all cards for this book"), callback = function()
                            UIManager:close(actions)
                            delete_book(selected_key, selected_label)
                        end }},
                        {{ text = _("Cancel"), callback = function() UIManager:close(actions) end }},
                    },
                }
                UIManager:show(actions)
            end,
        })
    end

    local title_str = _("Stats — ")
                      .. tostring(total_all)
                      .. (total_all == 1 and _(" card") or _(" cards"))
                      .. "  +" .. tostring(sent_all) .. " sent"
                      .. "  -" .. tostring(total_all - sent_all) .. " unsent"
    stats_menu = Menu:new {
        title = title_str,
        item_table = stat_items,
        onMenuHold = function(_, item)
            if item and item.hold_callback then item.hold_callback() end
        end,
    }
    UIManager:show(stats_menu)
end

-- ── Card export ─────────────────────────────────────────────────────────────

local function current_book_title(opts)
    local document = opts and opts.ui and opts.ui.document
    if not document or not document.getProps then return nil end
    local ok, props = pcall(document.getProps, document)
    if not (ok and props and props.title and props.title ~= "") then return nil end
    local title = props.title:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
    if #title > 100 then title = title:sub(1, 100) end
    return title ~= "" and title or nil
end

local function show_export_format(cards)
    local format_dialog
    local function close_format_dialog()
        if format_dialog then
            UIManager:close(format_dialog)
            format_dialog = nil
        end
    end
    local function export(format)
        local path, count, err = CardStorage.export_cards(cards, format)
        close_format_dialog()
        if path then
            local count_label = count == 1 and _("1 card")
                                or tostring(count) .. _(" cards")
            notify(_("Exported ") .. count_label .. _(" to ") .. path)
        elseif err == "no_cards" then
            notify(_("No cards to export"))
        else
            notify_error(_("Could not export cards"))
        end
    end

    format_dialog = ButtonDialog:new {
        title = _("Export Cards"),
        buttons = {
            {{ text = _("Export as CSV"), callback = function() export("csv") end }},
            {{ text = _("Export as TSV"), callback = function() export("tsv") end }},
            {{ text = _("Cancel"), callback = close_format_dialog }},
        },
    }
    UIManager:show(format_dialog)
end

local function show_export_scope(opts)
    local all_cards = CardStorage.load_cards()
    if #all_cards == 0 then
        notify(_("No cards to export"))
        return
    end

    local scope_dialog
    local function close_scope_dialog()
        if scope_dialog then
            UIManager:close(scope_dialog)
            scope_dialog = nil
        end
    end
    local function choose_cards(cards)
        close_scope_dialog()
        if #cards == 0 then
            notify(_("No cards to export"))
            return
        end
        show_export_format(cards)
    end

    local buttons = {
        {{ text = _("All Cards (") .. tostring(#all_cards) .. ")", callback = function()
            choose_cards(all_cards)
        end }},
    }

    local current_book = current_book_title(opts)
    if current_book then
        table.insert(buttons, {{ text = _("Current Book: ") .. current_book, callback = function()
            choose_cards(cards_for_book(all_cards, current_book))
        end }})
    end

    table.insert(buttons, {{ text = _("Choose Book"), callback = function()
        close_scope_dialog()
        local books, seen = {}, {}
        for index, card in ipairs(all_cards) do
            local book_key = (card.book_title and card.book_title ~= "")
                             and card.book_title or MISSING_BOOK
            if not seen[book_key] then
                seen[book_key] = true
                table.insert(books, {
                    key = book_key,
                    label = book_key == MISSING_BOOK and _("Unknown book") or book_key,
                })
            end
        end
        table.sort(books, function(left, right)
            if left.label == right.label then
                return left.key == MISSING_BOOK and right.key ~= MISSING_BOOK
            end
            return left.label < right.label
        end)

        local book_dialog
        local book_buttons = {}
        for _, book in ipairs(books) do
            local selected_book = book
            table.insert(book_buttons, {{ text = selected_book.label, callback = function()
                UIManager:close(book_dialog)
                choose_cards(cards_for_book(all_cards, selected_book.key))
            end }})
        end
        table.insert(book_buttons, {{ text = _("Cancel"), callback = function()
            UIManager:close(book_dialog)
        end }})
        book_dialog = ButtonDialog:new {
            title = _("Export Book"),
            buttons = book_buttons,
        }
        UIManager:show(book_dialog)
    end }})
    table.insert(buttons, {{ text = _("Cancel"), callback = function()
        close_scope_dialog()
    end }})

    scope_dialog = ButtonDialog:new {
        title = _("Export Cards"),
        buttons = buttons,
    }
    UIManager:show(scope_dialog)
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
                        "target_language",
                        "text_provider",
                        "image_provider",
                        "images_enabled",
                        "model",
                        "image_model",
                        "gemini_text_model",
                        "gemini_image_model",
                        "openai_model",
                        "openai_image_model",
                        "dashscope_api_key",
                        "gemini_api_key",
                        "openai_api_key",
                        "openrouter_api_key",
                        "openrouter_model",
                        "openrouter_image_model",
                        "elevenlabs_api_key",
                    }) do
                        -- The plugin can run without a local configuration.lua.
                        -- On-device settings are already persisted by SettingsViewer,
                        -- so only mirror them when a base config table is available.
                        if base_config and new_cfg[key] ~= nil then
                            base_config[key] = new_cfg[key]
                        end
                    end
                end, opts and opts.ui)
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
            text = _("Export Cards"),
            bold = true,
            callback = function() show_export_scope(opts) end,
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
                        local cleared = CardStorage.clear_all()
                        if not cleared then
                            notify_error(_("Could not clear cards: local persistence failed"))
                            return
                        end
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
        local prefix = card.sent_to_anki and "+ " or ""
        local book   = (card.book_title and card.book_title ~= "")
                       and card.book_title or _("Unknown book")
        local label  = prefix
                       .. (card.phrase or "") .. "  —  "
                       .. book .. "  (" .. (card.date or "") .. ")"

        local function open_viewer()
            local session = { open = true, image_version = 0, content_version = 0 }
            local function make_viewer(show_back)
                local v
                v = CardViewer:new {
                    card      = card,
                    show_back = show_back,
                    read_only = false,
                    on_show_answer = function()
                        -- Close whichever viewer is currently showing
                        -- (may differ from v after an async image update).
                        local cur = session.viewer or v
                        close_for_replacement(cur)
                        session.viewer = make_viewer(true)
                    end,
                    on_send = function()
                        local ok, err = AnkiSync.send_card(anki_config, card, base_config)
                        if ok and not CardStorage.mark_sent(card.phrase) then
                            return false, _("Anki accepted the card, but its sent state could not be saved")
                        end
                        return ok, err
                    end,
                    on_navigate_to_source = (ui and card.highlight_pos0) and function()
                        local cur = session.viewer
                        invalidate_viewer_session(session)
                        if cur then UIManager:close(cur) end
                        if menu_instance then UIManager:close(menu_instance) end
                        local event_name = ui.paging and "GotoPage" or "GotoXPointer"
                        ui:handleEvent(Event:new(event_name, card.highlight_pos0))
                    end or nil,
                    on_prepare_update = function(editing_card)
                        return CardStorage.ensure_identity(editing_card)
                    end,
                    on_update = function(updated_card)
                        local saved, save_err = CardStorage.update_card(card, updated_card)
                        if saved then invalidate_card_content(session) end
                        return saved, save_err
                    end,
                    on_regen_text = function()
                        local previous_show_back = true
                        close_for_replacement(session.viewer)
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
                                    notify_error(_("Regen failed: ") .. (new_prompt or "unknown"))
                                    session.viewer = make_viewer(previous_show_back)
                                    return
                                end
                                local candidate = copy_card(card)
                                candidate.text = new_text
                                candidate.image_prompt = new_prompt
                                if not CardStorage.update_card(card, candidate) then
                                    notify_error(_("Could not save regenerated sentence"))
                                    session.viewer = make_viewer(previous_show_back)
                                    return
                                end
                                for key in pairs(card) do card[key] = nil end
                                for key, value in pairs(candidate) do card[key] = value end
                                invalidate_card_content(session)
                                session.viewer = make_viewer(previous_show_back)
                                -- Kick off image generation with new prompt.
                                if new_prompt and ImageGenerator.images_enabled(base_config) then
                                    begin_image_request(base_config, card, session, nil, nil)
                                end
                            end)
                        end)
                    end,
                    on_regen_image = ImageGenerator.images_enabled(base_config) and function()
                        if not card.image_prompt or card.image_prompt == "" then
                            notify(_("No image prompt available"))
                            return
                        end
                        local old_image = card.image_path
                        notify(_("Regenerating image…"))
                        begin_image_request(base_config, card, session, function()
                                if old_image and old_image ~= "" then CardStorage.remove_image_if_unreferenced(old_image) end
                                UIManager:setDirty(nil, "full")
                                notify(_("New image loaded!"))
                            end, function(err)
                                notify_error(_("Image regen failed: ") .. (err or "unknown"))
                            end)
                    end or nil,
                    on_regen_ipa = function(new_phrase, updated_card, new_viewer)
                        NetworkMgr:runWhenOnline(function()
                            UIManager:scheduleIn(0.05, function()
                                local ipa, err = CardGenerator.generate_ipa(base_config, new_phrase)
                                if ipa then
                                    -- A later phrase edit supersedes this response.
                                    if updated_card.phrase ~= new_phrase then return end
                                    updated_card.ipa = ipa
                                    if not CardStorage.update_card(updated_card, updated_card) then
                                        notify_error(_("Could not save IPA update"))
                                        return
                                    end
                                    local still_shown = false
                                    for w in UIManager:topdown_widgets_iter() do
                                        if w == new_viewer then still_shown = true; break end
                                    end
                                    if still_shown then new_viewer:update() end
                                    notify(_("IPA updated"))
                                else
                                    notify_error(_("IPA regen failed: ") .. (err or "unknown"))
                                end
                            end)
                        end)
                    end,
                    on_close = function() invalidate_viewer_session(session) end,
                }
                UIManager:show(v)
                return v
            end
            session.viewer = make_viewer(false)
            -- Auto-regenerate image if missing (e.g. synced card).
            -- Only poll AnkiVocab for cards that were created via AnkiVocab
            -- (_ankivocab_word is set); otherwise use the local image_prompt.
            local img_cfg = base_config
            local is_ankivocab_card = card._ankivocab_word and card._ankivocab_word ~= ""
            if is_ankivocab_card then
                img_cfg = {}
                for k, v in pairs(base_config) do img_cfg[k] = v end
                img_cfg.image_provider = "ankivocab"
                img_cfg._ankivocab_word = card._ankivocab_word
            end
            local has_image_source = (card.image_prompt and card.image_prompt ~= "")
                                  or is_ankivocab_card
            if (not card.image_path or card.image_path == "")
               and has_image_source
               and ImageGenerator.images_enabled(img_cfg)
               and NetworkMgr:isOnline() then
                begin_image_request(img_cfg, card, session, nil, nil)
            end
            poll_pending_audio(base_config, card, session)
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
                                -- A filtered list ordinal is not the raw storage index.
                                -- Migrate legacy records before deleting by durable id.
                                if not CardStorage.ensure_identity(card) then
                                    notify_error(_("Could not delete card: local persistence failed"))
                                    return
                                end
                                local deleted = CardStorage.delete_card_by_id(card._storage_id)
                                if deleted then
                                    refresh()
                                else
                                    notify_error(_("Could not delete card: local persistence failed"))
                                end
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
