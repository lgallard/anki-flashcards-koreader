-- Full-screen Anki flashcard viewer with front/back experience.
--
-- Front: shows Phrase + IPA with a "Show Answer" button.
-- Back:  shows the image (when ready) + all fields + action buttons.
--
-- Modelled on chatgptviewer.lua.

local BD               = require("ui/bidi")
local Blitbuffer       = require("ffi/blitbuffer")
local ButtonDialog     = require("ui/widget/buttondialog")
local ButtonTable      = require("ui/widget/buttontable")
local CenterContainer  = require("ui/widget/container/centercontainer")
local Device           = require("device")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local ImageWidget      = require("ui/widget/imagewidget")
local InputContainer   = require("ui/widget/container/inputcontainer")
local InputDialog      = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification     = require("ui/widget/notification")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size             = require("ui/size")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local _                = require("gettext")

local Screen = Device.screen

local PTF_BOLD_START = "\xEF\xBF\xB2"  -- U+FFF2
local PTF_BOLD_END   = "\xEF\xBF\xB3"  -- U+FFF3

local function ptf_bold(s)
    return PTF_BOLD_START .. s .. PTF_BOLD_END
end

-- ── Content formatters ────────────────────────────────────────────────────────

local function format_front(card)
    local c = card or {}
    return (c.phrase or "") .. "\n\n" .. (c.ipa or "")
end

local function format_back(card)
    local c = card or {}
    local lines = {
        ptf_bold("[Phrase]")     .. "      " .. (c.phrase     or ""),
        ptf_bold("[IPA]")        .. "         " .. (c.ipa        or ""),
        ptf_bold("[Definition]") .. "  "       .. (c.definition or ""),
        ptf_bold("[Synonyms]")   .. "   "      .. (c.synonyms   or ""),
        ptf_bold("[Text]")       .. "        " .. (c.text       or ""),
        ptf_bold("[Source]")     .. "      "   .. (c.source     or ""),
    }
    return table.concat(lines, "\n\n")
end

-- Fields available for editing (shown on back only).
local EDITABLE_FIELDS = {
    { key = "phrase",     label = "Phrase" },
    { key = "ipa",        label = "IPA" },
    { key = "definition", label = "Definition" },
    { key = "synonyms",   label = "Synonyms" },
    { key = "text",       label = "Text (cloze)" },
    { key = "source",     label = "Source" },
}

-- ── Widget ────────────────────────────────────────────────────────────────────

local CardViewer = InputContainer:extend {
    card           = nil,   -- card table: { phrase, ipa, definition, synonyms, text, source, image_path, … }
    show_back      = false, -- false = front (question), true = back (answer)
    on_show_answer = nil,   -- function() — called when user flips to back
    on_save        = nil,   -- function() -> true | nil, err
    on_send        = nil,   -- function() -> true | nil, err
    on_regenerate  = nil,   -- function()
    read_only      = false,

    text_padding   = Size.padding.large,
    text_margin    = Size.margin.small,
    button_padding = Size.padding.default,
}

