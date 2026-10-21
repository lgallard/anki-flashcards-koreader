-- Focused LuaJIT regression harness for issue #72 automatic card saving.
package.path = "./AnkiFlashcards.koplugin/?.lua;" .. package.path

local function copy_card(card)
    local copy = {}
    for k, v in pairs(card) do copy[k] = v end
    return copy
end

-- Exercise real storage replacement and generation identities in memory.
local stored = {}
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/tmp" end }
end
package.preload["json"] = function()
    return {
        encode = function(entries) stored = entries; return "[]" end,
        decode = function() return stored end,
    }
end
package.loaded["card_storage"] = nil
local CardStorage = require("card_storage")
os.remove("/tmp/anki_flashcards.json")

local original = {
    phrase = "anchor", definition = "first", book_title = "Book",
    book_author = "Author", highlight_pos0 = "xpointer(/1)", highlight_pos1 = "xpointer(/2)",
}
assert(CardStorage.save_card(original), "initial generated card must save")
local old_id = original._storage_id
CardStorage.mark_sent(original.phrase)
local regenerated = { phrase = "anchored", definition = "replacement" }
assert(CardStorage.replace_card(original, regenerated), "regeneration must replace the saved card")
local cards = CardStorage.load_cards()
assert(#cards == 1, "regeneration must keep exactly one saved record")
assert(cards[1].phrase == "anchored" and cards[1].definition == "replacement", "replacement content missing")
assert(cards[1].book_title == "Book" and cards[1].book_author == "Author", "book metadata must survive regeneration")
assert(cards[1].highlight_pos0 == "xpointer(/1)" and cards[1].highlight_pos1 == "xpointer(/2)", "highlight identity must survive regeneration")
assert(cards[1].sent_to_anki, "sent-to-Anki state must survive regeneration")
assert(regenerated._storage_id ~= old_id, "replacement must invalidate old async generation callbacks")
assert(not CardStorage.update_image_path(original, "/tmp/stale.png"), "stale async image must not update replacement")
assert(CardStorage.update_image_path(regenerated, "/tmp/current.png"), "current async image must update replacement")
assert(CardStorage.load_cards()[1].image_path == "/tmp/current.png", "current async image was not persisted")
os.remove("/tmp/anki_flashcards.json")

-- save_raw must surface every failure after opening the file so callers can
-- report a failed persistence operation instead of pretending it succeeded.
local original_io_open = io.open
local original_encode = package.loaded.json.encode
local function fake_file(write_result, close_result)
    return {
        read = function() return "[]" end,
        write = function() return write_result end,
        close = function() return close_result end,
    }
end

stored = { copy_card(regenerated) }
io.open = function(_, mode)
    if mode == "r" then return fake_file(true, true) end
    return fake_file(false, true)
end
local saved, save_err = CardStorage.save_card { phrase = "write failure" }
assert(not saved and save_err == "write_failed", "save_card must report write failure")
stored = { copy_card(regenerated) }
io.open = function(_, mode)
    if mode == "r" then return fake_file(true, true) end
    return fake_file(true, false)
end
local replaced, replace_err = CardStorage.replace_card(regenerated, { phrase = "close failure" })
assert(not replaced and replace_err == "write_failed", "replace_card must report close failure")
stored = { copy_card(regenerated) }
package.loaded.json.encode = function() error("encode failure") end
io.open = function(_, mode)
    if mode == "r" then return fake_file(true, true) end
    return fake_file(true, true)
end
assert(not CardStorage.update_image_path(regenerated, "/tmp/encode-failure.png"),
       "async image update must report encoding failure")
package.loaded.json.encode = original_encode
io.open = original_io_open

-- Load main.lua with KOReader dependencies mocked, then drive its highlight flow.
local events, entries, viewers, generated_cards, storage_cards, image_callbacks, audio_callbacks, viewer_updates
local function reset_main(card_results, options)
    options = options or {}
    events, entries, viewers, generated_cards, storage_cards = {}, {}, {}, card_results, {}
    image_callbacks, audio_callbacks, viewer_updates = {}, {}, {}
    package.loaded["main"] = nil
    for _, name in ipairs({
        "configuration", "device", "gettext", "ui/widget/infomessage", "ui/widget/notification",
        "ui/widget/container/inputcontainer", "ui/uimanager", "ui/network/manager", "selection_context",
        "card_generator", "card_viewer", "card_storage", "anki_sync", "card_manager", "card_sync",
        "highlight_inbox", "image_generator", "audio_generator",
    }) do
        package.loaded[name] = nil
    end
    package.preload["configuration"] = function() return { target_language = "English" } end
    package.preload["device"] = function() return { hasClipboard = function() return true end } end
    package.preload["gettext"] = function() return function(s) return s end end
    package.preload["ui/widget/infomessage"] = function() return { new = function(_, options) return options end } end
    package.preload["ui/widget/notification"] = function() return { new = function(_, options) return options end } end
    package.preload["ui/widget/container/inputcontainer"] = function()
        return { new = function(_, options) return options end }
    end
    package.preload["ui/uimanager"] = function()
        return {
            show = function(_, widget) if widget.is_viewer then viewers[#viewers + 1] = widget end end,
            close = function() end,
            scheduleIn = function(_, delay, callback) if delay < 1 then callback() end end,
        }
    end
    package.preload["ui/network/manager"] = function()
        return { runWhenOnline = function(_, callback) callback() end, isOnline = function() return true end }
    end
    package.preload["selection_context"] = function() return function() return "context" end end
    package.preload["card_generator"] = function()
        return {
            generate = function()
                local result = table.remove(generated_cards, 1)
                if result == false then return nil, "provider failed" end
                return copy_card(result)
            end,
        }
    end
    package.preload["card_viewer"] = function()
        return { new = function(_, options)
            options.is_viewer = true
            options.update = function(self, updated_card)
                viewer_updates[#viewer_updates + 1] = { viewer = self, card = updated_card }
                return self
            end
            events[#events + 1] = "viewer"
            return options
        end }
    end
    package.preload["card_storage"] = function()
        local next_id = 0
        return {
            load_anki_settings = function() return nil end,
            save_card = function(card)
                next_id = next_id + 1
                card._storage_id = tostring(next_id)
                storage_cards[#storage_cards + 1] = copy_card(card)
                events[#events + 1] = "save"
                return true
            end,
            replace_card = function(old, card)
                assert(old._storage_id, "regeneration must target saved generation")
                next_id = next_id + 1
                card._storage_id = tostring(next_id)
                card.sent_to_anki = old.sent_to_anki
                storage_cards[1] = copy_card(card)
                events[#events + 1] = "replace"
                return true
            end,
            update_card = function() return true end,
            update_image_path = function(card, path)
                if not storage_cards[1] or storage_cards[1]._storage_id ~= card._storage_id then return false end
                storage_cards[1].image_path = path
                return true
            end,
            update_audio_url = function(card, url)
                if not storage_cards[1] or storage_cards[1]._storage_id ~= card._storage_id then return false end
                storage_cards[1]._audio_url = url
                return true
            end,
            mark_sent = function() return true end,
            find_by_position = function() return nil end,
            find_by_phrase_fuzzy = function() return nil end,
            load_cards = function() return storage_cards end,
        }
    end
    package.preload["anki_sync"] = function() return { send_card = function() return true end } end
    package.preload["card_manager"] = function() return { show = function() end, show_manage = function() end } end
    package.preload["card_sync"] = function() return { run_sync = function() end } end
    package.preload["highlight_inbox"] = function() return { show = function() end } end
    package.preload["image_generator"] = function()
        return {
            images_enabled = function() return options.images_enabled or false end,
            generate_async = function(_, _, _, on_success) image_callbacks[#image_callbacks + 1] = on_success end,
        }
    end
    package.preload["audio_generator"] = function()
        return {
            poll_ankivocab_async = function(_, _, on_success) audio_callbacks[#audio_callbacks + 1] = on_success end,
        }
    end
    local plugin = require("main")
    local highlight = {
        onTap = function() end,
        onClose = function() end,
        addToHighlightDialog = function(_, id, builder) entries[id] = builder end,
    }
    plugin.ui = {
        highlight = highlight,
        annotation = { annotations = {} },
        document = { getProps = function() return { title = "Book", authors = "Author" } end },
    }
    plugin:init()
    assert(entries.ankiflashcards_4, "Anki Card entry was not registered")
    return entries.ankiflashcards_4({
        selected_text = { text = "anchor", pos0 = "p0", pos1 = "p1" }, saveHighlight = function() end,
    })
end

local action = reset_main({ { phrase = "anchor", definition = "first" }, { phrase = "anchored", definition = "replacement" } })
action.callback()
assert(events[1] == "save" and events[2] == "viewer", "card must save before its viewer is created: " .. table.concat(events, ","))
assert(#storage_cards == 1 and storage_cards[1].book_title == "Book", "initial generation must persist metadata")
viewers[#viewers].on_regenerate()
assert(#storage_cards == 1 and storage_cards[1].phrase == "anchored", "regeneration must replace, not duplicate")
assert(storage_cards[1].highlight_pos0 == "p0" and storage_cards[1].highlight_pos1 == "p1", "regeneration must retain highlight metadata")

-- Late callbacks from the pre-regeneration generation must not mutate storage
-- or redraw the replacement viewer. The replacement starts its own image and
-- pending-audio work, and only its callbacks may update it.
local pending_action = reset_main({
    { phrase = "anchor", definition = "first", image_prompt = "first image", _audio_status = "pending", _ankivocab_word = "anchor" },
    { phrase = "anchored", definition = "replacement", image_prompt = "replacement image", _audio_status = "pending", _ankivocab_word = "anchored" },
}, { images_enabled = true })
pending_action.callback()
assert(#image_callbacks == 1 and #audio_callbacks == 1, "initial pending card must start image and audio work")
viewers[#viewers].on_regenerate()
assert(#image_callbacks == 2, "regenerated card must start replacement image work")
assert(#audio_callbacks == 2, "regenerated pending card must start audio polling")
local replacement_viewer = viewers[#viewers]
image_callbacks[1]("/tmp/stale.png")
audio_callbacks[1]("https://audio.example/stale.mp3")
assert(#viewer_updates == 0 and viewers[#viewers] == replacement_viewer,
       "stale callbacks must not redraw or replace the regenerated viewer")
assert(storage_cards[1].phrase == "anchored" and not storage_cards[1].image_path and not storage_cards[1]._audio_url,
       "stale callbacks must not persist into the regenerated card")
image_callbacks[2]("/tmp/current.png")
audio_callbacks[2]("https://audio.example/current.mp3")
assert(#viewer_updates == 1 and viewer_updates[1].viewer == replacement_viewer,
       "current image callback must update the current viewer")
assert(storage_cards[1].image_path == "/tmp/current.png"
       and storage_cards[1]._audio_url == "https://audio.example/current.mp3",
       "current callbacks must persist replacement media")

local failed_action = reset_main({ false })
failed_action.callback()
assert(#storage_cards == 0 and #viewers == 0, "failed generation must not save or show a card")

-- Exercise the real viewer's back-side action row with lightweight KOReader mocks.
local rendered_buttons
package.loaded["card_viewer"] = nil
package.preload["card_viewer"] = nil
for _, name in ipairs({
    "device", "gettext", "ui/uimanager", "ui/bidi", "ffi/blitbuffer", "ui/widget/buttondialog",
    "ui/widget/buttontable", "ui/widget/container/centercontainer", "ui/font",
    "ui/widget/container/framecontainer", "ui/geometry", "ui/gesturerange",
    "ui/widget/container/inputcontainer", "ui/widget/inputdialog", "ui/widget/container/movablecontainer",
    "ui/widget/notification", "ui/widget/scrolltextwidget", "ui/size", "ui/widget/titlebar",
    "ui/widget/verticalgroup", "ui/widget/horizontalgroup", "ui/widget/container/widgetcontainer", "ui/widget/verticalspan",
    "ui/widget/imagewidget", "ui/widget/container/overlapgroup", "ui/rendertext", "ui/widget/infomessage",
}) do package.loaded[name] = nil end
local function widget(options)
    options = options or {}
    options.getSize = options.getSize or function() return { h = 1, w = 1 } end
    options.getHeight = options.getHeight or function() return 1 end
    return options
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end, scaleBySize = function(_, n) return n end },
             hasKeys = function() return false end, isTouchDevice = function() return false end }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ui/uimanager"] = function() return { show = function() end, close = function() end, scheduleIn = function(_, _, callback) callback() end } end
package.preload["ui/bidi"] = function() return {} end
package.preload["ui/rendertext"] = function() return {} end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 1, COLOR_BLACK = 0, ColorRGB32 = function() return 0 end } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/size"] = function() return { padding = { large = 1, default = 1 }, margin = { small = 1 }, radius = { window = 1 } } end
package.preload["ui/geometry"] = function() return { new = function(_, options) return options end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, options) return options end } end
package.preload["ui/widget/container/inputcontainer"] = function()
    local Base = {}
    function Base:extend(def)
        def.__index = def
        function def:new(options)
            local instance = setmetatable(options or {}, def)
            instance:init()
            return instance
        end
        return def
    end
    return Base
end
package.preload["ui/widget/buttontable"] = function()
    return { new = function(_, options) rendered_buttons = options.buttons[1]; return widget(options) end }
end
for _, name in ipairs({
    "ui/widget/buttondialog", "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
    "ui/widget/inputdialog", "ui/widget/container/movablecontainer", "ui/widget/notification",
    "ui/widget/scrolltextwidget", "ui/widget/titlebar", "ui/widget/verticalgroup", "ui/widget/horizontalgroup",
    "ui/widget/container/widgetcontainer", "ui/widget/verticalspan", "ui/widget/imagewidget",
    "ui/widget/container/overlapgroup", "ui/widget/infomessage",
}) do
    package.preload[name] = function() return { new = function(_, options) return widget(options) end } end
end
local RealCardViewer = require("card_viewer")
RealCardViewer:new { card = { phrase = "anchor" }, show_back = true }
assert(rendered_buttons, "CardViewer did not build an action row")
for _, button in ipairs(rendered_buttons) do
    assert(not tostring(button.text):find("Save", 1, true), "Save button must not be rendered")
end

local function read(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*all")
    file:close()
    return content
end
local viewer_source = read("./AnkiFlashcards.koplugin/card_viewer.lua")
local main_source = read("./AnkiFlashcards.koplugin/main.lua")
local manager_source = read("./AnkiFlashcards.koplugin/card_manager.lua")
assert(not viewer_source:find('id      = "save"', 1, true), "Save button must not be rendered")
assert(not viewer_source:find("on_save", 1, true) and not main_source:find("on_save", 1, true)
       and not manager_source:find("on_save", 1, true), "manual Save callback path must be removed")

print("issue #72 autosave harness: PASS")
