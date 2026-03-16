-- Anki Settings UI -- lets the user change URL, Deck, and Tags.
-- Note type is fixed at "English" (read-only).
-- Settings are saved to anki_flashcards_settings.json in the KOReader data dir.

local ButtonDialog   = require("ui/widget/buttondialog")
local InputDialog    = require("ui/widget/inputdialog")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")

local AnkiSync       = require("anki_sync")
local CardStorage    = require("card_storage")
local CardSync       = require("card_sync")

local SettingsViewer = {}

-- Editable fields (note type "English" is fixed).
local FIELDS = {
    { key = "url",                  label = "AnkiConnect URL",     hint = "http://192.168.x.x:8765" },
    { key = "deck",                 label = "Deck",                hint = "English::Koreader" },
    { key = "tags",                 label = "Tags (comma-sep)",    hint = "KOReader" },
    { key = "elevenlabs_voice_id",  label = "ElevenLabs Voice ID", hint = "JBFqnCBsd6RMkjVDRZzb" },
}

-- Show the settings dialog. base_config is the full CONFIGURATION table
-- from main.lua (with nested .anki subtable).
-- on_saved(new_cfg) is called after every field save so the caller can update
-- its live copy.
function SettingsViewer.show(base_config, on_saved)
    -- Extract the anki subtable from the full config.
    local anki_base = base_config
    if base_config and type(base_config.anki) == "table" then
        anki_base = base_config.anki
    end

    -- Work on a merged copy so saved JSON values take priority.
    local cfg = {}
    if anki_base then
        for k, v in pairs(anki_base) do cfg[k] = v end
    end
    local saved = CardStorage.load_anki_settings()
    if saved then
        for k, v in pairs(saved) do cfg[k] = v end
    end

    local function val(key)
        local v = cfg[key]
        if key == "tags" and type(v) == "table" then
            return table.concat(v, ", ")
        end
        if v == nil or v == "" then return "" end
        return tostring(v)
    end

    local function short(key, max)
        local v = val(key)
        max = max or 30
        if #v > max then return v:sub(1, max) .. ".." end
        return v ~= "" and v or "(not set)"
    end

    local function show_settings_dialog()
        local dlg
        local buttons = {}

        -- Read-only row for fixed note type.
        table.insert(buttons, {{
            text     = _("Note type: English (fixed)"),
            callback = function() end,
        }})

        for _i, f in ipairs(FIELDS) do
            local fref = f
            table.insert(buttons, {{
                text     = fref.label .. ": " .. short(fref.key),
                callback = function()
                    UIManager:close(dlg)
                    local edit_dlg
                    edit_dlg = InputDialog:new {
                        title      = _("Anki - ") .. fref.label,
                        input      = val(fref.key),
                        input_hint = fref.hint,
                        buttons    = {{
                            {
                                text     = _("Cancel"),
                                callback = function()
                                    UIManager:close(edit_dlg)
                                    show_settings_dialog()
                                end,
                            },
                            {
                                text             = _("Save"),
                                is_enter_default = true,
                                callback         = function()
                                    local new_val = edit_dlg:getInputText() or ""
                                    UIManager:close(edit_dlg)
                                    if fref.key == "tags" then
                                        local tag_list = {}
                                        for t in new_val:gmatch("[^,]+") do
                                            local trimmed = t:match("^%s*(.-)%s*$")
                                            if trimmed ~= "" then
                                                table.insert(tag_list, trimmed)
                                            end
                                        end
                                        cfg.tags = #tag_list > 0 and tag_list or { "KOReader" }
                                    else
                                        cfg[fref.key] = new_val
                                    end
                                    CardStorage.save_anki_settings(cfg)
                                    if on_saved then on_saved(cfg) end
                                    show_settings_dialog()
                                end,
                            },
                        }},
                    }
                    UIManager:show(edit_dlg)
                    edit_dlg:onShowKeyboard()
                end,
            }})
        end

        -- Text provider toggle.
        local TEXT_PROVIDERS = { "dashscope", "gemini", "openrouter" }
        local cur_text = cfg.text_provider or "dashscope"
        local text_label = _("Text Provider: ") .. cur_text
        table.insert(buttons, {{
            text     = text_label,
            callback = function()
                local idx = 1
                for i, p in ipairs(TEXT_PROVIDERS) do
                    if p == cur_text then idx = i; break end
                end
                local next_tp = TEXT_PROVIDERS[(idx % #TEXT_PROVIDERS) + 1]
                cfg.text_provider = next_tp
                CardStorage.save_anki_settings(cfg)
                if on_saved then on_saved(cfg) end
                UIManager:close(dlg)
                show_settings_dialog()
            end,
        }})

        -- Image provider toggle.
        local IMAGE_PROVIDERS = { "dashscope", "gemini", "pollinations" }
        local cur_provider = cfg.image_provider or "dashscope"
        local provider_label = _("Image Provider: ") .. cur_provider
        table.insert(buttons, {{
            text     = provider_label,
            callback = function()
                -- Cycle to next provider.
                local idx = 1
                for i, p in ipairs(IMAGE_PROVIDERS) do
                    if p == cur_provider then idx = i; break end
                end
                local next_provider = IMAGE_PROVIDERS[(idx % #IMAGE_PROVIDERS) + 1]
                cfg.image_provider = next_provider
                CardStorage.save_anki_settings(cfg)
                if on_saved then on_saved(cfg) end
                UIManager:close(dlg)
                show_settings_dialog()
            end,
        }})

        -- ── API Keys section ─────────────────────────────────────────────
        local API_KEY_FIELDS = {
            { key = "dashscope_api_key",  label = "DashScope API Key" },
            { key = "gemini_api_key",     label = "Gemini API Key" },
            { key = "openrouter_api_key", label = "OpenRouter API Key" },
            { key = "elevenlabs_api_key", label = "ElevenLabs API Key" },
        }

        local function mask_key(k)
            if not k or k == "" or k:find("^YOUR_") then return "(not set)" end
            if #k <= 8 then return string.rep("*", #k) end
            return string.rep("*", #k - 4) .. k:sub(-4)
        end

        for _idx, akf in ipairs(API_KEY_FIELDS) do
            local aref = akf
            local raw = cfg[aref.key] or ""
            table.insert(buttons, {{
                text     = aref.label .. ": " .. mask_key(raw),
                callback = function()
                    UIManager:close(dlg)
                    local key_dlg
                    key_dlg = InputDialog:new {
                        title      = _(aref.label),
                        input      = (raw:find("^YOUR_") and "" or raw),
                        input_hint = _("Paste your API key here"),
                        buttons    = {{
                            {
                                text     = _("Cancel"),
                                callback = function()
                                    UIManager:close(key_dlg)
                                    show_settings_dialog()
                                end,
                            },
                            {
                                text             = _("Save"),
                                is_enter_default = true,
                                callback         = function()
                                    local new_key = key_dlg:getInputText() or ""
                                    UIManager:close(key_dlg)
                                    cfg[aref.key] = new_key
                                    CardStorage.save_anki_settings(cfg)
                                    if on_saved then on_saved(cfg) end
                                    show_settings_dialog()
                                end,
                            },
                        }},
                    }
                    UIManager:show(key_dlg)
                    key_dlg:onShowKeyboard()
                end,
            }})
        end

        -- Auto-Send on WiFi toggle (opt-in, disabled by default).
        local auto_label = cfg.auto_send_wifi
                           and _("Auto-Send on WiFi: ON (tap to disable)")
                           or  _("Auto-Send on WiFi: OFF (tap to enable)")
        table.insert(buttons, {{
            text     = auto_label,
            callback = function()
                cfg.auto_send_wifi = not cfg.auto_send_wifi
                CardStorage.save_anki_settings(cfg)
                if on_saved then on_saved(cfg) end
                UIManager:close(dlg)
                show_settings_dialog()
            end,
        }})

        -- TTS Audio toggle (requires elevenlabs_api_key in configuration.lua).
        local tts_label = cfg.tts_enabled
                           and _("TTS Audio (ElevenLabs): ON")
                           or  _("TTS Audio (ElevenLabs): OFF")
        table.insert(buttons, {{
            text     = tts_label,
            callback = function()
                cfg.tts_enabled = not cfg.tts_enabled
                CardStorage.save_anki_settings(cfg)
                if on_saved then on_saved(cfg) end
                UIManager:close(dlg)
                show_settings_dialog()
            end,
        }})

        -- Test connection to configured AnkiConnect URL.
        table.insert(buttons, {{
            text     = _("Test Connection"),
            callback = function()
                local url = cfg.url
                if not url or url == "" then
                    UIManager:show(Notification:new {
                        text = _("Set the AnkiConnect URL first"),
                        timeout = 3,
                    })
                    return
                end
                local ok, err = AnkiSync.test_connection(url)
                if ok then
                    UIManager:show(Notification:new {
                        text = _("Connection OK"),
                        timeout = 3,
                    })
                else
                    UIManager:show(Notification:new {
                        text = _("Cannot reach Anki. Check URL and that Anki is running."),
                        timeout = 5,
                    })
                end
            end,
        }})

        -- Cloud Sync via SyncService (Dropbox/WebDAV).
        local sync_label
        if cfg.sync_server then
            local sname = cfg.sync_server.name or cfg.sync_server.address or "Cloud"
            sync_label = _("Cloud Sync: ") .. sname
        else
            sync_label = _("Cloud Sync: (not configured)")
        end
        table.insert(buttons, {{
            text     = sync_label,
            callback = function()
                UIManager:close(dlg)
                CardSync.show_cloud_sync_dialog(cfg, function(new_cfg)
                    cfg = new_cfg
                    if on_saved then on_saved(new_cfg) end
                    show_settings_dialog()
                end)
            end,
        }})

        table.insert(buttons, {{
            text     = _("Close"),
            callback = function() UIManager:close(dlg) end,
        }})

        dlg = ButtonDialog:new {
            title   = _("Anki Settings"),
            buttons = buttons,
        }
        UIManager:show(dlg)
    end

    show_settings_dialog()
end

return SettingsViewer
