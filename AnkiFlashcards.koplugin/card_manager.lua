-- Card Manager — menu-based list of saved Anki cards with send/delete actions.

local ButtonDialog   = require("ui/widget/buttondialog")
local ConfirmBox     = require("ui/widget/confirmbox")
local Menu           = require("ui/widget/menu")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")

local CardStorage    = require("card_storage")
local AnkiSync       = require("anki_sync")
local CardViewer     = require("card_viewer")
local SettingsViewer = require("settings_viewer")

local CardManager = {}

local function notify(text)
    UIManager:show(Notification:new { text = text })
end

-- Merge saved settings on top of base_config, returning a fresh table.
local function effective_config(base)
    local cfg = {}
    if base then
        for k, v in pairs(base) do cfg[k] = v end
    end
    local saved = CardStorage.load_anki_settings()
    if saved then
        for k, v in pairs(saved) do cfg[k] = v end
    end
    return cfg
end

function CardManager.show(base_config)
    local anki_config = effective_config(base_config)
    local menu_instance

    local function refresh()
        if menu_instance then UIManager:close(menu_instance) end
        CardManager.show(base_config)
    end

    local function is_anki_ready()
        return anki_config.url
            and anki_config.url ~= ""
            and not anki_config.url:find("192.168.x.x")
    end

    local function send_one(card)
        if not is_anki_ready() then
            notify(_("Anki URL not set. Use ⚙ Anki Settings."))
            return false
        end
        local ok, err = AnkiSync.send_card(anki_config, card)
        if ok then
            CardStorage.mark_sent(card.phrase)
            return true
        else
            notify(_("Anki error: ") .. (err or "unknown"))
            return false
        end
    end

    local cards      = CardStorage.load_cards()
    local item_table = {}

    -- ⚙ Anki Settings ─────────────────────────────────────────────────────────
    table.insert(item_table, {
        text = _("⚙ Anki Settings"),
        bold = true,
        callback = function()
            SettingsViewer.show(base_config, function(new_cfg)
                for k, v in pairs(new_cfg) do anki_config[k] = v end
            end)
        end,
    })

    -- → Send All Unsent ────────────────────────────────────────────────────────
    table.insert(item_table, {
        text = _("→ Send All Unsent to Anki"),
        bold = true,
        callback = function()
            local fresh        = CardStorage.load_cards()
            local sent, failed = 0, 0
            for _, card in ipairs(fresh) do
                if not card.sent_to_anki then
                    if send_one(card) then
                        sent = sent + 1
                    else
                        failed = failed + 1
                    end
                end
            end
            local msg = tostring(sent) .. _(" sent")
            if failed > 0 then msg = msg .. ", " .. tostring(failed) .. _(" failed") end
            notify(msg)
            refresh()
        end,
    })

    -- ✕ Clear All ──────────────────────────────────────────────────────────────
    table.insert(item_table, {
        text = _("✕ Clear All Cards"),
        bold = true,
        callback = function()
            UIManager:show(ConfirmBox:new {
                text        = _("Delete all saved cards? This cannot be undone."),
                ok_text     = _("Clear All"),
                ok_callback = function()
                    CardStorage.clear_all()
                    notify(_("All cards cleared"))
                    refresh()
                end,
            })
        end,
    })

    -- ── Card list ──────────────────────────────────────────────────────────────
    if #cards == 0 then
        table.insert(item_table, { text = _("(no saved cards yet)") })
    end

    for i, card in ipairs(cards) do
        local idx    = i
        local prefix = card.sent_to_anki and "✓ " or ""
        local book   = (card.book_title and card.book_title ~= "")
                       and card.book_title or _("Unknown book")
        local label  = prefix
                       .. (card.phrase or "") .. "  —  "
                       .. book .. "  (" .. (card.date or "") .. ")"

        table.insert(item_table, {
            text = label,
            callback = function()
                local dialog
                dialog = ButtonDialog:new {
                    title   = card.phrase or "",
                    buttons = {
                        {
                            {
                                text     = _("View"),
                                callback = function()
                                    UIManager:close(dialog)
                                    local viewer = CardViewer:new {
                                        card      = card,
                                        read_only = true,
                                        on_save   = function()
                                            return nil, _("Already saved")
                                        end,
                                        on_send   = function()
                                            return AnkiSync.send_card(anki_config, card)
                                        end,
                                    }
                                    UIManager:show(viewer)
                                end,
                            },
                            {
                                text     = _("Send to Anki"),
                                callback = function()
                                    UIManager:close(dialog)
                                    if send_one(card) then
                                        notify(_("Sent!"))
                                        refresh()
                                    end
                                end,
                            },
                            {
                                text     = _("Delete"),
                                callback = function()
                                    UIManager:close(dialog)
                                    UIManager:show(ConfirmBox:new {
                                        text        = _("Delete '")
                                                      .. (card.phrase or "") .. _("'?"),
                                        ok_text     = _("Delete"),
                                        ok_callback = function()
                                            CardStorage.delete_card(idx)
                                            refresh()
                                        end,
                                    })
                                end,
                            },
                        },
                        {{
                            text     = _("Cancel"),
                            callback = function() UIManager:close(dialog) end,
                        }},
                    },
                }
                UIManager:show(dialog)
            end,
        })
    end

    local count_label = #cards == 1
                        and _("1 card")
                        or (tostring(#cards) .. _(" cards"))

    menu_instance = Menu:new {
        title        = _("📚 Anki Cards (") .. count_label .. ")",
        item_table   = item_table,
        -- Critical: colon-call convention so `self` is the menu instance.
        onMenuChoice = function(self, item)
            if item and item.callback then item.callback() end
        end,
        show_parent  = UIManager,
    }
    UIManager:show(menu_instance)
end

return CardManager
