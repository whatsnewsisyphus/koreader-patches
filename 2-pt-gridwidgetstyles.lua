--[[
    KOReader User Patch: Custom Progress Bar Styling for Project: Title

    This patch allows full customization of the progress bar appearance:
    - Height and border radius
    - Position (left, right, bottom margins)
    - Track background color based on book status
    - Fill color based on book status (reading, abandoned, complete)
    - Border width and color
    - Last opened book highlighting (border + optional fill color)
    - Completed books show as short right-aligned bars
    - Optional status badges (reading / abandoned / complete / on_hold)
    - Optional page-count-based bar width ("bookthickbar")
    - Optional page-count badge (P(###) in filename)
    - Optional folder badges:
        * Name badge at top-left of cover
        * Count badge "books[folders]" at bottom-left of cover

    Compatible with Project: Title plugin (coverbrowser mosaic view).
]]--

local userpatch   = require("userpatch")
local logger      = require("logger")
local Screen      = require("device").screen
local Blitbuffer  = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Font        = require("ui/font")
local RenderText  = require("ui/rendertext")

-- ============================================================================
-- CUSTOM SETTINGS - Edit these to customize your progress bar appearance
-- ============================================================================

local SETTINGS = {
    -- Dimensions
    height        = Screen:scaleBySize(11),
    border_radius = Screen:scaleBySize(5),
    border_width  = Screen:scaleBySize(0),

    -- Fill insets (padding inside the track)
    fill_inset_vertical   = Screen:scaleBySize(2),
    fill_inset_horizontal = Screen:scaleBySize(2),

    -- Position (distance from inner cover edges)
    margin_left   = Screen:scaleBySize(4),
    margin_right  = Screen:scaleBySize(4),
    margin_bottom = Screen:scaleBySize(8),

    -- Corner icon settings (status badges)
    show_status_badges    = true,
    gap_with_status_badge = Screen:scaleBySize(4),
    status_badge_gap      = false,

    -- Per-status badge visibility
    status_badge_show_reading   = false,
    status_badge_show_complete  = true,
    status_badge_show_abandoned = true,
    status_badge_show_on_hold   = true,

    -- Status badge appearance
    status_badge_icon_size       = Screen:scaleBySize(19),
    status_badge_background_size = Screen:scaleBySize(21),

    match_listviewstatusicons = true,
    complete_width = Screen:scaleBySize(9),

    -- Track colors (background) by status
    track_color = {
        reading   = "#fafafa",
        complete  = "#b0b0b0",
        on_hold   = "#b0b0b0",
        abandoned = "#b0b0b0",
        default   = "#fafafa",
    },

    -- Fill colors (progress) by status
    fill_color = {
        reading   = "#555555",
        complete  = "#666666",
        on_hold   = "#888888",
        abandoned = "#888888",
        default   = "#555555",
    },

    border_color = "#606060",
    last_opened_border_width = Screen:scaleBySize(0),
    last_opened_border_color = "#555555",
    last_opened_fill_color   = "#111111",

    ------------------------------------------------------------------------
    -- Book thickness bar options
    ------------------------------------------------------------------------
    bookthickbar               = true,
    bookthickbar_unopenedbooks = false,
    bookthickbar_min_pages     = 100,
    bookthickbar_max_pages     = 650,
    bookthickbar_min_fraction  = 0.25,
    bookthickbar_max_fraction  = 1.0,

    ------------------------------------------------------------------------
    -- Page-number and Folder Name badge options
    ------------------------------------------------------------------------
    page_badge_font        = "source/SourceSans3-Regular.ttf",
    page_badge_enabled     = true,
    page_badge_corner      = "bottom_left",
    page_badge_x_offset    = Screen:scaleBySize(-4),
    page_badge_y_offset    = Screen:scaleBySize(4),
    page_badge_width       = nil,
    page_badge_height      = nil,
    page_badge_radius      = Screen:scaleBySize(2),
    page_badge_border_width= Screen:scaleBySize(0),
    page_badge_border_color= "#606060",
    page_badge_bg_color    = "#dadada",
    page_badge_text_color  = "#333333",
    page_badge_text_size   = Screen:scaleBySize(9),
    page_badge_padding_x   = Screen:scaleBySize(4),
    page_badge_padding_y   = Screen:scaleBySize(4),

    style_folder_badges       = true,
    folder_name_badge_font    = "source/SourceSerif4-Regular.ttf",
    folder_name_badge_enabled = true,
    folder_badge_enabled      = true,
    folder_name_badge_bg_color    = "#ffffff",
    folder_name_badge_border_color= nil,
    folder_name_badge_text_color  = nil,
    folder_name_badge_x_offset    = nil,
    folder_name_badge_y_offset    = Screen:scaleBySize(0),

    debug_logging = false,
}

-- ============================================================================
-- COLOR CACHE
-- ============================================================================

local COLOR = nil

local function initColors()
    if COLOR then return end
    COLOR = {}

    for key, val in pairs(SETTINGS.track_color) do
        COLOR["track_" .. key] = Blitbuffer.colorFromString(val)
    end
    for key, val in pairs(SETTINGS.fill_color) do
        COLOR["fill_" .. key] = Blitbuffer.colorFromString(val)
    end

    COLOR.border             = Blitbuffer.colorFromString(SETTINGS.border_color)
    COLOR.last_opened_border = Blitbuffer.colorFromString(SETTINGS.last_opened_border_color)

    if SETTINGS.last_opened_fill_color then
        COLOR.fill_last_opened = Blitbuffer.colorFromString(SETTINGS.last_opened_fill_color)
    end

    COLOR.badge_bg = Blitbuffer.colorFromString("#f0f0f0")
    COLOR.page_badge_border = Blitbuffer.colorFromString(SETTINGS.page_badge_border_color)
    COLOR.page_badge_bg     = Blitbuffer.colorFromString(SETTINGS.page_badge_bg_color)
    COLOR.page_badge_text   = Blitbuffer.colorFromString(SETTINGS.page_badge_text_color)

    COLOR.folder_name_badge_bg = Blitbuffer.colorFromString(SETTINGS.folder_name_badge_bg_color or SETTINGS.page_badge_bg_color)
    COLOR.folder_name_badge_border = Blitbuffer.colorFromString(SETTINGS.folder_name_badge_border_color or SETTINGS.page_badge_border_color)
    COLOR.folder_name_badge_text = Blitbuffer.colorFromString(SETTINGS.folder_name_badge_text_color or SETTINGS.page_badge_text_color)
end

-- ============================================================================
-- Helpers & Render Functions
-- ============================================================================

local function round(v)
    return math.floor(v + 0.5)
end

local function safeGetFace(name, size)
    name = name or "ffont"
    local face = Font:getFace(name, size)
    if not face then
        logger.warn("[ProgressBar] Could not load font: " .. tostring(name) .. ", falling back to ffont")
        face = Font:getFace("ffont", size)
    end
    return face
end

local function getPageCountFromPath(path)
    if not path then return nil end
    local filename = path:match("([^/]+)$") or path
    local basename = filename:gsub("%.%w+$", "")
    local num_str = basename:match("P%((%d+)%)")
    if num_str then return tonumber(num_str) end
    return nil
end

local function computeThicknessFraction(page_count)
    if not page_count then return 0.66 end
    if page_count <= SETTINGS.bookthickbar_min_pages then return SETTINGS.bookthickbar_min_fraction end
    if page_count >= SETTINGS.bookthickbar_max_pages then return SETTINGS.bookthickbar_max_fraction end
    return SETTINGS.bookthickbar_min_fraction + (page_count - SETTINGS.bookthickbar_min_pages) * (SETTINGS.bookthickbar_max_fraction - SETTINGS.bookthickbar_min_fraction) / (SETTINGS.bookthickbar_max_pages - SETTINGS.bookthickbar_min_pages)
end

local function isStatusBadgeEnabledFor(status)
    if status == "reading" then return SETTINGS.status_badge_show_reading
    elseif status == "complete" then return SETTINGS.status_badge_show_complete
    elseif status == "abandoned" then return SETTINGS.status_badge_show_abandoned
    elseif status == "on_hold" then return SETTINGS.status_badge_show_on_hold
    end
    return false
end

-- Reusable badge drawing function (DRY implementation)
local function drawTextBadge(bb, text, face, align, bx, by, badge_w, badge_h, border_w, radius, color_border, color_bg, color_text, pad_x)
    if not face then return end

    local rt = RenderText:sizeUtf8Text(0, 1000, face, text, false, false)
    local text_w = rt.x

    if border_w > 0 then
        bb:paintRoundedRect(bx, by, badge_w, badge_h, color_border, radius)
    end

    local bg_x = bx + border_w
    local bg_y = by + border_w
    local bg_w = badge_w - 2 * border_w
    local bg_h = badge_h - 2 * border_w

    if bg_w > 0 and bg_h > 0 then
        bb:paintRoundedRect(bg_x, bg_y, bg_w, bg_h, color_bg, math.max(0, radius - border_w))
    else
        bg_x, bg_y, bg_w, bg_h = bx, by, badge_w, badge_h
    end

    local text_x
    if align == "left" then
        text_x = bg_x + pad_x
    else
        text_x = bg_x + math.floor((bg_w - text_w) / 2)
    end

    local center_y = bg_y + bg_h / 2
    local baseline = round(center_y - (rt.y_bottom - rt.y_top) / 2)

    RenderText:renderUtf8Text(bb, text_x, baseline, face, text, false, false, color_text)
end

local function drawCompleteIndicator(bb, left, right, iy, ih, bar_border_width, bar_border_color, fill_color)
    local slot_width = math.max(1, right - left)
    local indicator_h = SETTINGS.height
    local outer_w = math.min(SETTINGS.complete_width, slot_width)
    local inner_w = math.max(1, outer_w - 2 * bar_border_width)

    local inner_x = round(right - bar_border_width - inner_w)
    local inner_y = round(iy + ih - SETTINGS.margin_bottom - indicator_h)

    if bar_border_width > 0 then
        bb:paintRoundedRect(inner_x - bar_border_width, inner_y - bar_border_width, inner_w + 2 * bar_border_width, indicator_h + 2 * bar_border_width, bar_border_color, SETTINGS.border_radius + bar_border_width)
    end
    bb:paintRoundedRect(inner_x, inner_y, inner_w, indicator_h, fill_color, SETTINGS.border_radius)
end

local function drawProgressBar(bb, left, right, iy, ih, bar_border_width, bar_border_color, track_color, fill_color, pf)
    local slot_width = math.max(1, right - left)
    local bar_h = SETTINGS.height
    local bar_w = math.max(1, slot_width - 2 * bar_border_width)
    local bar_x = round(left + bar_border_width)
    local bar_y = round(iy + ih - SETTINGS.margin_bottom - bar_h)

    if bar_border_width > 0 then
        bb:paintRoundedRect(bar_x - bar_border_width, bar_y - bar_border_width, bar_w + 2 * bar_border_width, bar_h + 2 * bar_border_width, bar_border_color, SETTINGS.border_radius + bar_border_width)
    end
    bb:paintRoundedRect(bar_x, bar_y, bar_w, bar_h, track_color, SETTINGS.border_radius)

    local p = math.max(0, math.min(1, pf))
    local fill_w_full = math.floor(bar_w * p + 0.5)
    local fill_w = math.max(1, fill_w_full - 2 * SETTINGS.fill_inset_horizontal)
    local fill_h = bar_h - 2 * SETTINGS.fill_inset_vertical
    local fill_x = bar_x + SETTINGS.fill_inset_horizontal
    local fill_y = bar_y + SETTINGS.fill_inset_vertical

    if fill_h > 0 and fill_w > 0 then
        local fill_radius = math.max(0, SETTINGS.border_radius - math.max(SETTINGS.fill_inset_vertical, SETTINGS.fill_inset_horizontal))
        bb:paintRoundedRect(fill_x, fill_y, fill_w, fill_h, fill_color, fill_radius)
    end
end

local function drawStatusBadge(bb, status, ix, iy, iw, ih, is_last_opened, BD, IconWidget)
    local badge_size = SETTINGS.status_badge_background_size
    local icon_size  = SETTINGS.status_badge_icon_size or badge_size

    local progress_bar_y = round(iy + ih - SETTINGS.margin_bottom - SETTINGS.height)
    local badge_x = round(ix + iw - SETTINGS.margin_right - badge_size)
    local badge_y = round(progress_bar_y + (SETTINGS.height - badge_size) / 2)

    local badge_border_width = 0
    local badge_border_color
    if is_last_opened and SETTINGS.show_status_badges and SETTINGS.last_opened_border_width > 0 then
        badge_border_width = SETTINGS.last_opened_border_width
        badge_border_color = COLOR.last_opened_border
    end

    local bg_x, bg_y, bg_size = badge_x, badge_y, badge_size
    if badge_border_width > 0 then
        bb:paintRoundedRect(badge_x, badge_y, badge_size, badge_size, badge_border_color, math.floor(badge_size / 2))
        bg_size = math.max(1, badge_size - 2 * badge_border_width)
        bg_x = badge_x + badge_border_width
        bg_y = badge_y + badge_border_width
    end

    bb:paintRoundedRect(bg_x, bg_y, bg_size, bg_size, COLOR.badge_bg, math.floor(bg_size / 2))

    local icon_x = bg_x + math.floor((bg_size - icon_size) / 2)
    local icon_y = bg_y + math.floor((bg_size - icon_size) / 2)

    local mark
    if status == "abandoned" then
        mark = IconWidget:new{icon = BD.mirroredUILayout() and "dogear.abandoned.rtl" or "dogear.abandoned", width = icon_size, height = icon_size, alpha = true}
    elseif status == "complete" then
        mark = IconWidget:new{icon = BD.mirroredUILayout() and "dogear.complete.rtl" or "dogear.complete", width = icon_size, height = icon_size, alpha = true}
    elseif status == "on_hold" then
        mark = IconWidget:new{icon = "dogear.reading", width = icon_size, height = icon_size, alpha = true}
    else
        mark = IconWidget:new{icon = "dogear.reading", rotation_angle = BD.mirroredUILayout() and 270 or 0, width = icon_size, height = icon_size, alpha = true}
    end

    if mark then mark:paintTo(bb, icon_x, icon_y) end
end

-- ============================================================================
-- Patch
-- ============================================================================

local function patchCustomProgress(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    
    if not MosaicMenuItem then return end

    local BookInfoManager = require("bookinfomanager")
    local BD          = require("ui/bidi")
    local IconWidget  = require("ui/widget/iconwidget")
    local orig_paintTo = MosaicMenuItem.paintTo
    local orig_update  = MosaicMenuItem.update

    local show_name_grid_folders_pref = BookInfoManager:getSetting("show_name_grid_folders")

    if SETTINGS.style_folder_badges then
        local orig_BIM_getSetting = BookInfoManager.getSetting
        function BookInfoManager:getSetting(key, ...)
            if key == "show_name_grid_folders" then return false end
            return orig_BIM_getSetting(self, key, ...)
        end
    end
    
    function MosaicMenuItem:update(...)
        orig_update(self, ...)
        self.dir_book_count   = nil
        self.dir_folder_count = nil
        self.dir_name         = nil

        if not self.is_directory then return end

        if self.filepath then
            self.dir_name = self.filepath:match("([^/]+)/?$") or self.filepath
        end

        if type(self.mandatory) == "string" then
            local numbers = {}
            for n in self.mandatory:gmatch("(%d+)") do
                numbers[#numbers + 1] = tonumber(n)
            end
            self.dir_book_count   = numbers[1] or 0
            self.dir_folder_count = numbers[2] or 0
        end
    end

    local corner_mark_size = userpatch.getUpValue(orig_paintTo, "corner_mark_size") or Screen:scaleBySize(24)
    if not SETTINGS.status_badge_background_size then SETTINGS.status_badge_background_size = corner_mark_size end
    if not SETTINGS.status_badge_icon_size then SETTINGS.status_badge_icon_size = math.floor(corner_mark_size * 0.75) end

    initColors()

    local last_opened_file
    do
        local ok, settings = pcall(function() return require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua") end)
        if ok and settings then last_opened_file = settings:readSetting("lastfile") end
    end

    local function isLastOpened(filepath) return last_opened_file and filepath == last_opened_file end

    local orig_IconWidget_new = IconWidget.new
    if not SETTINGS.show_status_badges then
        local ImageWidget = require("ui/widget/imagewidget")
        local orig_ImageWidget_paintTo = ImageWidget.paintTo
        ImageWidget.paintTo = function(self, bb, x, y)
            if self.file and (self.file:match("dogear") or self.file:match("resources/trophy") or self.file:match("resources/pause") or self.file:match("resources/new")) then return end
            return orig_ImageWidget_paintTo(self, bb, x, y)
        end
    else
        local corner_prefixes = {"dogear.reading", "dogear.abandoned", "dogear.complete"}
        function IconWidget:new(o)
            if o and o.icon then
                if o.icon == "star.white" then o.alpha = true
                else
                    for _, prefix in ipairs(corner_prefixes) do
                        if o.icon:sub(1, #prefix) == prefix then
                            o.alpha = true
                            break
                        end
                    end
                end
            end
            return orig_IconWidget_new(self, o)
        end
    end

    function MosaicMenuItem:paintTo(bb, x, y)
        if not self.filepath then return orig_paintTo(self, bb, x, y) end
        if BookInfoManager:getSetting("force_no_progressbars") then return orig_paintTo(self, bb, x, y) end

        local saved_percent        = self.percent_finished
        local saved_show_progress  = self.show_progress_bar
        local saved_status         = self.status
        local saved_been_opened    = self.been_opened
        local saved_do_hint_opened = self.do_hint_opened
        local saved_mandatory      = self.mandatory
        local saved_title          = self.title

        self.percent_finished  = nil
        self.show_progress_bar = false
        self.status            = nil
        self.been_opened       = false
        self.do_hint_opened    = false

        orig_paintTo(self, bb, x, y)

        self.percent_finished  = saved_percent
        self.show_progress_bar = saved_show_progress
        self.status            = saved_status
        self.been_opened       = saved_been_opened
        self.do_hint_opened    = saved_do_hint_opened
        self.mandatory         = saved_mandatory
        self.title             = saved_title

        local page_count = getPageCountFromPath(self.filepath)
        local pf = saved_percent

        if (pf == nil) and SETTINGS.bookthickbar and SETTINGS.bookthickbar_unopenedbooks then pf = 0 end
        local skip_bar = (pf == nil)

        local target = self[1] and self[1][1] and self[1][1][1]
        if not target or not target.dimen then return end

        local fx = x + math.floor((self.width - target.dimen.w) / 2)
        local fy = y + math.floor((self.height - target.dimen.h) / 2)
        local fw, fh = target.dimen.w, target.dimen.h

        local b   = target.bordersize or 0
        local pad = target.padding or 0
        local ix  = fx + b + pad
        local iy  = fy + b + pad
        local iw  = fw - 2 * (b + pad)
        local ih  = fh - 2 * (b + pad)

        local status = self.status or "default"
        local is_last_opened = isLastOpened(self.filepath)
        local status_badge_allowed_for_status = isStatusBadgeEnabledFor(self.status)

        -- FIX #1: Status badges render regardless of `been_opened` for specific statuses
        local should_show_badge = SETTINGS.show_status_badges
            and status_badge_allowed_for_status
            and (self.been_opened or self.do_hint_opened or self.status == "complete" or self.status == "abandoned" or self.status == "on_hold")

        -- FIX #2: Progress & badge rendering wrapper updated
        if not self.is_directory then
            local base_left  = ix + SETTINGS.margin_left
            local base_right = ix + iw - SETTINGS.margin_right
            local left       = base_left
            local right      = base_right

            if SETTINGS.page_badge_enabled and page_count then
                local corner = SETTINGS.page_badge_corner
                if corner == "bottom_left" or corner == "bottom_right" then
                    local text = tostring(page_count)
                    local face = safeGetFace(SETTINGS.page_badge_font, SETTINGS.page_badge_text_size)
                    if face then
                        local rt = RenderText:sizeUtf8Text(0, 1000, face, text, false, false)
                        local badge_w = SETTINGS.page_badge_width  or (rt.x + 2 * SETTINGS.page_badge_padding_x)
                        local bx = (corner == "bottom_left") and (ix + SETTINGS.page_badge_x_offset) or (ix + iw - badge_w - SETTINGS.page_badge_x_offset)
                        
                        local combined_radius = (SETTINGS.page_badge_radius or 0) + (SETTINGS.border_radius or 0)
                        if corner == "bottom_left" then
                            local offset = ((bx + badge_w) - ix) - combined_radius
                            if offset < 0 then offset = 0 end
                            left = base_left + offset
                        else
                            local offset = ((ix + iw) - bx) - combined_radius
                            if offset < 0 then offset = 0 end
                            right = base_right - offset
                        end
                    end
                end
            end

            local badge_total_size = SETTINGS.status_badge_background_size
            if should_show_badge then
                if SETTINGS.status_badge_gap then
                    right = base_right - (badge_total_size + SETTINGS.gap_with_status_badge)
                else
                    right = base_right - math.floor(badge_total_size / 2)
                end
            end

            local badge_adjusted_right = right
            
            -- Calculate thickness for standard progress bars
            if SETTINGS.bookthickbar then
                right = left + math.max(1, math.floor(math.max(1, right - left) * computeThicknessFraction(page_count) + 0.5))
            end

            local track_color = COLOR["track_" .. status] or COLOR["track_default"]
            local fill_color  = (is_last_opened and COLOR.fill_last_opened) or COLOR["fill_" .. status] or COLOR["fill_default"]
            local bar_border_width = (is_last_opened and not SETTINGS.show_status_badges) and SETTINGS.last_opened_border_width or SETTINGS.border_width
            local bar_border_color = (is_last_opened and not SETTINGS.show_status_badges) and COLOR.last_opened_border or COLOR.border

            if status == "complete" then
                -- Use badge_adjusted_right so it anchors to the far right, ignoring thickness
                drawCompleteIndicator(bb, left, badge_adjusted_right, iy, ih, bar_border_width, bar_border_color, fill_color)
            elseif not skip_bar then
                drawProgressBar(bb, left, right, iy, ih, bar_border_width, bar_border_color, track_color, fill_color, pf)
            end

            if should_show_badge then
                drawStatusBadge(bb, status, ix, iy, iw, ih, is_last_opened, BD, IconWidget)
            end
        end

        -- Page-number badge
        if SETTINGS.page_badge_enabled and page_count and not self.is_directory then
            local face = safeGetFace(SETTINGS.page_badge_font, SETTINGS.page_badge_text_size)
            if face then
                local text = tostring(page_count)
                local rt = RenderText:sizeUtf8Text(0, 1000, face, text, false, false)
                local badge_w = SETTINGS.page_badge_width or (rt.x + 2 * SETTINGS.page_badge_padding_x)
                local badge_h = SETTINGS.page_badge_height or ((rt.y_top + rt.y_bottom) + 2 * SETTINGS.page_badge_padding_y)

                local corner = SETTINGS.page_badge_corner
                local bx, by
                if corner == "top_left" then bx = ix + SETTINGS.page_badge_x_offset; by = iy + SETTINGS.page_badge_y_offset
                elseif corner == "top_right" then bx = ix + iw - badge_w - SETTINGS.page_badge_x_offset; by = iy + SETTINGS.page_badge_y_offset
                elseif corner == "bottom_left" then bx = ix + SETTINGS.page_badge_x_offset; by = iy + ih - badge_h - SETTINGS.page_badge_y_offset
                else bx = ix + iw - badge_w - SETTINGS.page_badge_x_offset; by = iy + ih - badge_h - SETTINGS.page_badge_y_offset end

                drawTextBadge(bb, text, face, "center", bx, by, badge_w, badge_h, SETTINGS.page_badge_border_width, SETTINGS.page_badge_radius, COLOR.page_badge_border, COLOR.page_badge_bg, COLOR.page_badge_text, SETTINGS.page_badge_padding_x)
            end
        end

        local folder_style_enabled = SETTINGS.style_folder_badges and (show_name_grid_folders_pref ~= false)

        -- Folder name badge
        if self.is_directory and folder_style_enabled and SETTINGS.folder_name_badge_enabled and self.dir_name then
            local face = safeGetFace(SETTINGS.folder_name_badge_font or SETTINGS.page_badge_font, SETTINGS.page_badge_text_size)
            if face then
                local text = self.dir_name
                local rt = RenderText:sizeUtf8Text(0, 1000, face, text, false, false)
                local x_off = SETTINGS.folder_name_badge_x_offset or SETTINGS.page_badge_x_offset or 0
                local badge_w = math.max(10, iw - x_off)
                local badge_h = SETTINGS.page_badge_height or ((rt.y_top + rt.y_bottom) + 2 * SETTINGS.page_badge_padding_y)

                drawTextBadge(bb, text, face, "left", ix + x_off, iy + (SETTINGS.folder_name_badge_y_offset or SETTINGS.page_badge_y_offset or 0), badge_w, badge_h, SETTINGS.page_badge_border_width, SETTINGS.page_badge_radius, COLOR.folder_name_badge_border, COLOR.folder_name_badge_bg, COLOR.folder_name_badge_text, SETTINGS.page_badge_padding_x)
            end
        end

        -- Folder count badge
        if self.is_directory and folder_style_enabled and SETTINGS.folder_badge_enabled and self.dir_book_count then
            local face = safeGetFace(SETTINGS.page_badge_font, SETTINGS.page_badge_text_size)
            if face then
                local badge_text = (self.dir_folder_count and self.dir_folder_count > 0) and string.format("%d[%d]", self.dir_book_count, self.dir_folder_count) or tostring(self.dir_book_count)
                local rt = RenderText:sizeUtf8Text(0, 1000, face, badge_text, false, false)
                local badge_w = SETTINGS.page_badge_width or (rt.x + 2 * SETTINGS.page_badge_padding_x)
                local badge_h = SETTINGS.page_badge_height or ((rt.y_top + rt.y_bottom) + 2 * SETTINGS.page_badge_padding_y)

                drawTextBadge(bb, badge_text, face, "center", ix + (SETTINGS.page_badge_x_offset or 0), iy + ih - badge_h - (SETTINGS.page_badge_y_offset or 0), badge_w, badge_h, SETTINGS.page_badge_border_width, SETTINGS.page_badge_radius, COLOR.page_badge_border, COLOR.page_badge_bg, COLOR.page_badge_text, SETTINGS.page_badge_padding_x)
            end
        end
    end

    logger.info("Custom progress bar styling patch applied")
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCustomProgress)
