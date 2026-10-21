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
        state = {
            shown = {}, closed = 0, delete_calls = 0,
            cards = {
                { phrase = "other", book_title = "Other Book", _storage_id = "other-id" },
                { phrase = "anchor", book_title = "Target Book", _storage_id = "anchor-id" },
            },
        }
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
                ensure_identity = function(card) return card._storage_id ~= nil end,
                delete_card_by_id = function(storage_id)
                    assert(storage_id == "anchor-id", "delete must use card storage identity")
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
        manager.show({}, "Target Book")
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
            if widget.title == "My Cards (1 card (filtered))" then count = count + 1 end
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
    assert(state.shown[#state.shown].title == "My Cards (1 card (filtered))",
           "successful delete must end on the refreshed filtered card list")
end

-- A saved-card viewer must reopen after sentence persistence fails, and the
-- unsaved candidate must not leak into the in-memory card it displays.
do
    local shown, viewer_options = {}, nil
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
            show = function(_, widget) shown[#shown + 1] = widget end,
            close = function() end, setDirty = function() end,
            scheduleIn = function(_, _, callback) callback() end,
            topdown_widgets_iter = function() return function() return nil end end,
        }
    end
    package.preload["ui/event"] = function() return {} end
    local card = { phrase = "anchor", text = "old text", image_prompt = "old prompt", _storage_id = "saved-id" }
    package.preload["card_storage"] = function()
        return {
            load_anki_settings = function() return nil end,
            load_cards = function() return { card } end,
            ensure_identity = function(target) return target._storage_id == "saved-id" end,
            update_card = function() return false end,
            mark_sent = function() return true end,
        }
    end
    package.preload["anki_sync"] = function() return { send_card = function() return true end } end
    package.preload["card_generator"] = function()
        return { generate_text = function() return "new text", "new prompt" end }
    end
    package.preload["card_viewer"] = function()
        return { new = function(_, options) viewer_options = options; return options end }
    end
    package.preload["image_generator"] = function() return { images_enabled = function() return false end } end
    package.preload["ui/network/manager"] = function()
        return { runWhenOnline = function(_, callback) callback() end, isOnline = function() return true end }
    end
    package.preload["settings_viewer"] = function() return { show = function() end } end
    local manager = require("card_manager")
    manager.show({})
    shown[#shown].item_table[2].callback()
    local initial_viewer = viewer_options
    initial_viewer.on_regen_text()
    assert(viewer_options ~= initial_viewer and viewer_options.card.text == "old text"
           and viewer_options.card.image_prompt == "old prompt",
           "saved-card sentence save failure must restore the original viewer state")
    assert(card.text == "old text" and card.image_prompt == "old prompt",
           "saved-card sentence save failure must not mutate the live card")
end

-- Two rapid phrase edits in the My Cards viewer start two IPA requests.  The
-- first response must not overwrite or persist against the second phrase.
do
    local shown, viewer_options, scheduled, ipa_update_calls = {}, nil, {}, 0
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
            show = function(_, widget) shown[#shown + 1] = widget end,
            close = function() end, setDirty = function() end,
            scheduleIn = function(_, _, callback) scheduled[#scheduled + 1] = callback end,
            topdown_widgets_iter = function() return function() return nil end end,
        }
    end
    package.preload["ui/event"] = function() return {} end
    local card = { phrase = "anchor", ipa = "/old/" }
    package.preload["card_storage"] = function()
        return {
            load_anki_settings = function() return nil end,
            load_cards = function() return { card } end,
            ensure_identity = function(target)
                if target._storage_id then return true end
                if target.phrase == "anchor" then target._storage_id = "legacy-id"; return true end
                return false
            end,
            update_card = function(_, candidate)
                if candidate.ipa == "/first/" or candidate.ipa == "/second/" then
                    ipa_update_calls = ipa_update_calls + 1
                end
                return true
            end,
            mark_sent = function() return true end,
        }
    end
    package.preload["anki_sync"] = function() return { send_card = function() return true end } end
    package.preload["card_generator"] = function()
        return { generate_ipa = function(_, phrase) return phrase == "first edit" and "/first/" or "/second/" end }
    end
    package.preload["card_viewer"] = function()
        return { new = function(_, options) viewer_options = options; return options end }
    end
    package.preload["image_generator"] = function() return { images_enabled = function() return false end } end
    package.preload["ui/network/manager"] = function()
        return { runWhenOnline = function(_, callback) callback() end, isOnline = function() return true end }
    end
    package.preload["settings_viewer"] = function() return { show = function() end } end

    local manager = require("card_manager")
    manager.show({})
    shown[#shown].item_table[2].callback()
    assert(viewer_options, "My Cards must open a card viewer")
    assert(viewer_options.on_prepare_update(viewer_options.card),
           "My Cards must migrate a legacy identity before phrase mutation")
    assert(viewer_options.card._storage_id == "legacy-id" and viewer_options.card.phrase == "anchor",
           "My Cards legacy migration must retain the original phrase before rename")

    viewer_options.card.phrase, viewer_options.card.ipa = "first edit", ""
    assert(viewer_options.on_update(viewer_options.card), "first phrase edit must persist")
    viewer_options.on_regen_ipa("first edit", viewer_options.card, viewer_options)
    viewer_options.card.phrase, viewer_options.card.ipa = "second edit", ""
    assert(viewer_options.on_update(viewer_options.card), "second phrase edit must persist")
    viewer_options.on_regen_ipa("second edit", viewer_options.card, viewer_options)
    assert(#scheduled == 2, "two rapid phrase edits must retain both IPA callbacks")

    scheduled[1]()
    assert(card.phrase == "second edit" and card.ipa == "" and ipa_update_calls == 0,
           "stale first IPA response must not overwrite or persist against the second phrase")
    scheduled[2]()
    assert(card.phrase == "second edit" and card.ipa == "/second/" and ipa_update_calls == 1,
           "current second IPA response must persist exactly once")
end

-- A My Cards ordinary edit must invalidate an already-pending image callback
-- even though the card keeps the same persisted generation.
do
    local shown, viewer_options, image_callbacks, audio_callbacks, image_updates, audio_updates = {}, nil, {}, {}, 0, 0
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
        return { show = function(_, widget) shown[#shown + 1] = widget end, close = function() end,
                 setDirty = function() end, scheduleIn = function(_, _, callback) callback() end,
                 topdown_widgets_iter = function() return function() return nil end end }
    end
    package.preload["ui/event"] = function() return {} end
    local card = {
        phrase = "my old", definition = "first", image_prompt = "old image", _storage_id = "my-id",
        _audio_status = "pending", _ankivocab_word = "my old",
    }
    package.preload["card_storage"] = function()
        return {
            load_anki_settings = function() return nil end, load_cards = function() return { card } end,
            ensure_identity = function(target) return target._storage_id == "my-id" end,
            update_card = function() return true end, mark_sent = function() return true end,
            update_image_path = function() image_updates = image_updates + 1; return true end,
            update_audio_url = function() audio_updates = audio_updates + 1; return true end,
            remove_image_if_unreferenced = function() end,
        }
    end
    package.preload["anki_sync"] = function() return { send_card = function() return true end } end
    package.preload["card_generator"] = function() return {} end
    package.preload["card_viewer"] = function()
        return { new = function(_, options)
            options.update = function(self) return self end
            viewer_options = options
            return options
        end }
    end
    package.preload["image_generator"] = function()
        return { images_enabled = function() return true end,
                 generate_async = function(_, _, _, on_success) image_callbacks[#image_callbacks + 1] = on_success end }
    end
    package.preload["ui/network/manager"] = function() return { isOnline = function() return true end } end
    package.preload["audio_generator"] = function()
        return { poll_ankivocab_async = function(_, _, on_success)
            audio_callbacks[#audio_callbacks + 1] = on_success
        end }
    end
    package.preload["settings_viewer"] = function() return { show = function() end } end
    local manager = require("card_manager")
    manager.show({})
    shown[#shown].item_table[2].callback()
    assert(#image_callbacks == 1 and #audio_callbacks == 1,
           "My Cards must start pending image and audio callbacks")
    viewer_options.card.phrase = "my edited"
    viewer_options.card._ankivocab_word = "my edited"
    assert(viewer_options.on_update(viewer_options.card), "My Cards ordinary edit must persist")
    image_callbacks[1]("/tmp/my-cards-stale.png")
    audio_callbacks[1]("https://audio.example/my-cards-stale.mp3")
    assert(image_updates == 0 and audio_updates == 0 and not card.image_path and not card._audio_url,
           "My Cards ordinary edit must reject old image/audio persistence and redraw")
end

print("issue #72 delete-card harness: PASS")
