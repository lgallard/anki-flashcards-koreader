-- Full-screen Anki flashcard viewer.
-- Modelled on chatgptviewer.lua with card-specific buttons and edit flow.

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
local InputContainer   = require("ui/widget/container/inputcontainer")
local InputDialog      = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification     = require("ui/widget/notification")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size             = require("ui/size")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local _                = require("gettext")

local Screen = Device.screen

local PTF_BOLD_START = "\xEF\xBF\xB2"  -- U+FFF2
local PTF_BOLD_END   = "\xEF\xBF\xB3"  -- U+FFF3

local function ptf_bold(s)
    return PTF_BOLD_START .. s .. PTF_BOLD_END
end

-- Format the card table into display text using PTF bold for field labels.
local function format_card(card)
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

-- Fields available for editing.
local EDITABLE_FIELDS = {
    { key = "phrase",     label = "Phrase" },
    { key = "ipa",        label = "IPA" },
    { key = "definition", label = "Definition" },
    { key = "synonyms",   label = "Synonyms" },
    { key = "text",       label = "Text (cloze)" },
    { key = "source",     label = "Source" },
}

local CardViewer = InputContainer:extend {
    card          = nil,   -- card table: { phrase, ipa, definition, synonyms, text, source, … }
    on_save       = nil,   -- function() -> true | nil, err_string
    on_send       = nil,   -- function() -> true | nil, err_string
    on_regenerate = nil,   -- function()
    read_only     = false, -- hides Edit and Regenerate when true

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

    -- ── Build button row ──────────────────────────────────────────────────────
    local buttons_row = {}

    if not self.read_only then
        table.insert(buttons_row, {
            text     = _("✏️ Edit"),
            callback = function() self:showEditDialog() end,
        })
    end

    -- Save button — disabled when already saved.
    local CardStorage   = require("card_storage")
    local already_saved = self.card and CardStorage.is_saved(self.card.phrase or "")
    table.insert(buttons_row, {
        id       = "save",
        text     = already_saved and _("✓ Saved") or _("★ Save"),
        enabled  = not already_saved,
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

    -- Send to Anki button.
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

    self.button_table = ButtonTable:new {
        width       = self.width - 2 * self.button_padding,
        buttons     = { buttons_row },
        zero_sep    = true,
        show_parent = self,
    }

    -- ── Text content area ─────────────────────────────────────────────────────
    local text_content = format_card(self.card)
    local text_face    = Font:getFace("xx_smallinfofont")

    local textw_h = self.height - titlebar:getHeight() - self.button_table:getSize().h
    local inner_w = self.width  - 2 * self.text_padding - 2 * self.text_margin
    local inner_h = textw_h    - 2 * self.text_padding - 2 * self.text_margin

    self.scroll_text_w = ScrollTextWidget:new {
        text      = text_content,
        face      = text_face,
        width     = inner_w,
        height    = math.max(1, inner_h),
        dialog    = self,
        alignment = "left",
        justified = false,
    }

    self.textw = FrameContainer:new {
        padding    = self.text_padding,
        margin     = self.text_margin,
        bordersize = 0,
        self.scroll_text_w,
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

-- Show a ButtonDialog listing every editable field, then open InputDialog.
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

-- Open an InputDialog pre-filled with the current field value.
-- On OK, update card in-place and recreate the viewer.
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

-- Close this viewer and open a fresh one with the (possibly updated) card.
-- Follows the same close+recreate pattern as ChatGPTViewer:update().
function CardViewer:update(new_card)
    local card = new_card or self.card
    UIManager:close(self)
    local updated = CardViewer:new {
        card          = card,
        on_save       = self.on_save,
        on_send       = self.on_send,
        on_regenerate = self.on_regenerate,
        read_only     = self.read_only,
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
