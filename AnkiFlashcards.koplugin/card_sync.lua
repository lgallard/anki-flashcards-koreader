-- Cloud sync for AnkiFlashcards via KOReader's SyncService (Dropbox/WebDAV).
-- Three-way merge of anki_flashcards.json across devices.

local ButtonDialog  = require("ui/widget/buttondialog")
local ConfirmBox    = require("ui/widget/confirmbox")
local DataStorage   = require("datastorage")
local Notification  = require("ui/widget/notification")
local UIManager     = require("ui/uimanager")
local json          = require("json")
local _             = require("gettext")

local CardStorage   = require("card_storage")

local CARDS_FILE = DataStorage:getDataDir() .. "/anki_flashcards.json"

local CardSync = {}

-- SyncService was moved into KOReader's Cloud Storage plugin in 2026.08.
-- The plugin instance is available from ReaderUI on current KOReader; retain
-- the old module as a fallback for older releases.
local function get_sync_service(ui)
    if ui and ui.cloudstorage then
        return ui.cloudstorage
    end
    local ok, legacy_sync_service = pcall(require, "frontend/apps/cloudstorage/syncservice")
    if ok then return legacy_sync_service end
end

-- ── Helpers ──────────────────────────────────────────────────────────────

local function normalize(s)
    return (s or ""):lower():match("^%s*(.-)%s*$")
end

local function card_key(card)
    return normalize(card.phrase) .. "__" .. normalize(card.book_title)
end

