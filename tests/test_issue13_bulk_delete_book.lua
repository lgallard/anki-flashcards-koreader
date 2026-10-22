-- LuaJIT regression harness for issue #13 bulk deletion by book.
package.path = "./AnkiFlashcards.koplugin/?.lua;" .. package.path

local function clone(entries)
    local result = {}
    for i, card in ipairs(entries or {}) do
        result[i] = {}
        for key, value in pairs(card) do result[i][key] = value end
    end
    return result
end

-- Storage deletes only the requested exact group, retains media shared by cards
-- that survive, and never removes records/assets when persistence fails.
do
    local saved_open, saved_rename, saved_remove = io.open, os.rename, os.remove
    local files, encoded, serial, removed, fail_rename = {}, {}, 0, {}, false
    package.loaded["card_storage"], package.loaded["datastorage"], package.loaded["json"] = nil, nil, nil
    package.preload["datastorage"] = function()
        return { getDataDir = function() return "/issue13-storage" end }
    end
    package.preload["json"] = function()
        return {
            encode = function(entries)
                serial = serial + 1
                local token = "encoded-" .. serial
                encoded[token] = clone(entries)
                return token
            end,
            decode = function(token) return clone(encoded[token] or {}) end,
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
    local cards_path, shared = "/issue13-storage/anki_flashcards.json", "/issue13-storage/shared.png"
    local function seed()
        files, encoded, serial, removed = {}, {}, 0, {}
        encoded.live = {
            { phrase = "literal", book_title = "Unknown book", image_path = "/issue13-storage/literal.png" },
            { phrase = "missing", book_title = "", image_path = "/issue13-storage/missing.png" },
            { phrase = "target one", book_title = "Target", image_path = shared },
            { phrase = "target two", book_title = "Target", image_path = "/issue13-storage/target.png" },
            { phrase = "other", book_title = "Other", image_path = shared },
        }
        files[cards_path] = "live"
        files[shared], files["/issue13-storage/target.png"] = "shared", "target"
        files["/issue13-storage/literal.png"], files["/issue13-storage/missing.png"] = "literal", "missing"
    end

    seed()
    local ok, count = CardStorage.delete_cards_for_book("Target", false)
    assert(ok and count == 2, "exact selected book must report both deletions")
    local remaining = CardStorage.load_cards()
    assert(#remaining == 3 and remaining[1].phrase == "literal" and remaining[2].phrase == "missing"
           and remaining[3].phrase == "other", "exact selected book must retain other book groups")
    assert(files[shared] == "shared", "shared media referenced by a remaining card must survive")
    assert(files["/issue13-storage/target.png"] == nil, "unreferenced deleted-book media must be removed")

    ok, count = CardStorage.delete_cards_for_book(nil, true)
    assert(ok and count == 1, "missing-book selection must delete only missing-book cards")
    remaining = CardStorage.load_cards()
    assert(#remaining == 2 and remaining[1].phrase == "literal" and remaining[2].phrase == "other",
           "missing-book selection must not delete a literal Unknown book title")

    seed()
    fail_rename = true
    ok, count = CardStorage.delete_cards_for_book("Target", false)
    assert(not ok and count == "write_failed", "failed bulk persistence must report write_failed")
    remaining = CardStorage.load_cards()
    assert(#remaining == 5 and files[shared] == "shared" and files["/issue13-storage/target.png"] == "target",
           "failed bulk persistence must retain records and image assets")
    fail_rename = false
    io.open, os.rename, os.remove = saved_open, saved_rename, saved_remove
    package.loaded["card_storage"] = nil
end

-- Stats by Book exposes deletion only on long press, confirmation is inert until
-- accepted, and successful deletion refreshes stats with local-only feedback.
do
    local state = {
        shown = {}, closed = 0, delete_calls = 0, send_calls = 0,
        cards = {
            { phrase = "literal", book_title = "Unknown book", sent_to_anki = true },
            { phrase = "missing", book_title = "" },
            { phrase = "target", book_title = "Target" },
        },
    }
    for _, name in ipairs({
        "card_manager", "gettext", "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/menu",
        "ui/widget/notification", "ui/widget/infomessage", "ui/uimanager", "ui/event", "card_storage",
        "anki_sync", "card_generator", "card_viewer", "image_generator", "ui/network/manager", "settings_viewer",
    }) do package.loaded[name] = nil end
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
            delete_cards_for_book = function(title, include_missing)
                state.delete_calls = state.delete_calls + 1
                assert(title == "Unknown book" and not include_missing,
                       "literal Unknown book selection must retain its exact non-missing identity")
                state.cards = { state.cards[2], state.cards[3] }
                return true, 1
            end,
            mark_sent = function() return true end,
            update_card = function() return true end,
            update_image_path = function() return true end,
        }
    end
    package.preload["anki_sync"] = function()
        return { send_card = function() state.send_calls = state.send_calls + 1; return true end }
    end
    package.preload["card_generator"] = function() return {} end
    package.preload["card_viewer"] = function() return {} end
    package.preload["image_generator"] = function() return { images_enabled = function() return false end } end
    package.preload["ui/network/manager"] = function() return {} end
    package.preload["settings_viewer"] = function() return { show = function() end } end

    local CardManager = require("card_manager")
    CardManager.show_manage({})
    local manage = state.shown[#state.shown]
    manage.item_table[3].callback()
    local stats = state.shown[#state.shown]
    assert(stats.title:find("Stats", 1, true) and stats.item_table[1].hold_callback,
           "Stats by Book book entries must support long-press actions")
    stats.item_table[1].hold_callback()
    local actions = state.shown[#state.shown]
    assert(actions.buttons[1][1].text == "Delete all cards for this book",
           "long press must expose the required bulk-delete action")
    actions.buttons[1][1].callback()
    local confirm = state.shown[#state.shown]
    assert(confirm.text:find("Unknown book", 1, true) and confirm.text:find("1 local card", 1, true),
           "confirmation must identify the exact book and local card count")
    confirm.cancel_callback()
    assert(state.delete_calls == 0, "opening confirmation/cancelling must not mutate storage")

    -- Begin the same flow again and confirm it this time.
    stats.item_table[1].hold_callback()
    state.shown[#state.shown].buttons[1][1].callback()
    confirm = state.shown[#state.shown]
    confirm.ok_callback()
    assert(state.delete_calls == 1 and state.send_calls == 0,
           "confirmation must delete locally only and never invoke AnkiConnect")
    assert(state.shown[#state.shown].title:find("Stats", 1, true),
           "successful deletion must refresh Stats by Book")
    assert(state.shown[#state.shown - 1].text == "Deleted 1 local card for 'Unknown book'",
           "successful deletion must provide local-only feedback")
end

print("issue #13 bulk-delete-book harness: PASS")
