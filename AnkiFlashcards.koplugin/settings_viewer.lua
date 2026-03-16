-- Anki Settings UI — grouped into submenus for easier navigation.
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

    -- ── Shared helpers ───────────────────────────────────────────────────

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

    local function mask_key(k)
        if not k or k == "" or k:find("^YOUR_") then return "(not set)" end
        if #k <= 8 then return string.rep("*", #k) end
        return string.rep("*", #k - 4) .. k:sub(-4)
    end

    local function save()
        CardStorage.save_anki_settings(cfg)
        if on_saved then on_saved(cfg) end
    end

    -- Helper: show an InputDialog for editing a text field.
    local function edit_field(title, key, hint, parent_fn, transform)
        local edit_dlg
        edit_dlg = InputDialog:new {
            title      = _(title),
            input      = val(key),
            input_hint = hint,
            buttons    = {{
                {
                    text     = _("Cancel"),
                    callback = function()
                        UIManager:close(edit_dlg)
                        parent_fn()
                    end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local new_val = edit_dlg:getInputText() or ""
                        UIManager:close(edit_dlg)
                        if transform then
                            transform(new_val)
                        else
                            cfg[key] = new_val
                        end
                        save()
                        parent_fn()
                    end,
                },
            }},
        }
        UIManager:show(edit_dlg)
        edit_dlg:onShowKeyboard()
    end

    -- Helper: show an InputDialog for editing an API key.
    local function edit_key(label, key, parent_fn)
        local raw = cfg[key] or ""
        local edit_dlg
        edit_dlg = InputDialog:new {
            title      = _(label),
            input      = (raw:find("^YOUR_") and "" or raw),
            input_hint = _("Paste your API key here"),
            buttons    = {{
                {
                    text     = _("Cancel"),
                    callback = function()
                        UIManager:close(edit_dlg)
                        parent_fn()
                    end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local new_key = edit_dlg:getInputText() or ""
                        UIManager:close(edit_dlg)
                        cfg[key] = new_key
                        save()
                        parent_fn()
                    end,
                },
            }},
        }
        UIManager:show(edit_dlg)
        edit_dlg:onShowKeyboard()
    end

    -- Helper: cycle through a list of options for a toggle setting.
    local function make_cycle_button(label_prefix, key, options, parent_fn)
        local cur = cfg[key] or options[1]
        return {{
            text     = _(label_prefix) .. cur,
            callback = function()
                local idx = 1
                for i, p in ipairs(options) do
                    if p == cur then idx = i; break end
                end
                cfg[key] = options[(idx % #options) + 1]
                save()
                UIManager:close(parent_fn._dlg)
                parent_fn()
            end,
        }}
    end

    -- ── Submenu: Anki Connection ─────────────────────────────────────────

    local function show_anki_connection()
        local sub_dlg
        local buttons = {}

        -- Read-only note type.
        table.insert(buttons, {{
            text     = _("Note type: English (fixed)"),
            callback = function() end,
        }})

        -- Editable fields.
        local ANKI_FIELDS = {
            { key = "url",  label = "AnkiConnect URL", hint = "http://192.168.x.x:8765" },
            { key = "deck", label = "Deck",            hint = "English::Koreader" },
            { key = "tags", label = "Tags (comma-sep)", hint = "KOReader" },
        }
        for _i, f in ipairs(ANKI_FIELDS) do
            local fref = f
            table.insert(buttons, {{
                text     = fref.label .. ": " .. short(fref.key),
                callback = function()
                    UIManager:close(sub_dlg)
                    local transform
                    if fref.key == "tags" then
                        transform = function(new_val)
                            local tag_list = {}
                            for t in new_val:gmatch("[^,]+") do
                                local trimmed = t:match("^%s*(.-)%s*$")
                                if trimmed ~= "" then
                                    table.insert(tag_list, trimmed)
                                end
                            end
                            cfg.tags = #tag_list > 0 and tag_list or { "KOReader" }
                        end
                    end
                    edit_field("Anki - " .. fref.label, fref.key, fref.hint,
                              show_anki_connection, transform)
                end,
            }})
        end

        -- Test connection.
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
                local ok = AnkiSync.test_connection(url)
                UIManager:show(Notification:new {
                    text = ok and _("Connection OK")
                              or _("Cannot reach Anki. Check URL and that Anki is running."),
                    timeout = ok and 3 or 5,
                })
            end,
        }})

        table.insert(buttons, {{
            text     = _("Back"),
            callback = function() UIManager:close(sub_dlg); show_main() end,
        }})

        sub_dlg = ButtonDialog:new {
            title   = _("Anki Connection"),
            buttons = buttons,
        }
        UIManager:show(sub_dlg)
    end

    -- ── Submenu: AI Providers ────────────────────────────────────────────

    local function show_ai_providers()
        local sub_dlg
        show_ai_providers = function()
            local buttons = {}
            show_ai_providers._dlg = nil

            table.insert(buttons, make_cycle_button(
                "Text: ", "text_provider",
                { "dashscope", "gemini", "openrouter" }, show_ai_providers))

            table.insert(buttons, make_cycle_button(
                "Image: ", "image_provider",
                { "dashscope", "gemini", "pollinations" }, show_ai_providers))

            table.insert(buttons, {{
                text     = _("Back"),
                callback = function() UIManager:close(sub_dlg); show_main() end,
            }})

            sub_dlg = ButtonDialog:new {
                title   = _("AI Providers"),
                buttons = buttons,
            }
            show_ai_providers._dlg = sub_dlg
            UIManager:show(sub_dlg)
        end
        show_ai_providers()
    end

    -- ── Submenu: API Keys ────────────────────────────────────────────────

    local function show_api_keys()
        local sub_dlg
        local API_KEY_FIELDS = {
            { key = "dashscope_api_key",  label = "DashScope" },
            { key = "gemini_api_key",     label = "Gemini" },
            { key = "openrouter_api_key", label = "OpenRouter" },
            { key = "elevenlabs_api_key", label = "ElevenLabs" },
        }

        local buttons = {}
        for _i, akf in ipairs(API_KEY_FIELDS) do
            local aref = akf
            table.insert(buttons, {{
                text     = aref.label .. ": " .. mask_key(cfg[aref.key] or ""),
                callback = function()
                    UIManager:close(sub_dlg)
                    edit_key(aref.label .. " API Key", aref.key, show_api_keys)
                end,
            }})
        end

        table.insert(buttons, {{
            text     = _("Back"),
            callback = function() UIManager:close(sub_dlg); show_main() end,
        }})

        sub_dlg = ButtonDialog:new {
            title   = _("API Keys"),
            buttons = buttons,
        }
        UIManager:show(sub_dlg)
    end

    -- ── Submenu: Audio (TTS) ─────────────────────────────────────────────

    local function show_audio()
        local sub_dlg
        show_audio = function()
            local buttons = {}
            show_audio._dlg = nil

            local tts_label = cfg.tts_enabled
                and _("TTS Audio: ON")
                or  _("TTS Audio: OFF")
            table.insert(buttons, {{
                text     = tts_label,
                callback = function()
                    cfg.tts_enabled = not cfg.tts_enabled
                    save()
                    UIManager:close(sub_dlg)
                    show_audio()
                end,
            }})

            table.insert(buttons, {{
                text     = _("Voice ID: ") .. short("elevenlabs_voice_id"),
                callback = function()
                    UIManager:close(sub_dlg)
                    edit_field("ElevenLabs Voice ID", "elevenlabs_voice_id",
                              "JBFqnCBsd6RMkjVDRZzb", show_audio)
                end,
            }})

            table.insert(buttons, {{
                text     = _("Back"),
                callback = function() UIManager:close(sub_dlg); show_main() end,
            }})

            sub_dlg = ButtonDialog:new {
                title   = _("Audio (TTS)"),
                buttons = buttons,
            }
            show_audio._dlg = sub_dlg
            UIManager:show(sub_dlg)
        end
        show_audio()
    end

    -- ── Submenu: Sync ────────────────────────────────────────────────────

    local function show_sync()
        local sub_dlg
        show_sync = function()
            local buttons = {}
            show_sync._dlg = nil

            local auto_label = cfg.auto_send_wifi
                and _("Auto-Send on WiFi: ON")
                or  _("Auto-Send on WiFi: OFF")
            table.insert(buttons, {{
                text     = auto_label,
                callback = function()
                    cfg.auto_send_wifi = not cfg.auto_send_wifi
                    save()
                    UIManager:close(sub_dlg)
                    show_sync()
                end,
            }})

            local sync_name
            if cfg.sync_server then
                sync_name = cfg.sync_server.name or cfg.sync_server.address or "Cloud"
            end
            table.insert(buttons, {{
                text     = sync_name and (_("Cloud Sync: ") .. sync_name)
                                      or _("Cloud Sync: (not configured)"),
                callback = function()
                    UIManager:close(sub_dlg)
                    CardSync.show_cloud_sync_dialog(cfg, function(new_cfg)
                        cfg = new_cfg
                        save()
                        show_sync()
                    end)
                end,
            }})

            table.insert(buttons, {{
                text     = _("Back"),
                callback = function() UIManager:close(sub_dlg); show_main() end,
            }})

            sub_dlg = ButtonDialog:new {
                title   = _("Sync"),
                buttons = buttons,
            }
            show_sync._dlg = sub_dlg
            UIManager:show(sub_dlg)
        end
        show_sync()
    end

    -- ── Main settings screen ─────────────────────────────────────────────

    function show_main()
        local cur_text  = cfg.text_provider  or "dashscope"
        local cur_image = cfg.image_provider or "dashscope"

        local dlg
        dlg = ButtonDialog:new {
            title   = _("Anki Settings"),
            buttons = {
                {{ text = _("Anki Connection"),
                   callback = function() UIManager:close(dlg); show_anki_connection() end }},
                {{ text = _("AI Providers") .. "  (" .. cur_text .. " / " .. cur_image .. ")",
                   callback = function() UIManager:close(dlg); show_ai_providers() end }},
                {{ text = _("API Keys"),
                   callback = function() UIManager:close(dlg); show_api_keys() end }},
                {{ text = _("Audio (TTS)"),
                   callback = function() UIManager:close(dlg); show_audio() end }},
                {{ text = _("Sync"),
                   callback = function() UIManager:close(dlg); show_sync() end }},
                {{ text = _("Close"),
                   callback = function() UIManager:close(dlg) end }},
            },
        }
        UIManager:show(dlg)
    end

    show_main()
end

return SettingsViewer
