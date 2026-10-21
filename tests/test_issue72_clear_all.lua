-- LuaJIT regression harness for Issue #72 clear-all persistence integrity.
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

-- A failed clear must leave both the live card list and every image untouched.
-- After a durable empty-list write, the same operation removes records and assets.
do
    local saved_open, saved_rename, saved_remove = io.open, os.rename, os.remove
    local files, encoded, serial, removed = {}, {}, 0, {}
    local fail_rename = false

    package.loaded["card_storage"] = nil
    package.loaded["datastorage"] = nil
    package.loaded["json"] = nil
    package.preload["datastorage"] = function()
        return { getDataDir = function() return "/clear-all-test" end }
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
    local cards_path = "/clear-all-test/anki_flashcards.json"
    local first_image = "/clear-all-test/first.png"
    local second_image = "/clear-all-test/second.png"
    local function seed()
        files, encoded, serial, removed = {}, {}, 0, {}
        encoded.live = {
            { phrase = "first", image_path = first_image },
            { phrase = "second", image_path = second_image },
        }
        files[cards_path] = "live"
        files[first_image], files[second_image] = "first-image", "second-image"
    end

    seed()
    fail_rename = true
    local cleared, err = CardStorage.clear_all()
    assert(not cleared and err == "write_failed", "failed clear persistence must return write_failed")
    local retained = CardStorage.load_cards()
    assert(#retained == 2 and retained[1].phrase == "first" and retained[2].phrase == "second",
           "failed clear must retain every card record")
    assert(files[first_image] == "first-image" and files[second_image] == "second-image",
           "failed clear must retain every image asset")
    assert(#removed == 1 and removed[1]:find(".tmp-", 1, true),
           "failed clear may clean only the temporary database file")

    seed()
    fail_rename = false
    cleared, err = CardStorage.clear_all()
    assert(cleared and err == nil, "successful clear must return true")
    assert(#CardStorage.load_cards() == 0, "successful clear must remove every card record")
    assert(files[first_image] == nil and files[second_image] == nil,
           "successful clear must remove every image asset")
    assert(removed[1] == first_image and removed[2] == second_image,
           "image removal must occur after successful persistence")

    io.open, os.rename, os.remove = saved_open, saved_rename, saved_remove
    package.loaded["card_storage"] = nil
end

-- The Manage menu must stay open and report a local error on failed clear; it
-- must only report success and close after storage confirms the write.
do
    local state
    local function setup(clear_result)
        state = { shown = {}, closed = 0, clear_calls = 0 }
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
                clear_all = function()
                    state.clear_calls = state.clear_calls + 1
                    return clear_result, clear_result and nil or "write_failed"
                end,
                load_cards = function() return {} end,
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
    local function start_clear(manager)
        manager.show_manage({})
        local manage_menu = state.shown[#state.shown]
        manage_menu.item_table[6].callback()
        local confirm = state.shown[#state.shown]
        confirm.ok_callback()
    end

    start_clear(setup(false))
    assert(state.clear_calls == 1, "failed clear must call storage once")
    assert(state.closed == 0, "failed clear must preserve Manage menu navigation")
    assert(state.shown[#state.shown].text == "Could not clear cards: local persistence failed",
           "failed clear must show a local-persistence error")

    start_clear(setup(true))
    assert(state.clear_calls == 1, "successful clear must call storage once")
    assert(state.closed == 1, "successful clear must close the Manage menu")
    assert(state.shown[#state.shown].text == "All cards cleared",
           "successful clear must show success feedback")
end

print("issue #72 clear-all harness: PASS")