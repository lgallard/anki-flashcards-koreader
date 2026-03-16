-- Highlight Inbox — batch Anki flashcard creation from book highlights.
-- Shows all highlights for the open document; user selects which to convert.
-- Cards are generated sequentially and saved locally (send via "My Cards").

local NetworkMgr   = require("ui/network/manager")
local Menu         = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager    = require("ui/uimanager")
local _            = require("gettext")

local CardGenerator  = require("card_generator")
local CardStorage    = require("card_storage")
local ImageGenerator = require("image_generator")

local HighlightInbox = {}

local function normalize(s)
    return (s or ""):lower():match("^%s*(.-)%s*$")
end

local function clean(s, max_len)
    if not s then return "" end
    s = s:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
    if max_len and #s > max_len then s = s:sub(1, max_len) end
    return s
end

local function capitalize_first(s)
    return (s:gsub("^%l", string.upper))
end

local function cambridge_url(phrase, config)
    local lang = config and config.target_language or "English"
    if lang ~= "English" then return nil end
    local slug = (phrase or ""):lower():gsub("%s+", "-")
    return "https://dictionary.cambridge.org/dictionary/english/" .. slug
end

-- Internal: build and show the selection menu with current state.
local function show_menu(ui, config, highlights, already_carded, selected)
    local menu_ref = {}

    local function count_selected()
        local n = 0
        for _, v in pairs(selected) do if v then n = n + 1 end end
        return n
    end

    -- Defer close+reopen to after the current tap event has fully completed.
    -- This avoids modifying the menu while KOReader is still processing it.
    local function rebuild()
        UIManager:scheduleIn(0, function()
            if menu_ref[1] then UIManager:close(menu_ref[1]) end
            show_menu(ui, config, highlights, already_carded, selected)
        end)
    end

    local items   = {}
    local sel_cnt = count_selected()

    -- ▶ Generate Selected ────────────────────────────────────────────────────
    table.insert(items, {
        text     = _("Generate Selected (") .. tostring(sel_cnt) .. ")",
        bold     = true,
        callback = function()
            local to_do = {}
            for i, h in ipairs(highlights) do
                if selected[i] then table.insert(to_do, h) end
            end
            if #to_do == 0 then
                UIManager:show(Notification:new {
                    text    = _("Nothing selected."),
                    timeout = 3,
                })
                return
            end

            if menu_ref[1] then UIManager:close(menu_ref[1]) end

            local book_props = (ui.document and ui.document:getProps()) or {}
            local title = clean(book_props.title or "", 100)
            local author = book_props.authors or ""
            if type(author) == "table" then author = table.concat(author, ", ") end
            author = clean((author ~= "" and author or "Unknown Author"), 100)

            local total     = #to_do
            local done      = 0
            local failed    = 0
            local prog_notif

            local function show_progress(i)
                if prog_notif then UIManager:close(prog_notif) end
                prog_notif = Notification:new {
                    text    = _("Generating ") .. tostring(i) .. "/" .. tostring(total) .. "…",
                    timeout = 60,
                }
                UIManager:show(prog_notif)
            end

            local function finish()
                if prog_notif then UIManager:close(prog_notif) end
                local msg = tostring(done) .. _(" card(s) saved")
                if failed > 0 then
                    msg = msg .. ", " .. tostring(failed) .. _(" failed")
                end
                UIManager:show(Notification:new { text = msg, timeout = 5 })
            end

            local function generate_next(i)
                if i > total then finish(); return end
                local h      = to_do[i]
                local phrase = capitalize_first(clean(h.text or "", 2000))
                show_progress(i)
                UIManager:scheduleIn(0.05, function()
                    local card, err = CardGenerator.generate(
                        config, phrase, phrase, title, author
                    )
                    if card then
                        card.source      = cambridge_url(card.phrase, config)
                        card.book_title  = title
                        card.book_author = author
                        CardStorage.save_card(card)
                        done = done + 1
                        if card.image_prompt then
                            ImageGenerator.generate_async(
                                config, card.image_prompt, card.phrase,
                                function(img_path)
                                    card.image_path = img_path
                                    CardStorage.update_image_path(card.phrase, img_path)
                                end,
                                nil
                            )
                        end
                    else
                        failed = failed + 1
                    end
                    generate_next(i + 1)
                end)
            end

            NetworkMgr:runWhenOnline(function()
                generate_next(1)
            end)
        end,
    })

    -- ✓ Select All / ✗ Deselect All ─────────────────────────────────────────
    local uncarded = 0
    for _, h in ipairs(highlights) do
        if not already_carded[normalize(h.text)] then uncarded = uncarded + 1 end
    end
    if uncarded > 0 then
        table.insert(items, {
            text     = sel_cnt > 0 and _("✗ Deselect All") or _("✓ Select All"),
            callback = function()
                local new_val = sel_cnt == 0
                for i, h in ipairs(highlights) do
                    if not already_carded[normalize(h.text)] then
                        selected[i] = new_val
                    end
                end
                rebuild()
            end,
        })
    end

    -- Highlight list ─────────────────────────────────────────────────────────
    for i, h in ipairs(highlights) do
        local is_carded = already_carded[normalize(h.text)]
        local check     = is_carded and "✓ " or (selected[i] and "☑ " or "☐ ")
        local preview   = clean(h.text or "", 2000)
        if #preview > 60 then preview = preview:sub(1, 60) .. "…" end
        local chapter   = (h.chapter and h.chapter ~= "") and ("  [" .. h.chapter .. "]") or ""
        local label     = check .. preview .. chapter
        local idx       = i
        table.insert(items, {
            text     = label,
            callback = function()
                if not is_carded then
                    selected[idx] = not selected[idx]
                    rebuild()
                end
            end,
        })
    end

    local total_label = tostring(#highlights) .. _(" highlight(s)")
    local m = Menu:new {
        title      = _("Highlights to Anki Cards  (") .. total_label .. ")",
        item_table = items,
    }
    menu_ref[1] = m
    UIManager:show(m)
end

-- Public entry point. Call with self.ui and CONFIGURATION from main.lua.
function HighlightInbox.show(ui, config)
    -- Collect annotations from the open document.
    local raw        = (ui.annotation and ui.annotation.annotations) or {}
    local highlights = {}
    for _, ann in ipairs(raw) do
        -- Only visual highlights (drawer present) with non-empty text.
        if ann.drawer and ann.text and ann.text ~= "" then
            table.insert(highlights, ann)
        end
    end

    if #highlights == 0 then
        UIManager:show(Notification:new {
            text    = _("No highlights found in this book."),
            timeout = 3,
        })
        return
    end

    -- Build a lookup of already-carded phrases.
    local already_carded = {}
    for _, card in ipairs(CardStorage.load_cards()) do
        already_carded[normalize(card.phrase)] = true
    end

    -- Pre-select all highlights not yet converted to cards.
    local selected = {}
    for i, h in ipairs(highlights) do
        selected[i] = not already_carded[normalize(h.text)]
    end

    show_menu(ui, config, highlights, already_carded, selected)
end

return HighlightInbox
