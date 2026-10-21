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
    image_path = "/tmp/issue72-replace-old.png",
}
local old_replace_asset = assert(io.open(original.image_path, "w")); old_replace_asset:write("old"); old_replace_asset:close()
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
assert(not io.open("/tmp/issue72-replace-old.png", "r"),
       "full replacement must remove the old image only after persistence succeeds")
assert(not CardStorage.update_image_path(original, "/tmp/stale.png"), "stale async image must not update replacement")
assert(CardStorage.update_image_path(regenerated, "/tmp/current.png"), "current async image must update replacement")
assert(CardStorage.load_cards()[1].image_path == "/tmp/current.png", "current async image was not persisted")
os.remove("/tmp/anki_flashcards.json")

-- The normalized phrase uniqueness invariant applies to edits and full
-- regenerations as well as initial saves. Rejections preserve both records and
-- their sent state, so later sends still target the intended card.
local alpha = { phrase = "alpha", definition = "first" }
local beta = { phrase = "beta", definition = "second" }
assert(CardStorage.save_card(alpha) and CardStorage.save_card(beta), "setup cards must save")
assert(CardStorage.mark_sent("alpha"), "alpha sent state must persist")
local edit = copy_card(alpha)
edit.phrase = "  BETA  "
local updated, update_err = CardStorage.update_card(alpha, edit)
assert(not updated and update_err == "already_saved", "edit collision must be rejected")
local replacement = { phrase = "beta", definition = "replacement" }
local replaced, replace_err = CardStorage.replace_card(alpha, replacement)
assert(not replaced and replace_err == "already_saved", "regeneration collision must be rejected")
cards = CardStorage.load_cards()
assert(#cards == 2 and cards[1].phrase == "alpha" and cards[1].sent_to_anki
       and cards[2].phrase == "beta" and not cards[2].sent_to_anki,
       "rejected phrase collisions must not mutate records or sent-state targeting")
os.remove("/tmp/anki_flashcards.json")

-- Same-phrase requests started in one mocked second get distinct media paths.
-- Complete the second request first, persist it, then clean the stale first
-- result: the current asset must remain intact.
do
    local saved_time = os.time
    local scheduled, completed = {}, {}
    local saved_json = package.loaded.json
    package.loaded["image_generator"] = nil
    package.loaded["ssl.https"] = nil
    package.loaded["socket.http"] = nil
    package.loaded["ltn12"] = nil
    package.loaded["mime"] = nil
    package.loaded.json = nil
    os.time = function() return 1700000000 end
    package.preload["ssl.https"] = function()
        return {
            request = function(request)
                if request.url:find("/services/", 1, true) then
                    request.sink("create")
                elseif request.url:find("/tasks/", 1, true) then
                    request.sink("complete")
                else
                    request.sink("image bytes")
                end
                return 1, 200
            end,
        }
    end
    package.preload["socket.http"] = package.preload["ssl.https"]
    package.preload["ltn12"] = function()
        return {
            sink = { table = function(parts)
                return function(chunk) if chunk then table.insert(parts, chunk) end return 1 end
            end },
            source = { string = function(body) return body end },
        }
    end
    package.preload["mime"] = function() return { unb64 = function(value) return value end } end
    package.preload["json"] = function()
        return { decode = function(value)
            if value == "create" then return { output = { task_id = "task" } } end
            return { output = { task_status = "SUCCEEDED", results = {{ url = "https://image.test/result" }} } }
        end, encode = function() return "{}" end }
    end
    package.preload["ui/uimanager"] = function()
        return { scheduleIn = function(_, _, callback) table.insert(scheduled, callback) end }
    end
    local ImageGenerator = require("image_generator")
    ImageGenerator.generate_async({ image_provider = "dashscope", dashscope_api_key = "key" }, "prompt", "same phrase",
        function(path) completed.first = path end, function(err) error(err) end)
    ImageGenerator.generate_async({ image_provider = "dashscope", dashscope_api_key = "key" }, "prompt", "same phrase",
        function(path) completed.second = path end, function(err) error(err) end)
    -- create first, create second, then complete second before first.
    table.remove(scheduled, 1)()
    table.remove(scheduled, 1)()
    table.remove(scheduled, 2)()
    table.remove(scheduled, 1)()
    assert(completed.first ~= completed.second, "same-second image requests must have unique paths")
    assert(completed.first:match("same_phrase_1700000000_%d+%.png$"), "image filename must remain safe and readable")
    local current = { phrase = "same phrase" }
    assert(CardStorage.save_card(current), "current image test card must save")
    assert(CardStorage.update_image_path(current, completed.second), "reverse-order current image must persist")
    CardStorage.remove_image_if_unreferenced(completed.first)
    assert(not io.open(completed.first, "rb"), "stale image output must be removed")
    assert(io.open(completed.second, "rb"), "stale cleanup must not delete the current image")
    assert(not CardStorage.remove_image_if_unreferenced(completed.second),
           "persisted current path must be protected from cleanup")
    os.remove(completed.second)
    os.remove("/tmp/anki_flashcards.json")
    os.time = saved_time
    package.loaded.json = saved_json
    package.loaded["image_generator"] = nil
