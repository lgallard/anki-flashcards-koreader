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
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local _                = require("gettext")

local Screen = Device.screen

local PTF_HEADER     = "\xEF\xBF\xB1"  -- U+FFF1  required prefix to activate PTF parsing
local PTF_BOLD_START = "\xEF\xBF\xB2"  -- U+FFF2
local PTF_BOLD_END   = "\xEF\xBF\xB3"  -- U+FFF3

local function ptf_bold(s)
    return PTF_BOLD_START .. s .. PTF_BOLD_END
end

-- ── Content formatters ────────────────────────────────────────────────────────

local function blank_cloze(text)
    return (text or ""):gsub("{{c%d+::(.-)}}",  "[...]")
end

local function reveal_cloze(text)
    return (text or ""):gsub("{{c%d+::(.-)}}",
        PTF_BOLD_START .. "%1" .. PTF_BOLD_END)
end

-- Colors for special fields (tuned for e-ink visibility).
local COLOR_ORANGE = Blitbuffer.ColorRGB32(0x7A, 0x35, 0x00, 0xFF)  -- synonyms: very dark orange
local COLOR_RED    = Blitbuffer.ColorRGB32(0xBB, 0x00, 0x00, 0xFF)  -- IPA: deep red
local COLOR_BLUE   = Blitbuffer.ColorRGB32(0x00, 0x3A, 0x75, 0xFF)  -- phrase (back): dark navy blue

-- Fields available for editing (shown on back only).
-- IPA and Source are intentionally excluded: IPA is auto-regenerated when Phrase changes,
-- and Source is auto-updated to the Cambridge URL for the new phrase.
local EDITABLE_FIELDS = {
    { key = "phrase",     label = "Phrase" },
    { key = "definition", label = "Definition" },
    { key = "synonyms",   label = "Synonyms" },
    { key = "text",       label = "Text (cloze)" },
}

-- ── Widget ────────────────────────────────────────────────────────────────────

