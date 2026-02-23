-- Async image generator using Alibaba DashScope (Qwen Wanx).
-- Uses wan2.2-t2i-flash via the ImageSynthesis REST API.
-- International endpoint: https://dashscope-intl.aliyuncs.com/api/v1
--
-- Flow:
--   1. POST  /services/aigc/text2image/image-synthesis  → task_id
--   2. GET   /tasks/{task_id}  (every 2s)               → wait for SUCCEEDED
--   3. Download image URL → save PNG to KOReader data dir
--   4. Call on_success(path) or on_error(err)

local https       = require("ssl.https")
local http        = require("socket.http")
local ltn12       = require("ltn12")
local json        = require("json")
local DataStorage = require("datastorage")

local BASE_URL  = "https://dashscope-intl.aliyuncs.com/api/v1"
local CREATE_URL = BASE_URL .. "/services/aigc/text2image/image-synthesis"
local TASK_URL   = BASE_URL .. "/tasks/"
local MODEL      = "wan2.2-t2i-flash"
local IMAGE_DIR  = DataStorage:getDataDir() .. "/anki_images"

local NEGATIVE_PROMPT =
    "text, words, letters, numbers, watermark, signature, blurry, " ..
    "low quality, deformed, realistic, photorealistic, 3d render"

local ImageGenerator = {}

-- ── HTTP helpers ──────────────────────────────────────────────────────────────

local function https_request(method, url, api_key, body, extra_headers)
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
    if tostring(code) ~= "200" then
        local detail = table.concat(response):sub(1, 300)
        return nil, "HTTP " .. tostring(code) .. ": " .. detail
    end
    local ok2, data = pcall(json.decode, table.concat(response))
    if not ok2 then return nil, "JSON decode error" end
    return data
end

-- ── DashScope task lifecycle ──────────────────────────────────────────────────

local function create_task(api_key, image_prompt)
    local prompt =
        "Modern anime-style illustration: " .. (image_prompt or "") ..
        ". Widescreen 16:9 composition, vibrant colors, clean lines, " ..
        "professional quality. No text, words, letters or numbers anywhere."
    local body = json.encode({
        model  = MODEL,
        input  = {
            prompt          = prompt,
            negative_prompt = NEGATIVE_PROMPT,
        },
        parameters = {
            size      = "1024*576",
            n         = 1,
            watermark = false,
        },
    })
    local data, err = https_request(
        "POST", CREATE_URL, api_key, body,
        { ["X-DashScope-Async"] = "enable" }
    )
    if not data then return nil, err end
    if not (data.output and data.output.task_id) then
        return nil, "No task_id in response"
    end
    return data.output.task_id
end

-- Returns status string ("SUCCEEDED", "FAILED", "PENDING", "RUNNING")
-- and image URL on SUCCEEDED, or error string on FAILED.
local function check_task(api_key, task_id)
    local data, err = https_request("GET", TASK_URL .. task_id, api_key)
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

-- Download URL to a local file, returning (true) or (false, err).
local function download_image(url, save_path)
    os.execute("mkdir -p '" .. IMAGE_DIR .. "'")
    -- Choose transport based on scheme
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

-- ── Public API ────────────────────────────────────────────────────────────────

-- Kick off async image generation. Returns immediately.
-- on_success(image_path) called when the PNG is saved locally.
-- on_error(err_string) called on any failure.
function ImageGenerator.generate_async(config, image_prompt, phrase, on_success, on_error)
    local api_key = config and config.dashscope_api_key
    if not api_key or api_key == "" then
        if on_error then on_error("DashScope API key not configured") end
        return
    end
    if not image_prompt or image_prompt == "" then
        if on_error then on_error("No image prompt") end
        return
    end

    local UIManager = require("ui/uimanager")

    -- Step 1: Create the image task.
    local task_id, err = create_task(api_key, image_prompt)
    if not task_id then
        if on_error then on_error(err) end
        return
    end

    -- Build a safe filename from the phrase.
    local safe = (phrase or "card"):lower():gsub("[^%w%-%_]", "_"):sub(1, 40)
    local save_path = IMAGE_DIR .. "/" .. safe .. ".png"

    -- Step 2: Poll until SUCCEEDED (or failure / timeout).
    local attempts = 0
    local function poll()
        attempts = attempts + 1
        if attempts > 30 then
            if on_error then on_error("Image generation timed out") end
            return
        end
        local status, url_or_err = check_task(api_key, task_id)
        if status == "SUCCEEDED" then
            local ok2, dl_err = download_image(url_or_err, save_path)
            if ok2 then
                if on_success then on_success(save_path) end
            else
                if on_error then on_error(dl_err) end
            end
        elseif status == nil then
            if on_error then on_error(url_or_err) end
        else
            -- Still PENDING or RUNNING — try again in 2 seconds.
            UIManager:scheduleIn(2, poll)
        end
    end

    -- Give the API a 3-second head start before first poll.
    UIManager:scheduleIn(3, poll)
end

return ImageGenerator