function CardViewer:init()
    self.align  = "center"
    self.region = Geom:new {
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    local std_w = math.min(Screen:getWidth(), Screen:getHeight()) - Screen:scaleBySize(30)
    self.width  = std_w
    self.height = std_w

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    if Device:isTouchDevice() then
        local range = Geom:new { x=0, y=0, w=Screen:getWidth(), h=Screen:getHeight() }
        self.ges_events = {
            TapClose = { GestureRange:new { ges = "tap",   range = range } },
            Swipe    = { GestureRange:new { ges = "swipe", range = range } },
        }
    end

    local titlebar = TitleBar:new {
        width            = self.width,
        align            = "left",
        with_bottom_line = true,
        title            = _("Anki Flashcard"),
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }

    -- ── Button row ────────────────────────────────────────────────────────────
    local buttons_row = {}

    if not self.show_back then
        -- Front: Show Answer + Close
        table.insert(buttons_row, {
            text     = _("▼ Show Answer"),
            callback = function()
                if self.on_show_answer then self.on_show_answer() end
            end,
        })
        table.insert(buttons_row, {
            text     = _("Close"),
            callback = function() self:onClose() end,
        })
    else
        -- Back: full action buttons
        if not self.read_only then
            table.insert(buttons_row, {
                text     = _("✏️ Edit"),
                callback = function() self:showEditDialog() end,
            })
        end

        local CardStorage   = require("card_storage")
        local already_saved = self.card and CardStorage.is_saved(self.card.phrase or "")
        table.insert(buttons_row, {
            id      = "save",
            text    = already_saved and _("✓ Saved") or _("★ Save"),
            enabled = not already_saved,
            callback = function()
                if self.on_save then
                    local ok, err = self.on_save()
                    if ok then
                        UIManager:show(Notification:new { text = _("Saved!") })
                        local btn = self.button_table:getButtonById("save")
                        if btn then btn:disable(); btn:refresh() end
                    else
                        UIManager:show(Notification:new { text = err or _("Could not save") })
                    end
                end
            end,
        })

        table.insert(buttons_row, {
            text     = _("→ Anki"),
            callback = function()
                if self.on_send then
                    local ok, err = self.on_send()
                    if ok then
                        UIManager:show(Notification:new { text = _("Sent to Anki!") })
                    else
                        UIManager:show(Notification:new {
                            text = _("Anki error: ") .. (err or "unknown"),
                        })
                    end
                end
            end,
        })

        if not self.read_only then
            table.insert(buttons_row, {
                text     = _("↻"),
                callback = function()
                    if self.on_regenerate then self.on_regenerate() end
                end,
            })
        end

        table.insert(buttons_row, {
            text     = _("Close"),
            callback = function() self:onClose() end,
        })
    end

    self.button_table = ButtonTable:new {
        width       = self.width - 2 * self.button_padding,
        buttons     = { buttons_row },
        zero_sep    = true,
        show_parent = self,
    }

    -- ── Content area ──────────────────────────────────────────────────────────
    local total_content_h = self.height
                          - titlebar:getHeight()
                          - self.button_table:getSize().h
    local inner_w = self.width - 2 * self.text_padding - 2 * self.text_margin

    local content_widget

    -- Build a scaled ImageWidget that fits inner_w and at most 40% of the
    -- content area height, preserving the 16:9 generated image ratio.
    local function make_image_widget(image_path)
        if not image_path or image_path == "" then return nil, 0 end
        local natural_h = math.floor(inner_w * 9 / 16)
        local max_h     = math.floor(total_content_h * 0.40)
        local img_h     = math.min(natural_h, max_h)
        -- If height was capped, reduce width proportionally to stay in ratio.
        local img_w     = (img_h == natural_h) and inner_w
                          or math.floor(img_h * 16 / 9)
        local w = ImageWidget:new {
            file         = image_path,
            width        = img_w,
            height       = img_h,
            scale_factor = 0,   -- scale to fit bounding box, maintain ratio
        }
        return w, img_h
    end

    if not self.show_back then
        -- ── FRONT: optional image + centred phrase + IPA ──────────────────────
        local image_path = self.card and self.card.image_path
        local img_widget, image_h = make_image_widget(image_path)

        local front_face = Font:getFace("smallinfofont")
        local gap        = img_widget and Size.padding.default or 0
        local scroll_h   = total_content_h
                         - 2 * self.text_padding - 2 * self.text_margin
                         - image_h - gap
        self.scroll_text_w = ScrollTextWidget:new {
            text      = format_front(self.card),
            face      = front_face,
            width     = inner_w,
            height    = math.max(1, scroll_h),
            dialog    = self,
            alignment = "center",
            justified = false,
        }

        if img_widget then
            content_widget = VerticalGroup:new {
                img_widget,
                VerticalSpan:new { height = gap },
                self.scroll_text_w,
            }
        else
            content_widget = self.scroll_text_w
        end
    else
        -- ── BACK: optional image + all fields ────────────────────────────────
        local image_path = self.card and self.card.image_path
        local img_widget, image_h = make_image_widget(image_path)

        local text_face  = Font:getFace("xx_smallinfofont")
        local gap        = img_widget and Size.padding.default or 0
        local scroll_h   = total_content_h
                         - 2 * self.text_padding - 2 * self.text_margin
                         - image_h - gap
        self.scroll_text_w = ScrollTextWidget:new {
            text      = format_back(self.card),
            face      = text_face,
            width     = inner_w,
            height    = math.max(1, scroll_h),
            dialog    = self,
            alignment = "left",
            justified = false,
        }

        if img_widget then
            content_widget = VerticalGroup:new {
                img_widget,
                VerticalSpan:new { height = gap },
                self.scroll_text_w,
            }
        else
            content_widget = self.scroll_text_w
        end
    end

    self.textw = FrameContainer:new {
        padding    = self.text_padding,
        margin     = self.text_margin,
        bordersize = 0,
        content_widget,
    }

    self.frame = FrameContainer:new {
        radius     = Size.radius.window,
        padding    = 0,
        margin     = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new {
            titlebar,
            CenterContainer:new {
                dimen = Geom:new { w = self.width, h = self.textw:getSize().h },
                self.textw,
            },
            CenterContainer:new {
                dimen = Geom:new { w = self.width, h = self.button_table:getSize().h },
                self.button_table,
            },
        },
    }

    self.movable = MovableContainer:new {
        ignore_events = {
            "swipe", "hold", "hold_release", "hold_pan",
            "touch", "pan", "pan_release",
        },
        self.frame,
    }

    self[1] = WidgetContainer:new {
        align = self.align,
        dimen = self.region,
        self.movable,
    }
end

-- ── Edit flow (back only) ─────────────────────────────────────────────────────

function CardViewer:showEditDialog()
    local sel_dlg
    local field_buttons = {}
    for _, f in ipairs(EDITABLE_FIELDS) do
        local fref = f
        table.insert(field_buttons, {{
            text     = _(fref.label),
            callback = function()
                UIManager:close(sel_dlg)
                self:editField(fref)
            end,
        }})
    end
    table.insert(field_buttons, {{
        text     = _("Cancel"),
        callback = function() UIManager:close(sel_dlg) end,
    }})
    sel_dlg = ButtonDialog:new {
        title   = _("Edit field"),
        buttons = field_buttons,
    }
    UIManager:show(sel_dlg)
end

function CardViewer:editField(field_def)
    local current = self.card and self.card[field_def.key] or ""
    local input_dlg
    input_dlg = InputDialog:new {
        title      = _("Edit: ") .. field_def.label,
        input      = current,
        input_type = "text",
        buttons    = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(input_dlg) end,
            },
            {
                text             = _("OK"),
                is_enter_default = true,
                callback         = function()
                    local new_val = input_dlg:getInputText() or ""
                    UIManager:close(input_dlg)
                    self.card[field_def.key] = new_val
                    self:update()
                end,
            },
        }},
    }
    UIManager:show(input_dlg)
    input_dlg:onShowKeyboard()