end

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

-- Atomic persistence must leave an already-valid database readable after every
-- failure point, and legacy phrase records must acquire an id before an async
-- callback can outlive a delete/recreate cycle.
do
    local saved_open, saved_rename = io.open, os.rename
    local files, encoded_data, serial = {}, {}, 0
    local fail_encode, fail_write, fail_close, fail_rename = false, false, false, false
    local function clone_entries(entries)
        local copy = {}
        for i, entry in ipairs(entries or {}) do copy[i] = copy_card(entry) end
        return copy
    end
    package.loaded["card_storage"] = nil
    package.loaded["datastorage"] = nil
    package.preload["datastorage"] = function()
        return { getDataDir = function() return "/atomic-test" end }
    end
    package.loaded["json"] = nil
    package.preload["json"] = function()
        return {
            encode = function(entries)
                if fail_encode then error("encode failure") end
                serial = serial + 1
                local token = "encoded-" .. tostring(serial)
                encoded_data[token] = clone_entries(entries)
                return token
            end,
            decode = function(token)
                return clone_entries(encoded_data[token] or {})
            end,
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
            write = function(_, data)
                if fail_write then return false end
                buffer = buffer .. data
                return true
            end,
            close = function()
                if fail_close then return false end
                files[path] = buffer
                return true
            end,
        }
    end
    os.rename = function(from, to)
        if fail_rename then return false end
        files[to], files[from] = files[from], nil
        return true
    end
    local AtomicStorage = require("card_storage")
    local live = "/atomic-test/anki_flashcards.json"
    local function reset_valid()
        files, encoded_data, serial = {}, {}, 0
        encoded_data.valid = { { phrase = "legacy", definition = "original" } }
        files[live] = "valid"
        fail_encode, fail_write, fail_close, fail_rename = false, false, false, false
    end
    local function assert_original_survives(label)
        local cards = AtomicStorage.load_cards()
        assert(#cards == 1 and cards[1].phrase == "legacy" and not cards[1]._storage_id,
               label .. " must leave the original database readable and unchanged")
    end
    for label, set_failure in pairs({
        encode = function() fail_encode = true end,
        write = function() fail_write = true end,
        close = function() fail_close = true end,
        rename = function() fail_rename = true end,
    }) do
        reset_valid()
        set_failure()
        assert(not AtomicStorage.update_image_path({ phrase = "legacy" }, "/tmp/new.png"),
               label .. " failure must be reported")
        assert_original_survives(label)
    end
    reset_valid()
    local legacy = { phrase = "legacy" }
    assert(AtomicStorage.ensure_identity(legacy), "legacy card must migrate before async work is scheduled")
    assert(legacy._storage_id, "legacy in-memory card must receive its eagerly persisted identity")
    assert(AtomicStorage.update_image_path(legacy, "/tmp/first.png"), "legacy callback must use migrated identity")
    AtomicStorage.delete_card(1)
    local replacement = { phrase = "legacy", definition = "replacement" }
    assert(AtomicStorage.save_card(replacement), "replacement must save")
    assert(not AtomicStorage.update_image_path(legacy, "/tmp/stale-legacy.png"),
           "legacy callback must not mutate delete/recreate same-phrase card")
    assert(AtomicStorage.load_cards()[1]._storage_id == replacement._storage_id,
           "stale legacy callback changed replacement identity")
    io.open, os.rename = saved_open, saved_rename
    package.loaded["card_storage"] = nil
