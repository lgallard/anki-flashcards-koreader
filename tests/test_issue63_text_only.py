import subprocess
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "AnkiFlashcards.koplugin"


def run_lua(script: str) -> None:
    """Run a self-contained LuaJIT/KOReader-stub behavior harness."""
    result = subprocess.run(
        ["luajit", "-"],
        input=textwrap.dedent(script),
        text=True,
        cwd=ROOT,
        capture_output=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


LUA_STUBS = r'''
package.path = "./AnkiFlashcards.koplugin/?.lua;" .. package.path
local state = { requests = {}, schedules = {}, image_calls = 0 }
_G.TEST_STATE = state

local function encode(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) == "boolean" or type(v) == "number" then return tostring(v) end
    if type(v) ~= "table" then return "null" end
    local out, n = {}, 0
    for k, value in pairs(v) do
        n = n + 1
        local key = type(k) == "number" and "" or string.format("%q:", k)
        out[#out + 1] = key .. encode(value)
    end
    return "{" .. table.concat(out, ",") .. "}"
end

package.preload["json"] = function()
    return {
        encode = encode,
        decode = function(raw)
            local responses = {
                TEXT_ONLY_CARD = { phrase = "Run", text = "{{c1::Run}} home" },
                IMAGE_CARD = { phrase = "Run", text = "{{c1::Run}} home", image_prompt = "scene" },
                TEXT_ONLY_REGEN = { text = "{{c1::Run}} home" },
                IMAGE_REGEN = { text = "{{c1::Run}} home", image_prompt = "scene" },
                ['{"_marker":"TEXT_ONLY_CARD"}'] = { phrase = "Run", text = "{{c1::Run}} home" },
                ['{"_marker":"IMAGE_CARD"}'] = { phrase = "Run", text = "{{c1::Run}} home", image_prompt = "scene" },
                ['{"_marker":"TEXT_ONLY_REGEN"}'] = { text = "{{c1::Run}} home" },
                ['{"_marker":"IMAGE_REGEN"}'] = { text = "{{c1::Run}} home", image_prompt = "scene" },
                ANKI_NO_IMAGE = { phrase = "run", text_cloze = "{{c1::run}} home" },
                ANKI_IMAGE = { phrase = "run", text_cloze = "{{c1::run}} home", image_prompt = "scene", image_url = "https://image" },
                TASK_CREATED = { output = { task_id = "task-1" } },
                LLM_TEXT_ONLY_CARD = { choices = {{ message = { content = '{"_marker":"TEXT_ONLY_CARD"}' } }} },
                LLM_IMAGE_CARD = { choices = {{ message = { content = '{"_marker":"IMAGE_CARD"}' } }} },
                LLM_TEXT_ONLY_REGEN = { choices = {{ message = { content = '{"_marker":"TEXT_ONLY_REGEN"}' } }} },
                LLM_IMAGE_REGEN = { choices = {{ message = { content = '{"_marker":"IMAGE_REGEN"}' } }} },
            }
            assert(responses[raw], "unexpected JSON response: " .. tostring(raw))
            return responses[raw]
        end,
    }
end
package.preload["ltn12"] = function()
    return { source = { string = function(s) return s end }, sink = { table = function(t)
        return function(chunk) if chunk then t[#t + 1] = chunk end end
    end } }
end
local requester = { TIMEOUT = 0 }
function requester.request(args)
    state.requests[#state.requests + 1] = args
    local response = state.next_response or "TEXT_ONLY_CARD"
    if args.sink then args.sink(response) end
    return 1, 200
end
package.preload["ssl.https"] = function() return requester end
package.preload["socket.http"] = function() return requester end
package.preload["mime"] = function() return { unb64 = function(s) return s end } end
package.preload["datastorage"] = function() return { getDataDir = function() return "/tmp" end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, seconds, callback)
            state.schedules[#state.schedules + 1] = { seconds = seconds, callback = callback }
        end,
        show = function() end, close = function() end, setDirty = function() end,
    }
end
'''


def test_local_generation_and_sentence_regeneration_use_image_free_schema_when_disabled():
    run_lua(
        LUA_STUBS
        + r'''
local CardGenerator = require("card_generator")
local disabled = { text_provider = "dashscope", dashscope_api_key = "key", images_enabled = false }
TEST_STATE.next_response = "LLM_TEXT_ONLY_CARD"
local card = assert(CardGenerator.generate(disabled, "Run", "context", "Title", "Author"))
assert(card.image_prompt == nil, "text-only card must parse without image_prompt")
local payload = TEST_STATE.requests[#TEST_STATE.requests].source
assert(not payload:find("image_prompt", 1, true), "text-only generation payload requested image schema")
TEST_STATE.next_response = "LLM_TEXT_ONLY_REGEN"
local text, prompt = CardGenerator.generate_text(disabled, "Run")
assert(text == "{{c1::Run}} home" and prompt == nil, "text-only sentence regeneration returned an image prompt")
payload = TEST_STATE.requests[#TEST_STATE.requests].source
assert(not payload:find("image_prompt", 1, true), "text-only regenerate payload requested image schema")

local enabled = { text_provider = "dashscope", dashscope_api_key = "key", images_enabled = true }
TEST_STATE.next_response = "LLM_IMAGE_CARD"
card = assert(CardGenerator.generate(enabled, "Run", "context", "Title", "Author"))
assert(card.image_prompt == "scene", "enabled generation lost image output")
payload = TEST_STATE.requests[#TEST_STATE.requests].source
assert(payload:find("image_prompt", 1, true), "enabled generation did not request image schema")
TEST_STATE.next_response = "LLM_IMAGE_REGEN"
text, prompt = CardGenerator.generate_text(enabled, "Run")
assert(prompt == "scene", "enabled sentence regeneration lost image output")
'''
    )


def test_ankivocab_serializes_and_maps_image_fields_by_setting():
    run_lua(
        LUA_STUBS
        + r'''
local CardGenerator = require("card_generator")
local disabled = { text_provider = "ankivocab", image_provider = "ankivocab", ankivocab_api_key = "key", images_enabled = false }
TEST_STATE.next_response = "ANKI_NO_IMAGE"
local card = assert(CardGenerator.generate(disabled, "Run", "context", "Title", "Author"))
local payload = TEST_STATE.requests[#TEST_STATE.requests].source
assert(payload:find('"include_image":false', 1, true), "disabled AnkiVocab request did not serialize include_image=false")
assert(card.image_prompt == nil and card._image_url == nil, "disabled AnkiVocab mapping retained image fields")

local enabled = { text_provider = "ankivocab", image_provider = "ankivocab", ankivocab_api_key = "key", images_enabled = true }
TEST_STATE.next_response = "ANKI_IMAGE"
card = assert(CardGenerator.generate(enabled, "Run", "context", "Title", "Author"))
payload = TEST_STATE.requests[#TEST_STATE.requests].source
assert(payload:find('"include_image":true', 1, true), "enabled AnkiVocab request did not serialize include_image=true")
assert(card.image_prompt == "scene" and card._image_url == "https://image", "enabled AnkiVocab mapping lost image output")
'''
    )


def test_image_generator_final_guard_blocks_provider_and_polling_but_enabled_dispatches():
    run_lua(
        LUA_STUBS
        + r'''
local ImageGenerator = require("image_generator")
ImageGenerator.generate_async({ images_enabled = false, image_provider = "dashscope", dashscope_api_key = "key" }, "scene", "run", nil, function() end)
assert(#TEST_STATE.schedules == 0 and #TEST_STATE.requests == 0, "disabled image generation dispatched work")

TEST_STATE.next_response = "TASK_CREATED"
ImageGenerator.generate_async({ images_enabled = true, image_provider = "dashscope", dashscope_api_key = "key" }, "scene", "run", nil, function() end)
assert(#TEST_STATE.schedules == 1 and TEST_STATE.schedules[1].seconds == 0.5, "enabled image generation did not schedule provider dispatch")
TEST_STATE.schedules[1].callback()
assert(#TEST_STATE.requests == 1, "enabled image generation did not reach provider boundary")
assert(#TEST_STATE.schedules == 2 and TEST_STATE.schedules[2].seconds == 5, "enabled DashScope flow did not schedule polling")
'''
    )


def test_inbox_guard_skips_image_launch_for_text_only_cards():
    run_lua(
        LUA_STUBS
        + r'''
local menu
package.preload["ui/network/manager"] = function() return { runWhenOnline = function(_, cb) cb() end } end
package.preload["ui/widget/menu"] = function() return { new = function(_, t) menu = t; return t end } end
package.preload["ui/widget/notification"] = function() return { new = function(_, t) return t end } end
package.preload["card_storage"] = function() return { load_cards = function() return {} end, save_card = function() return true end, update_image_path = function() end } end
package.preload["card_generator"] = function() return { generate = function() return { phrase = "run", text = "{{c1::run}} home" } end } end
package.preload["image_generator"] = function()
    return { images_enabled = function(config) return config.images_enabled ~= false end,
             generate_async = function() TEST_STATE.image_calls = TEST_STATE.image_calls + 1 end }
end
local Inbox = require("highlight_inbox")
Inbox.show({ document = { getProps = function() return { title = "Book", authors = "Author" } end }, annotation = { annotations = {{ drawer = true, text = "Run" }} } }, { images_enabled = false })
menu.item_table[1].callback()
assert(TEST_STATE.image_calls == 0, "inbox launched image generation in text-only mode")
'''
    )


def test_main_normal_regenerate_and_saved_card_paths_keep_image_callbacks_off():
    run_lua(
        LUA_STUBS
        + r'''
local registrations = {}
local viewer_options
package.preload["configuration"] = function() return { images_enabled = false, target_language = "English" } end
package.preload["device"] = function() return { hasClipboard = function() return true end } end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, t) return t end } end
package.preload["ui/widget/notification"] = function() return { new = function(_, t) return t end } end
package.preload["ui/widget/container/inputcontainer"] = function() return { new = function(_, t) return t end } end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, cb) cb() end, isOnline = function() return true end }
end
package.preload["selection_context"] = function() return function() return "context" end end
package.preload["card_generator"] = function()
    return {
        generate = function() return { phrase = "run", text = "{{c1::run}} home" } end,
        generate_text = function() return "{{c1::run}} again", nil end,
        generate_quick_lookup = function() return nil, "unused" end,
    }
end
package.preload["card_viewer"] = function()
    return { new = function(_, t)
        viewer_options = t
        return { update = function() return {} end }
    end }
end
package.preload["card_storage"] = function()
    return {
        load_anki_settings = function() return nil end,
        save_card = function() return true end,
        update_image_path = function() end,
        update_audio_url = function() end,
        find_by_position = function() return { phrase = "saved", text = "{{c1::saved}} card" } end,
        find_by_phrase_fuzzy = function() return nil end,
        load_cards = function() return {} end,
        mark_sent = function() end,
    }
end
package.preload["anki_sync"] = function() return { send_card = function() return true end } end
package.preload["card_manager"] = function() return { show = function() end, show_manage = function() end } end
package.preload["card_sync"] = function() return { run_sync = function() end } end
package.preload["highlight_inbox"] = function() return { show = function() end } end
package.preload["audio_generator"] = function() return { poll_ankivocab_async = function() end } end
package.preload["image_generator"] = function()
    return {
        images_enabled = function(config) return config.images_enabled ~= false end,
        generate_async = function() TEST_STATE.image_calls = TEST_STATE.image_calls + 1 end,
    }
end

local Plugin = require("main")
local highlight = {
    addToHighlightDialog = function(_, key, factory) registrations[key] = factory end,
    onClose = function() end,
    onTap = function() return false end,
    view = { highlight = { visible_boxes = {{ index = 1, rect = { x = 0, y = 0, w = 20, h = 20 } }} },
             screenToPageTransform = function(_, pos) return pos end },
}
local ui = {
    highlight = highlight,
    document = { getProps = function() return { title = "Book", authors = "Author" } end },
    annotation = { annotations = {{ pos0 = 1, pos1 = 2, text = "saved" }} },
}
highlight.ui = ui
Plugin.ui = ui
Plugin:init()

local action = registrations["ankiflashcards_4"]({ selected_text = "Run", saveHighlight = function() end })
action.callback()
-- init queued auto-send and auto-sync first; normal generation is the third callback.
TEST_STATE.schedules[3].callback()
assert(TEST_STATE.image_calls == 0, "normal text-only generation launched image work")
assert(viewer_options.on_regen_image == nil, "normal text-only viewer exposed image regeneration")
viewer_options.on_regen_text()
TEST_STATE.schedules[4].callback()
assert(TEST_STATE.image_calls == 0, "sentence regeneration launched image work in text-only mode")

highlight:onTap(nil, { pos = { x = 1, y = 1 } })
assert(TEST_STATE.image_calls == 0, "saved-card auto-image path launched image work in text-only mode")
assert(viewer_options.on_regen_image == nil, "saved-card viewer exposed image regeneration in text-only mode")
'''
    )
