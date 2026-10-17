-- Focused LuaJIT harness for issue #10 card export behavior.
package.path = "./AnkiFlashcards.koplugin/?.lua;" .. package.path

package.preload["datastorage"] = function()
    return { getDataDir = function() return "/tmp" end }
end
package.preload["json"] = function()
    return { encode = function() return "[]" end, decode = function() return {} end }
end

local CardStorage = require("card_storage")
local original_date = os.date
os.date = function() return "20261017-120000" end

local csv_cards = {
    {
        phrase = 'Say "hi", friend',
        ipa = "/haɪ/\r\nsecond line",
        definition = "A definition\r\nwith a newline",
        synonyms = "hello, greeting",
        text = "A\tcloze sentence",
        source = 'Quote "source"',
        image_path = "/images/image,one.png",
    },
}
local csv_path, csv_count = assert(CardStorage.export_cards(csv_cards, "csv"))
assert(csv_count == 1, "CSV export count should be returned")
assert(csv_path == "/tmp/anki_flashcards_export_20261017-120000.csv", "CSV path should use data storage")
local csv_file = assert(io.open(csv_path, "r"))
local csv = csv_file:read("*all")
csv_file:close()
os.remove(csv_path)
assert(csv:find("Phrase,IPA,Definition,Synonyms,Text,Source,Image\r\n", 1, true), "CSV header missing")
assert(csv:find('"Say ""hi"", friend"', 1, true), "CSV quote/comma escaping failed")
assert(csv:find('"/haɪ/\r\nsecond line"', 1, true), "CSV CR/LF escaping failed")
assert(csv:find('"hello, greeting"', 1, true), "CSV delimiter escaping failed")
assert(csv:find('"image,one.png"', 1, true), "image filename should be exported without its path")

local tsv_cards = {
    {
        phrase = "tab\tphrase",
        ipa = "ipa",
        definition = "definition",
        synonyms = "synonyms",
        text = "text",
        source = "source\rline",
        image_path = "C:\\images\\plain.png",
    },
}
local tsv_path, tsv_count = assert(CardStorage.export_cards(tsv_cards, "tsv"))
assert(tsv_count == 1, "TSV export count should be returned")
assert(tsv_path == "/tmp/anki_flashcards_export_20261017-120000.tsv", "TSV path should use data storage")
local tsv_file = assert(io.open(tsv_path, "r"))
local tsv = tsv_file:read("*all")
tsv_file:close()
os.remove(tsv_path)
assert(tsv:find("Phrase\tIPA\tDefinition\tSynonyms\tText\tSource\tImage\r\n", 1, true), "TSV header missing")
assert(tsv:find('"tab\tphrase"', 1, true), "TSV delimiter escaping failed")
assert(tsv:find('"source\rline"', 1, true), "TSV CR escaping failed")
assert(tsv:find("plain.png", 1, true), "Windows image filename should be exported without its path")

local path, count, err = CardStorage.export_cards({}, "csv")
assert(path == nil and count == 0 and err == "no_cards", "empty exports must not create a file")
path, count, err = CardStorage.export_cards(csv_cards, "json")
assert(path == nil and count == 0 and err == "unsupported_format", "invalid format must fail safely")