local function read_json_array(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then return data end
    return {}
end

local function write_json_array(path, data)
    local f = io.open(path, "w")
    if not f then return false end
    local ok, encoded = pcall(json.encode, data)
    if not ok then f:close(); return false end
    f:write(encoded)
    f:close()
    return true
end

--- Return the effective timestamp for a card (updated_at or date fallback).
local function card_timestamp(card)
    if card.updated_at then return card.updated_at end
    -- Fallback: parse date string "YYYY-MM-DD" into epoch.
    if card.date then
        local y, m, d = card.date:match("^(%d+)-(%d+)-(%d+)$")
        if y then
            return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
        end
    end
    return 0
end

-- ── Three-Way Merge ──────────────────────────────────────────────────────

--- SyncService merge callback.
-- @param local_path   Path to the local cards file.
-- @param cached_path  Path to the cached baseline (last upload snapshot).
-- @param income_path  Path to the file just downloaded from the cloud.
-- @return true on success (required by SyncService).
function CardSync.merge_cards(local_path, cached_path, income_path)
    local local_cards  = read_json_array(local_path)
    local cached_cards = read_json_array(cached_path)
    local income_cards = read_json_array(income_path)

    -- Build index tables keyed by card_key.
    local function index_by_key(cards)
        local idx = {}
        for _, c in ipairs(cards) do
            idx[card_key(c)] = c
        end
        return idx
    end

    local local_idx  = index_by_key(local_cards)
    local cached_idx = index_by_key(cached_cards)
    local income_idx = index_by_key(income_cards)

    local merged = {}
    local seen   = {}

    -- Pass 1: iterate local cards.
    for _, lc in ipairs(local_cards) do
        local key = card_key(lc)
        if not seen[key] then
            seen[key] = true
            local rc = income_idx[key]
            local cc = cached_idx[key]

            if rc then
                -- Card exists in both local and remote → keep newer.
                local lt = card_timestamp(lc)
                local rt = card_timestamp(rc)
                if rt > lt then
                    -- Remote is newer — take remote but preserve local image_path.
                    rc.image_path = lc.image_path or ""
                    table.insert(merged, rc)
                else
                    table.insert(merged, lc)
                end
            elseif cc and #income_cards > 0 then
                -- Card in local + cached but NOT in remote → deleted remotely.
                -- Drop it (don't add to merged). But only if income is non-empty
                -- (empty income = first sync, not a mass delete).
            else
                -- Card only in local → new on this device → keep.
                table.insert(merged, lc)
            end
        end
    end

    -- Pass 2: remote-only cards (in income but not in local).
    for _, rc in ipairs(income_cards) do
        local key = card_key(rc)
        if not seen[key] then
            seen[key] = true
            local cc = cached_idx[key]

            if not local_idx[key] and not cc then
                -- New on other device → add (strip device-local image_path).
                rc.image_path = ""
                table.insert(merged, rc)
            end
            -- If in cached but not local → deleted locally → don't re-add.
        end
    end

    write_json_array(local_path, merged)
    return true
end

-- ── Sync Runner ──────────────────────────────────────────────────────────

function CardSync.run_sync(server, is_silent, ui)
    local sync_service = get_sync_service(ui)
    if not sync_service or not sync_service.sync then return false end
    if ui and sync_service == ui.cloudstorage then
        -- Cloud Storage plugin (2026.08+): Cloud:sync is an instance method.
        sync_service:sync(server, CARDS_FILE, CardSync.merge_cards, is_silent)
    else
        -- Legacy SyncService module: SyncService.sync is a static function.
        sync_service.sync(server, CARDS_FILE, CardSync.merge_cards, is_silent)
    end
    return true
end

-- ── Cloud Sync Dialog ────────────────────────────────────────────────────

function CardSync.show_cloud_sync_dialog(cfg, on_saved, ui)
    local sync_service = get_sync_service(ui)
    if not sync_service then
        UIManager:show(Notification:new { text = _("Cloud storage is unavailable."), timeout = 3 })
        return
    end
    if not cfg.sync_server then
        -- No server configured → open picker directly.
        local on_confirm = function(server)
            cfg.sync_server = server
            CardStorage.save_anki_settings(cfg)
            if on_saved then on_saved(cfg) end
            UIManager:show(Notification:new {
                text = _("Cloud sync server saved"),
                timeout = 3,
            })
            -- Trigger an initial sync.
            CardSync.run_sync(server, false, ui)
        end
        if sync_service.onShowCloudStorageList then
            sync_service:onShowCloudStorageList(on_confirm)
        else
            local sync_settings = sync_service:new{}
            sync_settings.onClose = function(this) UIManager:close(this) end
            sync_settings.onConfirm = on_confirm
            UIManager:show(sync_settings)
        end
        return
    end

    -- Server is configured — show action dialog.
    local server_name = cfg.sync_server.name or cfg.sync_server.address or "Cloud"
    local dlg
    dlg = ButtonDialog:new {
        title   = _("Cloud Sync"),
        buttons = {
            {{
                text     = _("Sync Now"),
                callback = function()
                    UIManager:close(dlg)
                    CardSync.run_sync(cfg.sync_server, false, ui)
                end,
            }},
            {{
                text     = _("Change Server"),
                callback = function()
                    UIManager:close(dlg)
                    local on_confirm = function(new_server)
                        -- Invalidate cached baseline when changing servers.
                        os.remove(CARDS_FILE .. ".sync")
                        cfg.sync_server = new_server
                        CardStorage.save_anki_settings(cfg)
                        if on_saved then on_saved(cfg) end
                        UIManager:show(Notification:new {
                            text = _("Server changed"),
                            timeout = 3,
                        })
                    end
                    if sync_service.onShowCloudStorageList then
                        sync_service:onShowCloudStorageList(on_confirm)
                    else
                        local sync_settings = sync_service:new{}
                        sync_settings.onClose = function(this) UIManager:close(this) end
                        sync_settings.onConfirm = on_confirm
                        UIManager:show(sync_settings)
                    end
                end,
            }},
            {{
                text     = _("Remove Server"),
                callback = function()
                    UIManager:close(dlg)
                    UIManager:show(ConfirmBox:new {
                        text = _("Remove cloud sync server?"),
                        ok_text = _("Remove"),
                        ok_callback = function()
                            os.remove(CARDS_FILE .. ".sync")
                            cfg.sync_server = nil
                            CardStorage.save_anki_settings(cfg)
                            if on_saved then on_saved(cfg) end
                            UIManager:show(Notification:new {
                                text = _("Cloud sync removed"),
                                timeout = 3,
                            })
                        end,
                    })
                end,
            }},
            {{
                text     = _("Close"),
                callback = function() UIManager:close(dlg) end,
            }},
        },
    }
    UIManager:show(dlg)
end

return CardSync
