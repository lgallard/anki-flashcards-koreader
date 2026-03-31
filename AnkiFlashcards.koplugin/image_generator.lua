-- Async image generator with multi-provider support.
--
-- Supported providers:
--   dashscope    — Alibaba DashScope (Qwen Wanx). Requires API key.
--   pollinations — Pollinations.ai (Flux). Free, no API key needed.
--   gemini       — Google Gemini Flash. Requires API key + billing.
--   openai       — OpenAI (GPT Image, DALL-E). Requires API key.
--   openrouter   — OpenRouter (Gemini, Flux, etc.). Requires API key.
--
-- Provider is selected via config.image_provider (default: "dashscope").
--
-- Public API:
--   ImageGenerator.generate_async(config, image_prompt, phrase, on_success, on_error)

local https       = require("ssl.https")
local http        = require("socket.http")
local ltn12       = require("ltn12")
local json        = require("json")
local mime        = require("mime")
local DataStorage = require("datastorage")

local IMAGE_DIR = DataStorage:getDataDir() .. "/.anki_images"

local ImageGenerator = {}

-- ── Shared helpers ──────────────────────────────────────────────────────────

local function ensure_image_dir()
    os.execute("mkdir -p '" .. IMAGE_DIR .. "'")
end

-- Build a unique filename from the phrase + timestamp.
local function make_save_path(phrase)
    local safe = (phrase or "card"):lower():gsub("[^%w%-%_]", "_"):sub(1, 40)
    return IMAGE_DIR .. "/" .. safe .. "_" .. os.time() .. ".png"
end

-- Download URL to a local file, returning (true) or (false, err).
local function download_image(url, save_path)
    ensure_image_dir()
    local requester = url:find("^https") and require("ssl.https") or require("socket.http")
    local saved_timeout = requester.TIMEOUT
    requester.TIMEOUT = 15
    local response = {}
    local ok, code = requester.request {
        url  = url,
        sink = ltn12.sink.table(response),
    }
    requester.TIMEOUT = saved_timeout
    if tostring(code) ~= "200" then
        return false, "Image download HTTP " .. tostring(code)
    end
    local f, ferr = io.open(save_path, "wb")
    if not f then return false, "Cannot write image: " .. tostring(ferr) end
    f:write(table.concat(response))
    f:close()
    return true
end

-- Resize a PNG file in-place using crop-to-fill so the image covers the
-- full target area with no black bars.  Falls back silently if RenderImage
-- is unavailable.
local function resize_image(path, target_w, target_h)
    local ok, RenderImage = pcall(require, "ui/renderimage")
    if not ok then return end
    local ok2, BlitBuffer = pcall(require, "ffi/blitbuffer")
    if not ok2 then return end

    -- Load at native resolution to get original dimensions.
    local orig = RenderImage:renderImageFile(path, false)
    if not orig then return end
    local orig_w, orig_h = orig:getWidth(), orig:getHeight()
    orig:free()
    if orig_w == 0 or orig_h == 0 then return end

    -- Scale so the image *covers* the target (crop-to-fill).
    local scale = math.max(target_w / orig_w, target_h / orig_h)
    local scaled_w = math.ceil(orig_w * scale)
    local scaled_h = math.ceil(orig_h * scale)

    local bb = RenderImage:renderImageFile(path, false, scaled_w, scaled_h)
    if not bb then return end

    local bw, bh = bb:getWidth(), bb:getHeight()
    if bw == target_w and bh == target_h then
        pcall(bb.writePNG, bb, path)
        bb:free()
        return
    end

    -- Crop the center region to exact target dimensions.
    local crop = BlitBuffer.new(target_w, target_h, bb:getType())
    local ox = math.max(0, math.floor((bw - target_w) / 2))
    local oy = math.max(0, math.floor((bh - target_h) / 2))
    crop:blitFrom(bb, 0, 0, ox, oy, target_w, target_h)
    bb:free()

    pcall(crop.writePNG, crop, path)
    crop:free()
end

-- ── DashScope provider ──────────────────────────────────────────────────────

local DASHSCOPE_BASE_URL  = "https://dashscope-intl.aliyuncs.com/api/v1"
local DASHSCOPE_CREATE_URL = DASHSCOPE_BASE_URL .. "/services/aigc/text2image/image-synthesis"
local DASHSCOPE_TASK_URL   = DASHSCOPE_BASE_URL .. "/tasks/"
local DASHSCOPE_MODEL      = "qwen-image-plus"