local original_open, original_remove, original_rename = io.open, os.remove, os.rename
local function assert_export_failure(fake_file, message)
    local removed, renamed = {}, {}
    io.open = function(file_path, mode)
        if mode == "w" then return fake_file end
        return original_open(file_path, mode)
    end
    os.remove = function(file_path)
        removed[#removed + 1] = file_path
        return true
    end
    os.rename = function(from_path, to_path)
        renamed[#renamed + 1] = { from_path, to_path }
        return true
    end

    local failed_path, failed_count, failed_err = CardStorage.export_cards(csv_cards, "csv")
    assert(failed_path == nil and failed_count == 0 and failed_err == "write_failed", message)
    assert(#removed == 1 and removed[1] == "/tmp/anki_flashcards_export_20261017-120000.csv.tmp",
           message .. ": temporary file must be removed")
    assert(#renamed == 0, message .. ": temporary file must not be renamed")

    io.open, os.remove, os.rename = original_open, original_remove, original_rename
end

local failed_write_close_calls = 0
assert_export_failure({
    write = function() return nil, "disk full" end,
    close = function() failed_write_close_calls = failed_write_close_calls + 1; return true end,
}, "write failure must fail safely")
assert(failed_write_close_calls == 1, "write failure must close the temporary file")

assert_export_failure({
    write = function() return true end,
    close = function() return nil, "flush failed" end,
}, "close failure must fail safely")

os.date = original_date

print("issue #10 CardStorage export harness: PASS")

-- Verify the Manage entry can export all cards and a selected book.
package.loaded["card_manager"] = nil
package.loaded["card_storage"] = nil
local ui_state = { shown = {}, exports = {}, cards = {
    { phrase = "one", book_title = "Book A" },
    { phrase = "two", book_title = "Book B" },
} }
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/menu"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/notification"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, options) return options end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) ui_state.shown[#ui_state.shown + 1] = widget end,
        close = function() end,
    }
end
package.preload["ui/event"] = function() return {} end
package.preload["card_storage"] = function()
    return {
        load_anki_settings = function() return nil end,
        load_cards = function() return ui_state.cards end,
        export_cards = function(cards, format)
            ui_state.exports[#ui_state.exports + 1] = { cards = cards, format = format }
            return "/data/anki_flashcards_export.csv", #cards
        end,
        clear_all = function() end,
        mark_sent = function() end,
        delete_card = function() end,
        update_card = function() end,
        update_image_path = function() end,
    }
end
package.preload["anki_sync"] = function() return { send_card = function() return true end } end
package.preload["card_generator"] = function() return {} end
package.preload["card_viewer"] = function() return {} end
package.preload["image_generator"] = function() return { images_enabled = function() return false end } end
package.preload["ui/network/manager"] = function() return {} end
package.preload["settings_viewer"] = function() return { show = function() end } end

local CardManager = require("card_manager")
local function export_menu()
    CardManager.show_manage({}, { ui = { document = { getProps = function()
        return { title = "Book A" }
    end } } })
    local manage = ui_state.shown[#ui_state.shown]
    for _, item in ipairs(manage.item_table) do
        if item.text == "Export Cards" then
            item.callback()
            return ui_state.shown[#ui_state.shown]
        end
    end
    error("Export Cards entry not found")
end

local scope = export_menu()
scope.buttons[1][1].callback()
local format = ui_state.shown[#ui_state.shown]
format.buttons[1][1].callback()
assert(ui_state.exports[1].format == "csv" and #ui_state.exports[1].cards == 2,
       "All Cards CSV export did not reach CardStorage")
assert(ui_state.shown[#ui_state.shown].text == "Exported 2 cards to /data/anki_flashcards_export.csv",
       "success notification must show exact path and count")

scope = export_menu()
scope.buttons[3][1].callback() -- Choose Book
local book_picker = ui_state.shown[#ui_state.shown]
book_picker.buttons[2][1].callback() -- Book B
format = ui_state.shown[#ui_state.shown]
format.buttons[2][1].callback()
assert(ui_state.exports[2].format == "tsv" and #ui_state.exports[2].cards == 1
       and ui_state.exports[2].cards[1].phrase == "two",
       "book-filtered TSV export did not reach CardStorage")

ui_state.cards = {
    { phrase = "titled unknown", book_title = "Unknown book" },
    { phrase = "untitled", book_title = "" },
}
local collision_exports = {}
for button_index = 1, 2 do
    scope = export_menu()
    scope.buttons[3][1].callback() -- Choose Book
    book_picker = ui_state.shown[#ui_state.shown]
    assert(book_picker.buttons[button_index][1].text == "Unknown book",
           "real and missing books must retain the Unknown book display label")
    book_picker.buttons[button_index][1].callback()
    format = ui_state.shown[#ui_state.shown]
    format.buttons[1][1].callback()
    collision_exports[button_index] = ui_state.exports[#ui_state.exports].cards
end
assert(#collision_exports[1] == 1 and #collision_exports[2] == 1
       and collision_exports[1][1].phrase ~= collision_exports[2][1].phrase,
       "real Unknown book and no-book selections must export separately")
local collision_phrases = {
    [collision_exports[1][1].phrase] = true,
    [collision_exports[2][1].phrase] = true,
}
assert(collision_phrases["titled unknown"] and collision_phrases["untitled"],
       "Choose Book must export both real Unknown book and no-book cards independently")

ui_state.cards = {}
local shown_before = #ui_state.shown
export_menu()
assert(#ui_state.exports == 4 and #ui_state.shown == shown_before + 2
       and ui_state.shown[#ui_state.shown].text == "No cards to export",
       "zero-card export must notify without creating an export")

print("issue #10 Card Manager export harness: PASS")
