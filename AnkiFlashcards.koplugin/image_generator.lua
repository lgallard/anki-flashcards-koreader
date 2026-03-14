-- Async image generator with multi-provider support.
--
-- Supported providers:
--   dashscope    — Alibaba DashScope (Qwen Wanx). Requires API key.
--   pollinations — Pollinations.ai (Flux). Free, no API key needed.
--
-- Provider is selected via config.image_provider (default: "dashscope").
--
-- Public API:
--   ImageGenerator.generate_async(config, image_prompt, phrase, on_success, on_error)

local https       = require("ssl.https")
local http        = require("socket.http")
local ltn12       = require("ltn12")
local json        = require("json")
local DataStorage = require("datastorage")

local IMAGE_DIR = DataStorage:getDataDir() .. "/anki_images"

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
    requester.TIMEOUT = 30
    local response = {}
    local ok, code = requester.request {
        url  = url,
        sink = ltn12.sink.table(response),
    }
    if tostring(code) ~= "200" then
        return false, "Image download HTTP " .. tostring(code)
    end
    local f, ferr = io.open(save_path, "wb")
    if not f then return false, "Cannot write image: " .. tostring(ferr) end
    f:write(table.concat(response))
    f:close()
    return true
end

-- Resize a PNG file in-place using KOReader's own image rendering stack.
-- Falls back silently (keeps original) if RenderImage is unavailable.
local function resize_image(path, target_w, target_h)
    local ok, RenderImage = pcall(require, "ui/renderimage")
    if not ok then return end
    local bb = RenderImage:renderImageFile(path, false, target_w, target_h)
    if not bb then return end
    pcall(bb.writePNG, bb, path)
    bb:free()
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

local function pollinations_generate(config, image_prompt, phrase, on_success, on_error)
    local UIManager = require("ui/uimanager")
    local save_path = make_save_path(phrase)

    local prompt =
        "Modern anime-style illustration: " .. (image_prompt or "") ..
        ". Widescreen 16:9 composition, vibrant colors, clean lines, " ..
        "professional quality. No text, words, letters or numbers anywhere."

    local encoded = url_encode(prompt)
    local url = "https://image.pollinations.ai/prompt/" .. encoded
             .. "?width=1664&height=928&nologo=true&seed=" .. os.time()

    local function do_download()
        ensure_image_dir()
        local ok2, dl_err = download_image(url, save_path)
        if ok2 then
            resize_image(save_path, 768, 432)
            if on_success then on_success(save_path) end
        else
            if on_error then on_error(dl_err) end
        end
    end

    -- Schedule so the UI can render before blocking on the download.
    UIManager:scheduleIn(0.5, do_download)
end

-- ── Provider dispatch ───────────────────────────────────────────────────────

local PROVIDERS = {
    dashscope    = dashscope_generate,
    pollinations = pollinations_generate,
}

-- ── Public API ──────────────────────────────────────────────────────────────

--- Kick off async image generation. Returns immediately.
--- on_success(image_path) called when the PNG is saved locally.
--- on_error(err_string) called on any failure.
function ImageGenerator.generate_async(config, image_prompt, phrase, on_success, on_error)
    if not image_prompt or image_prompt == "" then
        if on_error then on_error("No image prompt") end
        return
    end

    local provider_name = config and config.image_provider or "dashscope"
    local provider_fn = PROVIDERS[provider_name]
    if not provider_fn then
        if on_error then on_error("Unknown image provider: " .. tostring(provider_name)) end
        return
    end

    provider_fn(config, image_prompt, phrase, on_success, on_error)
end

return ImageGenerator