local NEGATIVE_PROMPT =
    "text, words, letters, numbers, watermark, signature, blurry, " ..
    "low quality, deformed, realistic, photorealistic, 3d render"

local function dashscope_https_request(method, url, api_key, body, extra_headers)
    local response = {}
    https.TIMEOUT = 15
    http.TIMEOUT  = 15
    local headers = {
        ["Authorization"] = "Bearer " .. api_key,
        ["Content-Type"]  = "application/json",
    }
    if extra_headers then
        for k, v in pairs(extra_headers) do headers[k] = v end
    end
    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local ok, code = https.request {
        url     = url,
        method  = method,
        headers = headers,
        source  = body and ltn12.source.string(body) or nil,
        sink    = ltn12.sink.table(response),
    }
    if tostring(code) == "429" then
        return nil, "RATE_LIMITED"
    end
    if tostring(code) ~= "200" then
        local detail = table.concat(response):sub(1, 300)
        return nil, "HTTP " .. tostring(code) .. ": " .. detail
    end
    local ok2, data = pcall(json.decode, table.concat(response))
    if not ok2 then return nil, "JSON decode error" end
    return data
end

local function dashscope_create_task(api_key, image_prompt)
    local prompt =
        "Modern anime-style illustration: " .. (image_prompt or "") ..
        ". Widescreen 16:9 composition, vibrant colors, clean lines, " ..
        "professional quality. No text, words, letters or numbers anywhere."
    local body = json.encode({
        model  = DASHSCOPE_MODEL,
        input  = {
            prompt          = prompt,
            negative_prompt = NEGATIVE_PROMPT,
        },
        parameters = {
            size           = "1664*928",
            n              = 1,
            watermark      = false,
            prompt_extend  = true,
        },
    })
    local data, err = dashscope_https_request(
        "POST", DASHSCOPE_CREATE_URL, api_key, body,
        { ["X-DashScope-Async"] = "enable" }
    )
    if not data then return nil, err end
    if not (data.output and data.output.task_id) then
        return nil, "No task_id in response"
    end
    return data.output.task_id
end

local function dashscope_check_task(api_key, task_id)
    local data, err = dashscope_https_request("GET", DASHSCOPE_TASK_URL .. task_id, api_key)
    if not data then return nil, err end
    local output = data.output
    if not output then return nil, "No output in response" end
    local status = output.task_status
    if status == "SUCCEEDED" then
        if output.results and output.results[1] and output.results[1].url then
            return "SUCCEEDED", output.results[1].url
        end
        return nil, "No image URL in task results"
    elseif status == "FAILED" then
        return nil, "DashScope task failed: " .. (output.message or "unknown")
    end
    return status  -- "PENDING" or "RUNNING"
end

local function dashscope_generate(config, image_prompt, phrase, on_success, on_error)
    local api_key = config and config.dashscope_api_key
    if not api_key or api_key == "" then
        if on_error then on_error("DashScope API key not configured") end
        return
    end

    local UIManager = require("ui/uimanager")
    local save_path = make_save_path(phrase)

    local function start_polling(task_id)
        local attempts = 0
        local function poll()
            attempts = attempts + 1
            if attempts > 20 then
                if on_error then on_error("Image generation timed out") end
                return
            end
            local status, url_or_err = dashscope_check_task(api_key, task_id)
            if status == "SUCCEEDED" then
                local ok2, dl_err = download_image(url_or_err, save_path)
                if ok2 then
                    resize_image(save_path, 768, 432)
                    if on_success then on_success(save_path) end
                else
                    if on_error then on_error(dl_err) end
                end
            elseif status == nil then
                if url_or_err == "RATE_LIMITED" then
                    UIManager:scheduleIn(15, poll)
                else
                    if on_error then on_error(url_or_err) end
                end
            else
                UIManager:scheduleIn(5, poll)
            end
        end
        UIManager:scheduleIn(5, poll)
    end

    local function try_create()
        local task_id, err = dashscope_create_task(api_key, image_prompt)
        if not task_id then
            if err == "RATE_LIMITED" then
                UIManager:scheduleIn(15, try_create)
            else
                if on_error then on_error(err) end
            end
            return
        end
        start_polling(task_id)
    end

    UIManager:scheduleIn(0.5, try_create)