end

-- ── Update (close+recreate) ───────────────────────────────────────────────────

-- Closes this viewer and opens a fresh one with the (possibly updated) card.
-- Preserves show_back state unless new_show_back is explicitly passed.
function CardViewer:update(new_card, new_show_back)
    local card      = new_card or self.card
    local show_back = new_show_back ~= nil and new_show_back or self.show_back
    UIManager:close(self)
    local updated = CardViewer:new {
        card           = card,
        show_back      = show_back,
        on_show_answer = self.on_show_answer,
        on_save        = self.on_save,
        on_send        = self.on_send,
        on_regenerate  = self.on_regenerate,
        read_only      = self.read_only,
    }
    UIManager:show(updated)
    return updated
end

-- ── Event handlers ────────────────────────────────────────────────────────────

function CardViewer:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "partial", self.frame.dimen
    end)
end

function CardViewer:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.frame.dimen
    end)
    return true
end

function CardViewer:onTapClose(arg, ges_ev)
    if ges_ev.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

function CardViewer:onSwipe(arg, ges)
    if ges.pos:intersectWith(self.textw.dimen) then
        local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
        if direction == "west" then
            self.scroll_text_w:scrollText(1)
            return true
        elseif direction == "east" then
            self.scroll_text_w:scrollText(-1)
            return true
        else
            UIManager:setDirty(nil, "full")
            return false
        end
    end
    return self.movable:onMovableSwipe(arg, ges)
end

function CardViewer:onClose()
    UIManager:close(self)
    return true
end

return CardViewer