local CardViewer = InputContainer:extend {
    card           = nil,   -- card table: { phrase, ipa, definition, synonyms, text, source, image_path, … }
    show_back      = false, -- false = front (question), true = back (answer)
    on_show_answer = nil,   -- function() — called when user flips to back
    on_save        = nil,   -- function() -> true | nil, err
    on_send        = nil,   -- function() -> true | nil, err
    on_regenerate  = nil,   -- function()
    on_update      = nil,   -- function(card) — called after a field edit (to persist)
    on_regen_ipa   = nil,   -- function(new_phrase, card, new_viewer) — async IPA regen after phrase change
    on_navigate_to_source = nil, -- function() — jump to highlight position in book
    on_regen_text  = nil,   -- function() — regenerate example sentence only
    on_regen_image = nil,   -- function() — regenerate image only
    on_highlight_dialog = nil, -- function() — open KOReader's native highlight dialog (color, style, delete…)
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
        if self.on_highlight_dialog then
            table.insert(buttons_row, {
                text     = _("Highlight"),
                callback = function()
                    self:onClose()
                    self.on_highlight_dialog()
                end,
            })
        end
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

        if not self.read_only and self.on_regenerate then
            table.insert(buttons_row, {
                text     = _("↻"),
                callback = function() self.on_regenerate() end,
            })
        end

        if self.on_navigate_to_source then
            table.insert(buttons_row, {
                text     = _("Go to"),
                callback = function() self.on_navigate_to_source() end,
            })
        end

        if self.on_highlight_dialog then
            table.insert(buttons_row, {
                text     = _("Highlight"),
                callback = function()
                    self:onClose()
                    self.on_highlight_dialog()
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

    -- Build a scaled ImageWidget (scale to width, max 40% of content height).
    -- Tapping the image opens a full-screen zoomable viewer.
    local function make_image_widget(image_path)
        if not image_path or image_path == "" then return nil, 0 end
        local max_h = math.floor(total_content_h * 0.40)
        -- Scale to full width; let ImageWidget compute the natural height.
        local img = ImageWidget:new {
            file         = image_path,
            width        = inner_w,
            scale_factor = 0,
        }
        local img_h = img:getSize().h
        -- If the image is taller than 40% of content area, re-create with a height cap.
        if img_h > max_h then
            img:free()
            img = ImageWidget:new {
                file         = image_path,
                width        = inner_w,
                height       = max_h,
                scale_factor = 0,
            }
            img_h = max_h
        end
        self._tap_image_widget = img
        self._tap_image_path   = image_path
        return img, img_h
    end

    -- Build a ScrollTextWidget for one content section.
    -- justified=true enables full justification (implies left alignment).
    -- w overrides the default inner_w (used for multi-column layouts).
    local function make_text(text, face, height, color, align, justified, w)
        return ScrollTextWidget:new {
            text      = PTF_HEADER .. (text or ""),  -- header activates PTF bold parsing
            face      = face,
            fgcolor   = color,
            width     = w or inner_w,
            height    = math.max(1, height),
            dialog    = self,
            alignment = justified and "left" or (align or "center"),
            justified = justified or false,
        }
    end

    local gap = Size.padding.default
    -- Available height for all content widgets (inside the frame's padding/margin).
    local avail_h = total_content_h - 2 * self.text_padding - 2 * self.text_margin

    if not self.show_back then
        -- ── FRONT ─────────────────────────────────────────────────────────────
        -- Layout (top→bottom): Definition · Synonyms (orange) · Image · Cloze (blanked)
        local c          = self.card or {}
        local face       = Font:getFace("smallinfofont")
        local img_widget, image_h = make_image_widget(c.image_path)
        local n_gaps     = img_widget and 3 or 2
        local text_h     = avail_h - image_h - n_gaps * gap
        local def_h      = math.max(1, math.floor(text_h * 0.30))
        local syn_h      = math.max(1, math.floor(text_h * 0.20))
        local cloze_h    = math.max(1, text_h - def_h - syn_h)

        local def_w   = make_text(c.definition or "",              face, def_h,   nil,          "left")
        local syn_w   = make_text(ptf_bold(c.synonyms or ""),     face, syn_h,   COLOR_ORANGE)
        local cloze_w = make_text(blank_cloze(c.text or ""),      face, cloze_h)
        self.scroll_text_w = cloze_w

        local items = { def_w, VerticalSpan:new{height=gap}, syn_w }
        if img_widget then
            table.insert(items, VerticalSpan:new{height=gap})
            table.insert(items, img_widget)
        end
        table.insert(items, VerticalSpan:new{height=gap})
        table.insert(items, cloze_w)
        content_widget = VerticalGroup:new(items)

    else
        -- ── BACK ──────────────────────────────────────────────────────────────
        -- Layout (top→bottom): Definition · Image · Phrase (blue) · IPA (red) · Cloze
        local c          = self.card or {}
        local face       = Font:getFace("smallinfofont")
        local img_widget, image_h = make_image_widget(c.image_path)
        local n_gaps     = img_widget and 4 or 3
        local text_h     = avail_h - image_h - n_gaps * gap
        local def_h      = math.max(1, math.floor(text_h * 0.30))
        local phrase_h   = math.max(1, math.floor(text_h * 0.12))
        local ipa_h      = math.max(1, math.floor(text_h * 0.10))
        local cloze_h    = math.max(1, text_h - def_h - phrase_h - ipa_h)

        local def_w    = make_text(c.definition or "",          face, def_h,    nil,        "left")
        local phrase_w = make_text(ptf_bold(c.phrase or ""),    face, phrase_h, COLOR_BLUE)
        local ipa_w    = make_text(ptf_bold(c.ipa or ""),       face, ipa_h,    COLOR_RED)
        local cloze_w  = make_text(reveal_cloze(c.text or ""), face, cloze_h)
        self.scroll_text_w = cloze_w

        local items = { def_w }
        if img_widget then
            table.insert(items, VerticalSpan:new{height=gap})
            table.insert(items, img_widget)
        end
        table.insert(items, VerticalSpan:new{height=gap})
        table.insert(items, phrase_w)
        table.insert(items, VerticalSpan:new{height=gap})
        table.insert(items, ipa_w)
        table.insert(items, VerticalSpan:new{height=gap})
        table.insert(items, cloze_w)
        content_widget = VerticalGroup:new(items)
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
    for _i, f in ipairs(EDITABLE_FIELDS) do
        local fref = f
        table.insert(field_buttons, {{
            text     = _(fref.label),
            callback = function()
                UIManager:close(sel_dlg)
                self:editField(fref)
            end,
        }})
    end
    if self.on_regen_text then
        table.insert(field_buttons, {{
            text     = _("Regen sentence"),
            callback = function()
                UIManager:close(sel_dlg)
                self.on_regen_text()
            end,
        }})
    end
    if self.on_regen_image then
        table.insert(field_buttons, {{
            text     = _("Regen image"),
            callback = function()
                UIManager:close(sel_dlg)
                self.on_regen_image()
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
        title   = _("Edit: ") .. field_def.label,
        input   = current,
        buttons = {{
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
                    -- Defer widget-tree changes until after the current
                    -- event cycle completes (avoids crash mid-callback).
                    UIManager:scheduleIn(0, function()
                        local old_phrase = self.card.phrase
                        self.card[field_def.key] = new_val
                        -- When phrase changes: auto-update Cambridge source URL,
                        -- clear stale IPA, then trigger async IPA regeneration.
                        local phrase_changed = field_def.key == "phrase"
                                               and new_val ~= old_phrase
                        if phrase_changed then
                            local slug = new_val:lower():gsub("%s+", "-")
                            self.card.source = "https://dictionary.cambridge.org/dictionary/english/" .. slug
                            self.card.ipa    = ""
                        end
                        if self.on_update then self.on_update(self.card) end
                        local new_v = self:update()
                        if phrase_changed and self.on_regen_ipa then
                            self.on_regen_ipa(new_val, self.card, new_v)
                        end
                    end)
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
        card                  = card,
        show_back             = show_back,
        on_show_answer        = self.on_show_answer,
        on_save               = self.on_save,
        on_send               = self.on_send,
        on_regenerate         = self.on_regenerate,
        on_update             = self.on_update,
        on_regen_ipa          = self.on_regen_ipa,
        on_navigate_to_source = self.on_navigate_to_source,
        on_regen_text         = self.on_regen_text,
        on_regen_image        = self.on_regen_image,
        on_highlight_dialog   = self.on_highlight_dialog,
        read_only             = self.read_only,
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
    -- Don't close while any dialog (InputDialog, ButtonDialog, VirtualKeyboard…) is on top.
    if UIManager:getTopmostVisibleWidget() ~= self then
        return true
    end
    -- Tap on image → open full-screen zoomable viewer.
    if self._tap_image_widget and self._tap_image_path
       and self._tap_image_widget.dimen
       and ges_ev.pos:intersectWith(self._tap_image_widget.dimen) then
        local ImageViewer = require("ui/widget/imageviewer")
        UIManager:show(ImageViewer:new {
            file       = self._tap_image_path,
            fullscreen = true,
        })
        return true
    end
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