end

-- ── Pollinations provider ───────────────────────────────────────────────────

-- URL-encode a string for use in the Pollinations endpoint path.
local function url_encode(str)
    return (str:gsub("[^%w%-%.%_%~ ]", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "%%20"))
end

-- Write a self-contained download helper to /tmp so we can run it as a
-- background luajit subprocess without blocking the KOReader UI thread.
local DOWNLOAD_HELPER = "/tmp/anki_download.lua"

local function ensure_download_helper()
    local f = io.open(DOWNLOAD_HELPER, "r")
    if f then f:close() return true end
    f = io.open(DOWNLOAD_HELPER, "w")
    if not f then return false end
    f:write([=[
require("setupkoenv")
local https = require("ssl.https")
local ltn12  = require("ltn12")
https.TIMEOUT = 60
local url, save_path, done_file = arg[1], arg[2], arg[3]
local r = {}
local _, c = https.request{url = url, sink = ltn12.sink.table(r)}
c = tostring(c)
if c == "200" then
    local f = io.open(save_path, "wb")
    if f then f:write(table.concat(r)) f:close() end
end
local d = io.open(done_file, "w")
if d then d:write(c) d:close() end
]=])
    f:close()
    return true
end

local POLLINATIONS_USER_HINT =
    "Pollinations is unreliable. Consider switching to another image provider in Anki Settings."

local function pollinations_generate(config, image_prompt, phrase, on_success, on_error)
    local UIManager = require("ui/uimanager")
    local save_path = make_save_path(phrase)
    ensure_image_dir()

    if not ensure_download_helper() then
        if on_error then on_error("Cannot create download helper") end
        return
    end

    local prompt =
        "Modern anime-style illustration: " .. (image_prompt or "") ..
        ". Widescreen 16:9 composition, vibrant colors, clean lines, " ..
        "professional quality. No text, words, letters or numbers anywhere."

    local encoded = url_encode(prompt)
    local url = "https://image.pollinations.ai/prompt/" .. encoded
             .. "?width=768&height=432&nologo=true&seed=" .. os.time()

    -- Marker file: luajit subprocess writes HTTP status code here on completion.
    local done_file = save_path .. ".done"
    os.remove(done_file)
    os.remove(save_path)

    -- Launch luajit in the background so the UI thread is never blocked.
    -- The helper script uses KOReader's own SSL stack via setupkoenv.
    os.execute(string.format(
        "./luajit '%s' '%s' '%s' '%s' &",
        DOWNLOAD_HELPER, url, save_path, done_file
    ))

    local attempts = 0
    local max_attempts = 10  -- 10 × 3s = 30s (fail fast — service is unreliable)
    local function poll()
        attempts = attempts + 1

        -- done_file appears once the subprocess finishes (success or failure).
        local f = io.open(done_file, "r")
        if f then
            local code = f:read("*a"):match("%d+")
            f:close()
            os.remove(done_file)

            if code == "200" then
                local img = io.open(save_path, "rb")
                if img then
                    local size = img:seek("end")
                    img:close()
                    if size and size > 100 then
                        resize_image(save_path, 768, 432)
                        if on_success then on_success(save_path) end
                        return
                    end
                end
                os.remove(save_path)
                if on_error then on_error("Pollinations returned empty image. " .. POLLINATIONS_USER_HINT) end
            else
                os.remove(save_path)
                if on_error then on_error("Pollinations error (HTTP " .. (code or "?") .. "). " .. POLLINATIONS_USER_HINT) end
            end
            return
        end

        if attempts >= max_attempts then
            os.remove(done_file)
            os.remove(save_path)
            if on_error then on_error("Pollinations timed out. " .. POLLINATIONS_USER_HINT) end
            return
        end

        UIManager:scheduleIn(3, poll)
    end

    UIManager:scheduleIn(3, poll)
end

-- ── Gemini Flash provider ──────────────────────────────────────────────────

local GEMINI_URL =
    "https://generativelanguage.googleapis.com/v1beta/models/"
    .. "gemini-2.5-flash-image:generateContent"

