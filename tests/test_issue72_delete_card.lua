-- LuaJIT regression harness for Issue #72 delete persistence integrity.
package.path = "./AnkiFlashcards.koplugin/?.lua;" .. package.path

local function clone_entries(entries)
    local copy = {}
    for i, entry in ipairs(entries or {}) do
        local item = {}
        for key, value in pairs(entry) do item[key] = value end
        copy[i] = item
    end
    return copy
end

-- Failed card-list persistence must retain both the record and its image;
-- successful persistence must remove both.
do
    local saved_open, saved_rename, saved_remove = io.open, os.rename, os.remove
    local files, encoded, serial, removed = {}, {}, 0, {}
    local fail_rename = false

    package.loaded["card_storage"] = nil
    package.loaded["datastorage"] = nil
    package.loaded["json"] = nil
    package.preload["datastorage"] = function()
        return { getDataDir = function() return "/delete-card-test" end }
    end
    package.preload["json"] = function()
        return {
            encode = function(entries)
                serial = serial + 1
                local token = "encoded-" .. tostring(serial)
                encoded[token] = clone_entries(entries)
                return token
            end,
            decode = function(token) return clone_entries(encoded[token] or {}) end,
        }
    end
    io.open = function(path, mode)
        if mode == "r" then
            if files[path] == nil then return nil end
            return { read = function() return files[path] end, close = function() return true end }
        end
        if mode ~= "w" then return nil end
        local buffer = ""
        return {
            write = function(_, data) buffer = buffer .. data; return true end,
            close = function() files[path] = buffer; return true end,
        }
    end
    os.rename = function(from, to)
        if fail_rename then return false end
        files[to], files[from] = files[from], nil
        return true
    end
    os.remove = function(path)
        removed[#removed + 1] = path
        files[path] = nil
        return true
    end

    local CardStorage = require("card_storage")
    local cards_path = "/delete-card-test/anki_flashcards.json"
    local image_path = "/delete-card-test/card.png"
    local function seed()
        files, encoded, serial, removed = {}, {}, 0, {}
        encoded.live = { { phrase = "anchor", image_path = image_path } }
        files[cards_path] = "live"
        files[image_path] = "image"
    end

    seed()
    fail_rename = true
    local deleted, err = CardStorage.delete_card(1)
    assert(not deleted and err == "write_failed", "failed delete persistence must return write_failed")
    local retained = CardStorage.load_cards()
    assert(#retained == 1 and retained[1].phrase == "anchor", "failed delete must retain the card record")
    assert(files[image_path] == "image", "failed delete must retain the image asset")
    assert(#removed == 1 and removed[1]:find(".tmp-", 1, true),
           "failed delete may clean only the temporary database file")

    seed()
    fail_rename = false
    deleted, err = CardStorage.delete_card(1)
    assert(deleted and err == nil, "successful delete must return true")
    assert(#CardStorage.load_cards() == 0, "successful delete must remove the card record")
    assert(files[image_path] == nil, "successful delete must remove the image asset")
    assert(removed[#removed] == image_path, "image removal must occur after successful persistence")

    io.open, os.rename, os.remove = saved_open, saved_rename, saved_remove
    package.loaded["card_storage"] = nil
end

-- The card list must refresh only after a successful delete and must show an
-- explicit local-persistence error if deletion fails.
do
    local state
    local function setup(delete_result)
        state = { shown = {}, closed = 0, delete_calls = 0, cards = { { phrase = "anchor" } } }
        for _, name in ipairs({
            "card_manager", "gettext", "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/menu",
            "ui/widget/notification", "ui/widget/infomessage", "ui/uimanager", "ui/event", "card_storage",
            "anki_sync", "card_generator", "card_viewer", "image_generator", "ui/network/manager", "settings_viewer",
        }) do
            package.loaded[name] = nil
        end
        package.preload["gettext"] = function() return function(s) return s end end
        for _, name in ipairs({ "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/menu",
                                "ui/widget/notification", "ui/widget/infomessage" }) do
            package.preload[name] = function() return { new = function(_, options) return options end } end
        end
        package.preload["ui/uimanager"] = function()
            return {
                show = function(_, widget) state.shown[#state.shown + 1] = widget end,
                close = function() state.closed = state.closed + 1 end,
                setDirty = function() end,
            }
        end
        package.preload["ui/event"] = function() return {} end
        package.preload["card_storage"] = function()
            return {
                load_anki_settings = function() return nil end,
                load_cards = function() return state.cards end,
                delete_card = function()
                    state.delete_calls = state.delete_calls + 1
                    return delete_result
                end,
                mark_sent = function() return true end,
                update_card = function() return true end,
                update_image_path = function() return true end,
            }
        end
        package.preload["anki_sync"] = function() return { send_card = function() return true end } end
        package.preload["card_generator"] = function() return {} end
        package.preload["card_viewer"] = function() return {} end
        package.preload["image_generator"] = function() return { images_enabled = function() return false end } end
        package.preload["ui/network/manager"] = function() return {} end
        package.preload["settings_viewer"] = function() return { show = function() end } end
        return require("card_manager")
    end
    local function start_delete(manager)
        manager.show({})
        local list = state.shown[#state.shown]
        list.item_table[2].hold_callback()
        local actions = state.shown[#state.shown]
        actions.buttons[2][1].callback()
        local confirm = state.shown[#state.shown]
        confirm.ok_callback()
    end
    local function count_card_menus()
        local count = 0
        for _, widget in ipairs(state.shown) do
            if widget.title == "My Cards (1 card)" then count = count + 1 end
        end
        return count
    end

    start_delete(setup(false))
    assert(state.delete_calls == 1, "failed delete must call storage once")
    assert(count_card_menus() == 1, "failed delete must not refresh the card list")
    local error_widget = state.shown[#state.shown]
    assert(error_widget.text == "Could not delete card: local persistence failed",
           "failed delete must show a clear local-persistence error")

    start_delete(setup(true))
    assert(state.delete_calls == 1, "successful delete must call storage once")
    assert(count_card_menus() == 2, "successful delete must refresh the card list")
    assert(state.shown[#state.shown].title == "My Cards (1 card)",
           "successful delete must end on the refreshed card list")
end

print("issue #72 delete-card harness: PASS")
