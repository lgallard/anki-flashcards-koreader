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

local SettingsViewer = {}

-- Editable fields (note type "English" is fixed).
local FIELDS = {
    { key = "url",  label = "AnkiConnect URL", hint = "http://192.168.x.x:8765" },
    { key = "deck", label = "Deck",             hint = "English::Koreader" },
    { key = "tags", label = "Tags (comma-sep)", hint = "KOReader" },
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
                        text = _("Connected to ") .. url,
                        timeout = 3,
                    })
                else
                    UIManager:show(Notification:new {
                        text = _("Cannot reach ") .. url
                            .. " - check IP and that Anki is running",
                        timeout = 8,
                    })
                end
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