local function gemini_generate(config, image_prompt, phrase, on_success, on_error)
    local api_key = config and config.gemini_api_key
    if not api_key or api_key == "" then
        if on_error then on_error("Gemini API key not configured") end
        return
    end

    local UIManager = require("ui/uimanager")
    local save_path = make_save_path(phrase)

    local function do_generate()
        local prompt =
            "Modern anime-style illustration: " .. (image_prompt or "") ..
            ". Widescreen 16:9 composition, vibrant colors, clean lines, " ..
            "professional quality. No text, words, letters or numbers anywhere."

        local body = json.encode({
            contents = {{ parts = {{ text = prompt }} }},
            generationConfig = {
                responseModalities = { "IMAGE" },
                imageConfig = {
                    aspectRatio = "16:9",
                },
            },
        })

        local response = {}
        https.TIMEOUT = 30
        local _, code = https.request {
            url     = GEMINI_URL .. "?key=" .. api_key,
            method  = "POST",
            headers = {
                ["Content-Type"]   = "application/json",
                ["Content-Length"]  = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink   = ltn12.sink.table(response),
        }

        if tostring(code) ~= "200" then
            local detail = table.concat(response):sub(1, 300)
            if on_error then on_error("Gemini HTTP " .. tostring(code) .. ": " .. detail) end
            return
        end

        local ok2, data = pcall(json.decode, table.concat(response))
        if not ok2 or not data then
            if on_error then on_error("Gemini JSON decode error") end
            return
        end

        -- Extract base64 image from response.
        local b64_data, img_mime
        if data.candidates and data.candidates[1]
           and data.candidates[1].content
           and data.candidates[1].content.parts then
            for _pi, part in ipairs(data.candidates[1].content.parts) do
                if part.inlineData and part.inlineData.data then
                    b64_data = part.inlineData.data
                    img_mime = part.inlineData.mimeType
                    break
                end
            end
        end

        if not b64_data then
            if on_error then on_error("No image in Gemini response") end
            return
        end

        -- Decode base64 and save to disk.
        local image_bytes = mime.unb64(b64_data)
        if not image_bytes or #image_bytes < 100 then
            if on_error then on_error("Gemini returned empty image") end
            return
        end

        ensure_image_dir()
        local f = io.open(save_path, "wb")
        if not f then
            if on_error then on_error("Cannot write image file") end
            return
        end
        f:write(image_bytes)
        f:close()

        resize_image(save_path, 768, 432)
        if on_success then on_success(save_path) end
    end

    UIManager:scheduleIn(0.5, function()
        local ok, err = pcall(do_generate)
        if not ok and on_error then
            on_error("Gemini error: " .. tostring(err))
        end
    end)
end

-- ── OpenAI image provider ──────────────────────────────────────────────────

-- Background POST helper — runs API call + image extraction in a luajit
-- subprocess so the UI thread is never blocked.
local POST_HELPER = "/tmp/anki_post_image.lua"

local function ensure_post_helper()
    local f = io.open(POST_HELPER, "r")
    if f then f:close() return true end
    f = io.open(POST_HELPER, "w")
    if not f then return false end
    f:write([=[
require("setupkoenv")
local https = require("ssl.https")
local ltn12  = require("ltn12")
local json   = require("json")
local mime   = require("mime")
https.TIMEOUT = 60
local body_file, api_key, save_path, done_file = arg[1], arg[2], arg[3], arg[4]
-- Read request body from temp file.
local bf = io.open(body_file, "r")
if not bf then
    local d = io.open(done_file, "w"); if d then d:write("error") d:close() end; return
end
local body = bf:read("*a"); bf:close(); os.remove(body_file)
-- Make the API call.
local r = {}
local _, c = https.request{
    url     = "https://api.openai.com/v1/images/generations",
    method  = "POST",
    headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
        ["Content-Length"] = tostring(#body),
    },
    source = ltn12.source.string(body),
    sink   = ltn12.sink.table(r),
}
c = tostring(c)
if c == "200" then
    local ok, data = pcall(json.decode, table.concat(r))
    if ok and data and data.data and data.data[1] then
        local b64 = data.data[1].b64_json
        local url = data.data[1].url
        if b64 then
            local bytes = mime.unb64(b64)
            if bytes then
                local out = io.open(save_path, "wb")
                if out then out:write(bytes) out:close() end
            end
        elseif url then
            local img = {}
            local _, ic = https.request{url = url, sink = ltn12.sink.table(img)}
            if tostring(ic) == "200" then
                local out = io.open(save_path, "wb")
                if out then out:write(table.concat(img)) out:close() end
            end
        end
    end
end
local d = io.open(done_file, "w")
if d then d:write(c) d:close() end
]=])
    f:close()
    return true
end

local function openai_generate(config, image_prompt, phrase, on_success, on_error)
    local api_key = config and config.openai_api_key
    if not api_key or api_key == "" then
        if on_error then on_error("OpenAI API key not configured") end
        return
    end

    local UIManager = require("ui/uimanager")
    local save_path = make_save_path(phrase)
    ensure_image_dir()

    if not ensure_post_helper() then
        if on_error then on_error("Cannot create image helper") end
        return
    end

    local prompt =
        "Modern anime-style illustration: " .. (image_prompt or "") ..
        ". Widescreen 16:9 composition, vibrant colors, clean lines, " ..
        "professional quality. No text, words, letters or numbers anywhere."

    local body = json.encode({
        model  = config.openai_image_model or "gpt-image-1",
        prompt = prompt,
        n      = 1,
        size   = "1536x1024",
    })

    -- Write request body to a temp file for the subprocess.
    local body_file = save_path .. ".body"
    local done_file = save_path .. ".done"
    os.remove(body_file)
    os.remove(done_file)
    os.remove(save_path)

    local bf = io.open(body_file, "w")
    if not bf then
        if on_error then on_error("Cannot write request body") end
        return
    end
    bf:write(body)
    bf:close()

    -- Launch luajit in the background.
    os.execute(string.format(
        "./luajit '%s' '%s' '%s' '%s' '%s' &",
        POST_HELPER, body_file, api_key, save_path, done_file
    ))

    local attempts = 0
    local max_attempts = 30  -- 30 × 3s = 90s
    local function poll()
        attempts = attempts + 1

        local f = io.open(done_file, "r")
        if f then
            local code = f:read("*a"):match("%d+")
            f:close()
            os.remove(done_file)

            if code == "200" then
                local img = io.open(save_path, "rb")
                if img then
                    local size = img:seek("end")
                    img:close()
                    if size and size > 100 then
                        resize_image(save_path, 768, 432)
                        if on_success then on_success(save_path) end
                        return
                    end
                end
                os.remove(save_path)
                if on_error then on_error("OpenAI returned empty image") end
            else
                os.remove(save_path)
                if on_error then on_error("OpenAI HTTP " .. (code or "error")) end
            end
            return
        end

        if attempts >= max_attempts then
            os.remove(done_file)
            os.remove(save_path)
            os.remove(body_file)
            if on_error then on_error("Image generation timed out") end
            return
        end

        UIManager:scheduleIn(3, poll)
    end

    UIManager:scheduleIn(3, poll)
end

-- ── OpenRouter image provider ─────────────────────────────────────────────

-- Background POST helper for OpenRouter — uses the chat completions endpoint
-- with modalities=["image"]. Response contains base64 data-URL in
-- choices[].message.images[].image_url.url.
local OPENROUTER_IMAGE_HELPER = "/tmp/anki_openrouter_image.lua"

local function ensure_openrouter_image_helper()
    local f = io.open(OPENROUTER_IMAGE_HELPER, "r")
    if f then f:close() return true end
    f = io.open(OPENROUTER_IMAGE_HELPER, "w")
    if not f then return false end
    f:write([=[
require("setupkoenv")
local https = require("ssl.https")
local ltn12  = require("ltn12")
local json   = require("json")
local mime   = require("mime")
https.TIMEOUT = 90
local body_file, api_key, save_path, done_file = arg[1], arg[2], arg[3], arg[4]
-- Read request body from temp file.
local bf = io.open(body_file, "r")
if not bf then
    local d = io.open(done_file, "w"); if d then d:write("error") d:close() end; return
end
local body = bf:read("*a"); bf:close(); os.remove(body_file)
-- Make the API call.
local r = {}
local _, c = https.request{
    url     = "https://openrouter.ai/api/v1/chat/completions",
    method  = "POST",
    headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
        ["Content-Length"] = tostring(#body),
    },
    source = ltn12.source.string(body),
    sink   = ltn12.sink.table(r),
}
c = tostring(c)
if c == "200" then
    local ok, data = pcall(json.decode, table.concat(r))
    if ok and data and data.choices and data.choices[1]
       and data.choices[1].message and data.choices[1].message.images
       and data.choices[1].message.images[1] then
        local img_entry = data.choices[1].message.images[1]
        local data_url = img_entry.image_url and img_entry.image_url.url
        if data_url then
            -- Strip "data:image/...;base64," prefix.
            local b64 = data_url:match("base64,(.+)")
            if b64 then
                local bytes = mime.unb64(b64)
                if bytes then
                    local out = io.open(save_path, "wb")
                    if out then out:write(bytes) out:close() end
                end
            end
        end
    end
end
local d = io.open(done_file, "w")
if d then d:write(c) d:close() end
]=])
    f:close()
    return true
end

local function openrouter_image_generate(config, image_prompt, phrase, on_success, on_error)
    local api_key = config and config.openrouter_api_key
    if not api_key or api_key == "" then
        if on_error then on_error("OpenRouter API key not configured") end
        return
    end

    local UIManager = require("ui/uimanager")
    local save_path = make_save_path(phrase)
    ensure_image_dir()

    if not ensure_openrouter_image_helper() then
        if on_error then on_error("Cannot create image helper") end
        return
    end

    local prompt =
        "Modern anime-style illustration: " .. (image_prompt or "") ..
        ". Widescreen 16:9 composition, vibrant colors, clean lines, " ..
        "professional quality. No text, words, letters or numbers anywhere."

    local body = json.encode({
        model      = config.openrouter_image_model or "google/gemini-3.1-flash-image-preview",
        messages   = {{ role = "user", content = prompt }},
        modalities = { "image" },
        image_config = {
            aspect_ratio = "16:9",
            image_size   = "1K",
        },
    })

    -- Write request body to a temp file for the subprocess.
    local body_file = save_path .. ".body"
    local done_file = save_path .. ".done"
    os.remove(body_file)
    os.remove(done_file)
    os.remove(save_path)

    local bf = io.open(body_file, "w")
    if not bf then
        if on_error then on_error("Cannot write request body") end
        return
    end
    bf:write(body)
    bf:close()

    -- Launch luajit in the background.
    os.execute(string.format(
        "./luajit '%s' '%s' '%s' '%s' '%s' &",
        OPENROUTER_IMAGE_HELPER, body_file, api_key, save_path, done_file
    ))

    local attempts = 0
    local max_attempts = 30  -- 30 × 3s = 90s
    local function poll()
        attempts = attempts + 1

        local f = io.open(done_file, "r")
        if f then
            local code = f:read("*a"):match("%d+")
            f:close()
            os.remove(done_file)

            if code == "200" then
                local img = io.open(save_path, "rb")
                if img then
                    local size = img:seek("end")
                    img:close()
                    if size and size > 100 then
                        resize_image(save_path, 768, 432)
                        if on_success then on_success(save_path) end
                        return
                    end
                end
                os.remove(save_path)
                if on_error then on_error("OpenRouter returned empty image") end
            else
                os.remove(save_path)
                if on_error then on_error("OpenRouter HTTP " .. (code or "error")) end
            end
            return
        end

        if attempts >= max_attempts then
            os.remove(done_file)
            os.remove(save_path)
            os.remove(body_file)
            if on_error then on_error("Image generation timed out") end
            return
        end

        UIManager:scheduleIn(3, poll)
    end

    UIManager:scheduleIn(3, poll)
end

-- ── AnkiVocab provider (download pre-generated image from URL) ──────────────

-- Poll the AnkiVocab API to fetch the image URL for a word.
-- The server generates images asynchronously, so the URL may not be available
-- in the initial card generation response.  Returns (url, nil) or (nil, err).
-- IMPORTANT: this runs inside UIManager callbacks, so the HTTP timeout must be
-- short to avoid freezing the e-ink UI.
local function ankivocab_poll_image_url(config, word)
    local api_url = config.ankivocab_url
    local api_key = config.ankivocab_api_key
    if not api_url or api_url == "" or not api_key or api_key == "" then
        return nil, "AnkiVocab not configured"
    end
    api_url = api_url:gsub("/$", "")
    local endpoint = api_url .. "/v1/cards/generate"
    local body = json.encode({
        word          = word,
        include_image = true,
        include_audio = false,
    })
    local response_body = {}
    local requester = endpoint:find("^https") and https or http
    -- Short timeout — this blocks the UI thread on e-ink devices.
    local saved_timeout = requester.TIMEOUT
    requester.TIMEOUT = 10
    local poll_ok, poll_code = pcall(function()
        return select(2, requester.request {
            url     = endpoint,
            method  = "POST",
            headers = {
                ["Content-Type"]  = "application/json",
                ["X-API-Key"]     = api_key,
                ["Content-Length"] = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink   = ltn12.sink.table(response_body),
        })
    end)
    requester.TIMEOUT = saved_timeout
    if not poll_ok then
        return nil, "request error: " .. tostring(poll_code)
    end
    if tostring(poll_code) ~= "200" then
        return nil, "HTTP " .. tostring(poll_code)
    end
    local ok, data = pcall(json.decode, table.concat(response_body))
    if not ok or not data then return nil, "JSON decode error" end
    if type(data.image_url) == "string" and data.image_url ~= "" then
        return data.image_url
    end
    return nil, "image not ready"
end

local function ankivocab_generate(config, image_prompt, phrase, on_success, on_error)
    local UIManager    = require("ui/uimanager")
    local Notification = require("ui/widget/notification")
    local _            = require("gettext")
    local save_path = make_save_path(phrase)

    -- The image URL may be passed directly from the card generation response,
    -- or we may need to poll the API until the server finishes generating it.
    local image_url = config._ankivocab_image_url
    local word = config._ankivocab_word or phrase

    -- Helper: download and deliver the image once we have a URL.
    local function download_and_finish(url)
        ensure_image_dir()
        local ok, err = download_image(url, save_path)
        if ok then
            resize_image(save_path, 768, 432)
            if on_success then on_success(save_path) end
        else
            if on_error then on_error(err or "Image download failed") end
        end
    end

    -- If the URL is already available, download directly.
    if type(image_url) == "string" and image_url ~= "" then
        UIManager:scheduleIn(0.5, function()
            download_and_finish(image_url)
        end)
        return
    end

    -- URL not available yet — poll the AnkiVocab API until the image is ready.
    local attempts = 0
    local max_attempts = 6  -- 6 × 10s = 60s

    local function poll()
        attempts = attempts + 1
        if attempts > max_attempts then
            if on_error then on_error("AnkiVocab image not ready — try Regen Image later") end
            return
        end
        local url, _err = ankivocab_poll_image_url(config, word)
        if url then
            download_and_finish(url)
        else
            UIManager:scheduleIn(10, poll)
        end
    end

    -- First poll after 10s to give the server time to generate.
    UIManager:scheduleIn(10, poll)
end

-- ── Provider dispatch ───────────────────────────────────────────────────────

local PROVIDERS = {
    dashscope    = dashscope_generate,
    pollinations = pollinations_generate,
    gemini       = gemini_generate,
    openai       = openai_generate,
    openrouter   = openrouter_image_generate,
    ankivocab    = ankivocab_generate,
}

-- ── Public API ──────────────────────────────────────────────────────────────

--- Kick off async image generation. Returns immediately.
--- on_success(image_path) called when the PNG is saved locally.
--- on_error(err_string) called on any failure; if nil, a Notification is shown.
function ImageGenerator.generate_async(config, image_prompt, phrase, on_success, on_error)
    -- Default on_error: show a wrapping InfoMessage so long errors are readable on e-ink.
    if not on_error then
        local InfoMessage = require("ui/widget/infomessage")
        local UIManager   = require("ui/uimanager")
        on_error = function(msg)
            UIManager:show(InfoMessage:new { text = msg, timeout = 5 })
        end
    end

    local provider_name = config and config.image_provider or "dashscope"

    -- AnkiVocab provides a direct image URL, no prompt needed.
    if provider_name ~= "ankivocab" and (not image_prompt or image_prompt == "") then
        on_error("No image prompt")
        return
    end
    local provider_fn = PROVIDERS[provider_name]
    if not provider_fn then
        on_error("Unknown image provider: " .. tostring(provider_name))
        return
    end

    provider_fn(config, image_prompt, phrase, on_success, on_error)
end

return ImageGenerator
