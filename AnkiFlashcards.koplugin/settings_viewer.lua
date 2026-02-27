-- Anki Settings UI -- lets the user change URL, Deck, and Tags.
-- Note type is fixed at "English" (read-only).
-- Settings are saved to anki_flashcards_settings.json in the KOReader data dir.

local ButtonDialog   = require("ui/widget/buttondialog")
local InputDialog    = require("ui/widget/inputdialog")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")

local CardStorage    = require("card_storage")

local SettingsViewer = {}

-- Editable fields (note type "English" is fixed).
local FIELDS = {
    { key = "url",  label = "AnkiConnect URL", hint = "http://192.168.x.x:8765" },
    { key = "deck", label = "Deck",             hint = "English::Koreader" },
    { key = "tags", label = "Tags (comma-sep)", hint = "KOReader" },
}

-- Scan the local subnet for AnkiConnect on port 8765.
-- Returns "http://IP:8765" on success, or nil + error string.
local function discover_anki()
    local socket = require("socket")
    local http   = require("socket.http")
    local ltn12  = require("ltn12")
    local json   = require("json")

    local logger = require("logger")

    -- Get our local IP. The UDP trick returns 0.0.0.0 on KOReader,
    -- so fall back to parsing Linux network commands.
    local our_ip

    -- Try: ip route get (most reliable on Linux)
    local pipe = io.popen("ip -4 route get 8.8.8.8 2>/dev/null")
    if pipe then
        local out = pipe:read("*a")
        pipe:close()
        our_ip = out:match("src%s+(%d+%.%d+%.%d+%.%d+)")
    end

    -- Fallback: ifconfig wlan0 / eth0
    if not our_ip or our_ip == "0.0.0.0" then
        local pipe2 = io.popen("ifconfig wlan0 2>/dev/null || ifconfig eth0 2>/dev/null")
        if pipe2 then
            local out = pipe2:read("*a")
            pipe2:close()
            our_ip = out:match("inet%s+(%d+%.%d+%.%d+%.%d+)")
        end
    end

    if not our_ip or our_ip == "0.0.0.0" or our_ip == "127.0.0.1" then
        return nil, "Cannot determine local IP"
    end
    logger.dbg("AnkiDiscover: our IP =", our_ip)

    local prefix = our_ip:match("^(%d+%.%d+%.%d+)%.")
    if not prefix then return nil, "Cannot determine subnet from " .. our_ip end
    logger.dbg("AnkiDiscover: scanning", prefix .. ".1-254 :8765")

    for i = 1, 254 do
        local ip = prefix .. "." .. i
        local tcp = socket.tcp()
        tcp:settimeout(0.5)
        local ok, err = tcp:connect(ip, 8765)
        tcp:close()
        if ok then
            logger.dbg("AnkiDiscover: port open on", ip)
            -- Port is open -- verify it is actually AnkiConnect.
            http.TIMEOUT = 2
            local response = {}
            local body = '{"action":"requestPermission","version":6}'
            local ok2, code = http.request {
                url     = "http://" .. ip .. ":8765",
                method  = "POST",
                headers = {
                    ["Content-Type"]   = "application/json",
                    ["Content-Length"] = tostring(#body),
                },
                source = ltn12.source.string(body),
                sink   = ltn12.sink.table(response),
            }
            if ok2 and tostring(code) == "200" then
                local ok3, data = pcall(json.decode, table.concat(response))
                if ok3 and data and data.result then
                    return "http://" .. ip .. ":8765"
                end
            end
        end
    end
    return nil, "Not found on " .. prefix .. ".x:8765"
end

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

        -- Discover AnkiConnect on LAN.
        table.insert(buttons, {{
            text     = _("Discover Anki on LAN"),
            callback = function()
                UIManager:close(dlg)
                local scanning = Notification:new {
                    text    = _("Scanning local network.."),
                    timeout = 120,
                }
                UIManager:show(scanning)
                UIManager:scheduleIn(0.1, function()
                    local url, err = discover_anki()
                    UIManager:close(scanning)
                    UIManager:show(Notification:new {
                        text    = url and (_("Found: ") .. url) or (err or "Not found"),
                        timeout = 5,
                    })
                    if url then
                        cfg.url = url
                        CardStorage.save_anki_settings(cfg)
                        if on_saved then on_saved(cfg) end
                    end
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
