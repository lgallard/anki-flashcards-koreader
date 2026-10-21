-- Focused LuaJIT regression harness for Issue #72 inbox persistence failures.
package.path = "./AnkiFlashcards.koplugin/?.lua;" .. package.path

local function copy_card(card)
    local copy = {}
    for k, v in pairs(card) do copy[k] = v end
    return copy
end

local function run_case(save_result, save_error, assign_storage_id)
    local menu, notifications, image_calls, image_updates = nil, {}, 0, 0
    package.loaded["highlight_inbox"] = nil
    for _, name in ipairs({
        "ui/network/manager", "ui/widget/menu", "ui/widget/notification",
        "ui/uimanager", "gettext", "card_generator", "card_storage", "image_generator",
    }) do
        package.loaded[name] = nil
    end

    package.preload["ui/network/manager"] = function()
        return { runWhenOnline = function(_, callback) callback() end }
    end
    package.preload["ui/widget/menu"] = function()
        return { new = function(_, options) menu = options; return options end }
    end
    package.preload["ui/widget/notification"] = function()
        return { new = function(_, options) return options end }
    end
    package.preload["ui/uimanager"] = function()
        return {
            show = function(_, widget)
                if widget.text then notifications[#notifications + 1] = widget.text end
            end,
            close = function() end,
            scheduleIn = function(_, _, callback) callback() end,
        }
    end
    package.preload["gettext"] = function() return function(text) return text end end
    package.preload["card_generator"] = function()
        return {
            generate = function()
                return { phrase = "duplicate", definition = "definition", image_prompt = "scene" }
            end,
        }
    end
    package.preload["card_storage"] = function()
        return {
            load_cards = function() return {} end,
            save_card = function(card)
                if save_result and assign_storage_id then card._storage_id = "saved-generation" end
                return save_result, save_error
            end,
            update_image_path = function(card, path)
                assert(card._storage_id == "saved-generation", "async update must target a saved identity")
                assert(path == "/tmp/inbox-image.png", "unexpected image path")
                image_updates = image_updates + 1
                return true
            end,
        }
    end
    package.preload["image_generator"] = function()
        return {
            images_enabled = function() return true end,
            generate_async = function(_, _, _, on_success)
                image_calls = image_calls + 1
                on_success("/tmp/inbox-image.png")
            end,
        }
    end

    local Inbox = require("highlight_inbox")
    Inbox.show({
        document = { getProps = function() return { title = "Book", authors = "Author" } end },
        annotation = { annotations = {{ drawer = true, text = "Duplicate" }} },
    }, { images_enabled = true })
    assert(menu and menu.item_table[1], "inbox menu was not rendered")
    menu.item_table[1].callback()
    return image_calls, image_updates, notifications[#notifications]
end

local images, updates, summary = run_case(false, "already_saved", false)
assert(images == 0 and updates == 0, "duplicate inbox card must not generate or update an image")
assert(summary == "0 card(s) saved, 1 already saved", "duplicate summary was not surfaced: " .. tostring(summary))

images, updates, summary = run_case(false, "write_failed", false)
assert(images == 0 and updates == 0, "failed inbox save must not generate or update an image")
assert(summary == "0 card(s) saved, 1 failed", "write failure summary was not surfaced: " .. tostring(summary))

images, updates, summary = run_case(true, nil, false)
assert(images == 0 and updates == 0, "save without a storage id must not start async image work")
assert(summary == "0 card(s) saved, 1 failed", "missing identity must not count as saved: " .. tostring(summary))

images, updates, summary = run_case(true, nil, true)
assert(images == 1 and updates == 1, "successfully saved inbox card must retain image generation behavior")
assert(summary == "1 card(s) saved", "successful inbox summary changed: " .. tostring(summary))

print("issue #72 inbox save failures: PASS")