end

-- Load main.lua with KOReader dependencies mocked, then drive its highlight flow.
local events, entries, viewers, generated_cards, storage_cards, image_callbacks, audio_callbacks, viewer_updates, shown_messages
local function reset_main(card_results, options)
    options = options or {}
    events, entries, viewers, generated_cards, storage_cards = {}, {}, {}, card_results, {}
    image_callbacks, audio_callbacks, viewer_updates, shown_messages = {}, {}, {}, {}
    if options.saved_highlight_card then
        local saved = copy_card(options.saved_highlight_card)
        if not options.legacy_saved_card then
            saved._storage_id = saved._storage_id or "saved-highlight-1"
        end
        storage_cards[1] = saved
    end
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
            show = function(_, widget)
                if widget.is_viewer then viewers[#viewers + 1] = widget
                elseif widget.text then shown_messages[#shown_messages + 1] = widget.text end
            end,
            close = function() end,
            setDirty = function() end,
            scheduleIn = function(_, delay, callback) if delay < 1 then callback() end end,
            topdown_widgets_iter = function()
                local yielded = false
                return function()
                    if yielded then return nil end
                    yielded = true
                    return viewers[#viewers]
                end
            end,
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
            generate_text = function()
                local result = options.text_results and table.remove(options.text_results, 1)
                if result == false or not result then return nil, "sentence provider failed" end
                return result.text, result.prompt
            end,
            generate_ipa = function(_, phrase)
                local result = options.ipa_results and table.remove(options.ipa_results, 1)
                if result == false then return nil, "IPA provider failed" end
                return result or ("/" .. phrase .. "/")
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
                if options.replace_fails then return false, options.replace_error or "write_failed" end
                next_id = next_id + 1
                card._storage_id = tostring(next_id)
                card.sent_to_anki = old.sent_to_anki
                storage_cards[1] = copy_card(card)
                events[#events + 1] = "replace"
                return true
            end,
            update_card = function(old, candidate)
                if options.update_card_fails then
                    return false, options.update_error or "write_failed"
                end
                if not storage_cards[1] or storage_cards[1]._storage_id ~= old._storage_id then
                    return false, "not_saved"
                end
                candidate._storage_id = old._storage_id
                storage_cards[1] = copy_card(candidate)
                events[#events + 1] = "update"
                return true
            end,
            ensure_identity = function(card)
                if card._storage_id then return true end
                if storage_cards[1] and storage_cards[1].phrase == card.phrase then
                    next_id = next_id + 1
                    card._storage_id = "legacy-" .. tostring(next_id)
                    storage_cards[1]._storage_id = card._storage_id
                    return true
                end
                return false
            end,
            update_image_path = function(card, path)
                if options.update_image_fails then return false end
                if not storage_cards[1] or storage_cards[1]._storage_id ~= card._storage_id then return false end
                storage_cards[1].image_path = path
                return true
            end,
            update_audio_url = function(card, url)
                if not storage_cards[1] or storage_cards[1]._storage_id ~= card._storage_id then return false end
                storage_cards[1]._audio_url = url
                return true
            end,
            remove_image_if_unreferenced = function(path)
                for _, stored_card in ipairs(storage_cards) do
                    if stored_card.image_path == path then return false end
                end
                return os.remove(path)
            end,
            mark_sent = function() return true end,
            find_by_position = function(pos0)
                if storage_cards[1] and storage_cards[1].highlight_pos0 == pos0 then
                    return copy_card(storage_cards[1])
                end
                return nil
            end,
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
    highlight.ui = plugin.ui
    plugin:init()
    assert(entries.ankiflashcards_4, "Anki Card entry was not registered")
    return entries.ankiflashcards_4({
        selected_text = { text = "anchor", pos0 = "p0", pos1 = "p1" }, saveHighlight = function() end,
    }), plugin, highlight
end

local action = reset_main({ { phrase = "anchor", definition = "first" }, { phrase = "anchored", definition = "replacement" } })
action.callback()
assert(events[1] == "save" and events[2] == "viewer", "card must save before its viewer is created: " .. table.concat(events, ","))
assert(#storage_cards == 1 and storage_cards[1].book_title == "Book", "initial generation must persist metadata")
viewers[#viewers].on_regenerate()
assert(#storage_cards == 1 and storage_cards[1].phrase == "anchored", "regeneration must replace, not duplicate")
assert(storage_cards[1].highlight_pos0 == "p0" and storage_cards[1].highlight_pos1 == "p1", "regeneration must retain highlight metadata")

-- Owner callbacks capture a legacy record's identity before the viewer mutates
-- its phrase, so update_card never has to discover the old phrase afterwards.
local legacy_primary_action = reset_main({ { phrase = "legacy primary", definition = "first" } })
legacy_primary_action.callback()
local legacy_primary_viewer = viewers[#viewers]
storage_cards[1]._storage_id, legacy_primary_viewer.card._storage_id = nil, nil
assert(legacy_primary_viewer.on_prepare_update(legacy_primary_viewer.card),
       "primary viewer must migrate legacy identity before editing")
assert(legacy_primary_viewer.card.phrase == "legacy primary" and legacy_primary_viewer.card._storage_id,
       "primary legacy migration must run while the original phrase is intact")
legacy_primary_viewer.card.phrase = "renamed primary"
assert(legacy_primary_viewer.on_update(legacy_primary_viewer.card), "primary legacy rename must persist")
assert(#storage_cards == 1 and storage_cards[1].phrase == "renamed primary",
       "primary legacy rename must not duplicate or lose the saved record")

-- Existing document highlights use a separate viewer path. Its edits must target
-- the saved generation, survive reopening the highlight, and persist its IPA
-- refresh without redrawing a viewer that is no longer visible.
local function open_saved_highlight(saved_card, options)
    options = options or {}
    options.saved_highlight_card = saved_card
    local _action, plugin, highlight = reset_main({}, options)
    plugin.ui.annotation.annotations[1] = {
        pos0 = saved_card.highlight_pos0, pos1 = saved_card.highlight_pos1, text = saved_card.phrase,
    }
    highlight.view = {
        highlight = { visible_boxes = {{ rect = { x = 0, y = 0, w = 100, h = 100 }, index = 1 }} },
        screenToPageTransform = function(_, pos) return pos end,
    }
    assert(highlight:onTap(nil, { pos = { x = 1, y = 1 } }), "saved highlight tap must open its card viewer")
    return viewers[#viewers]
end

local saved_highlight = {
    phrase = "anchor", definition = "original", ipa = "/old/",
    highlight_pos0 = "saved-p0", highlight_pos1 = "saved-p1",
}
local highlight_viewer = open_saved_highlight(saved_highlight, { ipa_results = { "/edited/" } })
highlight_viewer.card.phrase = "edited"
highlight_viewer.card.definition = "persisted edit"
local edited_ok, edited_err = highlight_viewer.on_update(highlight_viewer.card)
assert(edited_ok and not edited_err, "saved-highlight edit must persist")
assert(storage_cards[1].phrase == "edited" and storage_cards[1].definition == "persisted edit",
       "saved-highlight edit was not durable")
highlight_viewer.on_regen_ipa("edited", highlight_viewer.card, highlight_viewer)
assert(storage_cards[1].ipa == "/edited/", "saved-highlight IPA regeneration must persist")
assert(#viewer_updates == 1 and viewer_updates[1].viewer == highlight_viewer,
       "saved-highlight IPA regeneration must redraw only its visible viewer")
-- Reopen by its unchanged highlight identity, not its old phrase.
assert(highlight_viewer.on_highlight_dialog, "saved highlight navigation must remain available")
local reopened_viewer = open_saved_highlight(storage_cards[1])
assert(reopened_viewer.card.definition == "persisted edit" and reopened_viewer.card.ipa == "/edited/",
       "reopened saved highlight must read the persisted edit and IPA")

local legacy_highlight_viewer = open_saved_highlight({
    phrase = "legacy highlight", definition = "original", highlight_pos0 = "legacy-p0", highlight_pos1 = "legacy-p1",
}, { legacy_saved_card = true })
assert(not legacy_highlight_viewer.card._storage_id, "legacy highlight setup must omit storage identity")
assert(legacy_highlight_viewer.on_prepare_update(legacy_highlight_viewer.card),
       "tapped-highlight viewer must migrate identity before editing")
legacy_highlight_viewer.card.phrase = "renamed highlight"
assert(legacy_highlight_viewer.on_update(legacy_highlight_viewer.card), "legacy tapped-highlight rename must persist")
assert(#storage_cards == 1 and storage_cards[1].phrase == "renamed highlight",
       "legacy tapped-highlight rename must not duplicate or lose the record")

for _, failure in ipairs({ "write_failed", "already_saved" }) do
    local failing_viewer = open_saved_highlight(saved_highlight, {
        update_card_fails = true, update_error = failure,
    })
    failing_viewer.card.phrase = "conflicting phrase"
    local saved, save_err = failing_viewer.on_update(failing_viewer.card)
    assert(not saved and save_err == failure,
           "saved-highlight edit must surface its " .. failure .. " persistence failure")
    assert(storage_cards[1].phrase == "anchor" and storage_cards[1].definition == "original",
           "failed saved-highlight edit must not mutate durable storage")
end

-- A stale IPA result may still persist after a viewer closes, but must not
-- recreate/redraw a viewer that is no longer on screen.
local closed_viewer = open_saved_highlight(saved_highlight, { ipa_results = { "/closed/" } })
local offscreen = { update = function() error("offscreen viewer must not redraw") end }
closed_viewer.on_regen_ipa("anchor", closed_viewer.card, offscreen)
assert(storage_cards[1].ipa == "/closed/", "offscreen saved-highlight IPA refresh must still persist")

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

-- A successful ordinary edit retains the generation but invalidates media work
-- created for its old content. Audio also requires its original AnkiVocab word.
local ordinary_edit_action = reset_main({ {
    phrase = "anchor", definition = "first", image_prompt = "old image", _audio_status = "pending", _ankivocab_word = "anchor",
} }, { images_enabled = true })
ordinary_edit_action.callback()
local ordinary_edit_viewer = viewers[#viewers]
assert(#image_callbacks == 1 and #audio_callbacks == 1, "ordinary-edit setup must start image and audio callbacks")
ordinary_edit_viewer.card.phrase = "edited"
ordinary_edit_viewer.card._ankivocab_word = "edited"
assert(ordinary_edit_viewer.on_update(ordinary_edit_viewer.card), "ordinary primary edit must persist")
image_callbacks[1]("/tmp/ordinary-stale.png")
audio_callbacks[1]("https://audio.example/ordinary-stale.mp3")
assert(storage_cards[1].phrase == "edited" and not storage_cards[1].image_path and not storage_cards[1]._audio_url,
       "ordinary primary edit must reject old image and audio callbacks")

local tapped_media_viewer = open_saved_highlight({
    phrase = "tap old", definition = "first", image_prompt = "old image", highlight_pos0 = "tap-p0", highlight_pos1 = "tap-p1",
    _audio_status = "pending", _ankivocab_word = "tap old",
}, { images_enabled = true })
assert(#image_callbacks == 1 and #audio_callbacks == 1,
       "tapped-highlight setup must start image and audio callbacks")
tapped_media_viewer.card.phrase = "tap edited"
tapped_media_viewer.card._ankivocab_word = "tap edited"
assert(tapped_media_viewer.on_update(tapped_media_viewer.card), "ordinary tapped-highlight edit must persist")
image_callbacks[1]("/tmp/tapped-stale.png")
audio_callbacks[1]("https://audio.example/tapped-stale.mp3")
assert(storage_cards[1].phrase == "tap edited" and not storage_cards[1].image_path and not storage_cards[1]._audio_url,
       "ordinary tapped-highlight edit must reject old image and audio callbacks")

-- A newer image request wins; stale output is deleted, and a dismissed viewer
-- rejects output without reopening or persisting it.
local old_image, stale_image, current_image = "/tmp/issue72-old.png", "/tmp/issue72-stale.png", "/tmp/issue72-current.png"
for _, path in ipairs({ old_image, stale_image, current_image }) do
    local f = assert(io.open(path, "w")); f:write("x"); f:close()
end
local media_action = reset_main({ {
    phrase = "anchor", definition = "first", image_prompt = "image", image_path = old_image,
} }, { images_enabled = true })
media_action.callback()
local media_viewer = viewers[#viewers]
media_viewer.on_regen_image()
media_viewer.on_regen_image()
assert(#image_callbacks == 3, "initial plus two image requests must retain separate callbacks; got " .. tostring(#image_callbacks))
image_callbacks[2](stale_image)
assert(not io.open(stale_image, "r") and storage_cards[1].image_path == old_image,
       "stale image result must be deleted without replacing the current image")
image_callbacks[3](current_image)
assert(not io.open(old_image, "r") and storage_cards[1].image_path == current_image,
       "old image must be removed only after the current replacement persisted")
os.remove(current_image)

local dismissed_image = "/tmp/issue72-dismissed.png"
local dismissed_action = reset_main({ {
    phrase = "dismiss", definition = "first", image_prompt = "image",
} }, { images_enabled = true })
dismissed_action.callback()
local dismissed_viewer = viewers[#viewers]
local f = assert(io.open(dismissed_image, "w")); f:write("x"); f:close()
dismissed_viewer.on_close()
image_callbacks[1](dismissed_image)
assert(not io.open(dismissed_image, "r") and not storage_cards[1].image_path,
       "dismissed viewer must reject and clean its late image callback")

local retained_old, rejected_new = "/tmp/issue72-retained-old.png", "/tmp/issue72-rejected-new.png"
for _, path in ipairs({ retained_old, rejected_new }) do
    local file = assert(io.open(path, "w")); file:write("x"); file:close()
end
local failed_media_action = reset_main({ {
    phrase = "failure", definition = "first", image_prompt = "image", image_path = retained_old,
} }, { images_enabled = true, update_image_fails = true })
failed_media_action.callback()
viewers[#viewers].on_regen_image()
image_callbacks[2](rejected_new)
assert(io.open(retained_old, "r") and not io.open(rejected_new, "r"),
       "failed replacement persistence must retain old image and clean new output")
os.remove(retained_old)

local failed_action = reset_main({ false })
failed_action.callback()
assert(#storage_cards == 0 and #viewers == 0, "failed generation must not save or show a card")

-- A generation or persistence failure after the viewer closes must restore the
-- existing generated-card viewer. Sentence persistence failure must also leave
-- the live card table untouched until the durable update succeeds.
local full_failure = reset_main({ { phrase = "anchor", definition = "first" }, false })
full_failure.callback()
local original_full_viewer = viewers[#viewers]
original_full_viewer.on_regenerate()
assert(#viewers == 2 and viewers[#viewers].card.phrase == "anchor",
       "failed full regeneration must restore the existing viewer")
assert(storage_cards[1].phrase == "anchor", "failed full regeneration must retain stored card")

local replace_failure = reset_main({ { phrase = "anchor", definition = "first" }, { phrase = "replacement" } },
                                   { replace_fails = true })
replace_failure.callback()
local replace_failure_viewer = viewers[#viewers]
replace_failure_viewer.on_regenerate()
assert(#viewers == 2 and viewers[#viewers].card.phrase == "anchor",
       "failed replacement persistence must restore the existing viewer")
assert(storage_cards[1].phrase == "anchor", "failed replacement persistence must retain stored card")

local collision_restore = reset_main({ { phrase = "anchor", definition = "first" }, { phrase = "beta" } },
                                    { replace_fails = true, replace_error = "already_saved" })
collision_restore.callback()
viewers[#viewers].on_regenerate()
assert(#viewers == 2 and viewers[#viewers].card.phrase == "anchor"
       and storage_cards[1].phrase == "anchor",
       "duplicate regeneration rejection must restore the current viewer without mutation")

local sentence_failure = reset_main({ { phrase = "anchor", definition = "first", text = "old", image_prompt = "old prompt" } },
                                   { text_results = { { text = "new", prompt = "new prompt" } }, update_card_fails = true })
sentence_failure.callback()
local original_sentence_viewer = viewers[#viewers]
original_sentence_viewer.on_regen_text()
assert(#viewers == 2 and viewers[#viewers].card.text == "old" and viewers[#viewers].card.image_prompt == "old prompt",
       "failed sentence persistence must restore the existing viewer state")
assert(storage_cards[1].text == "old" and storage_cards[1].image_prompt == "old prompt",
       "failed sentence persistence must not mutate in-memory or stored card state")

-- Exercise the real viewer's back-side action row and edit-failure rollback with lightweight KOReader mocks.
local rendered_buttons, last_input_dialog, last_info_text, viewer_input_value
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
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget)
            if widget.getInputText then last_input_dialog = widget
            elseif widget.text then last_info_text = widget.text end
        end,
        close = function() end,
        scheduleIn = function(_, _, callback) callback() end,
    }
end
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
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_, options)
        options.getInputText = function() return viewer_input_value end
        options.onShowKeyboard = function() end
        return widget(options)
    end }
end
local RealCardViewer = require("card_viewer")
RealCardViewer:new { card = { phrase = "anchor" }, show_back = true }
assert(rendered_buttons, "CardViewer did not build an action row")
for _, button in ipairs(rendered_buttons) do
    assert(not tostring(button.text):find("Save", 1, true), "Save button must not be rendered")
end

local failing_card = { phrase = "anchor", definition = "original", ipa = "/old/" }
local failing_viewer = RealCardViewer:new {
    card = failing_card,
    show_back = true,
    on_update = function() return false, "already_saved" end,
}
viewer_input_value = "duplicate"
failing_viewer:editField({ key = "phrase", label = "Phrase" })
assert(last_input_dialog and last_input_dialog.buttons[1][2], "CardViewer edit dialog was not shown")
last_input_dialog.buttons[1][2].callback()
assert(failing_card.phrase == "anchor" and failing_card.ipa == "/old/",
       "CardViewer must restore in-memory state after a failed persisted edit")
assert(last_info_text == "A card with this phrase is already saved",
       "CardViewer must display the duplicate edit failure")

local prepared_phrase, updated_phrase
local identity_card = { phrase = "legacy anchor", definition = "original" }
local identity_viewer = RealCardViewer:new {
    card = identity_card,
    show_back = true,
    on_prepare_update = function(card)
        prepared_phrase = card.phrase
        card._storage_id = "migrated-before-mutation"
        return true
    end,
    on_update = function(card)
        updated_phrase = card.phrase
        return card._storage_id == "migrated-before-mutation"
    end,
}
viewer_input_value = "renamed legacy"
identity_viewer:editField({ key = "phrase", label = "Phrase" })
last_input_dialog.buttons[1][2].callback()
assert(prepared_phrase == "legacy anchor" and updated_phrase == "renamed legacy",
       "CardViewer must capture legacy identity before mutating phrase")

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
