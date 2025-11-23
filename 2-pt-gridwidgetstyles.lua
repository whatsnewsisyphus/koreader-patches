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

    Installation:
    1. Create a 'patches' folder in your KOReader directory if it doesn't exist
    2. Save this file as '2-progress-bar-custom.lua' in the patches folder
    3. Restart KOReader
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
    height        = Screen:scaleBySize(9),
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
    -- If true, bar width is reduced to avoid overlap with the badge.
    -- If false, bar is shortened by badge radius so it ends under the badge.
    status_badge_gap = false,

    -- Per-status badge visibility
    status_badge_show_reading   = false,
    status_badge_show_complete  = true,
    status_badge_show_abandoned = true,
    status_badge_show_on_hold   = true,

    -- Status badge appearance
    status_badge_icon_size       = Screen:scaleBySize(13), -- icon size inside the circle
    status_badge_background_size = Screen:scaleBySize(17), -- circle diameter

    -- Make list view status icons match the dogear badges used in grid view
    match_listviewstatusicons = true,

    -- Complete book indicator. Equal to bar height with a high radius makes it a circle.
    complete_width = Screen:scaleBySize(9),

    -- Track colors (background) by status
    track_color = {
        reading   = "#dadada",
        complete  = "#b0b0b0",
        on_hold   = "#b0b0b0",
        abandoned = "#b0b0b0",
        default   = "#dadada",
    },

    -- Fill colors (progress) by status
    fill_color = {
        reading   = "#555555",
        complete  = "#666666",
        on_hold   = "#888888",
        abandoned = "#888888",
        default   = "#555555",
    },

    -- Border styling for normal books
    border_color = "#606060",

    -- Last opened book highlighting
    -- When show_status_badges = false:
    --   this border is drawn around the PROGRESS BAR for last-opened book.
    -- When show_status_badges = true:
    --   this border is drawn around the BADGE background instead.
    last_opened_border_width = Screen:scaleBySize(0),
    last_opened_border_color = "#555555",

    -- Optional fill color override for last-opened book.
    -- If nil, last-opened books use the same fill_color as their status.
    last_opened_fill_color = "#111111",

    ------------------------------------------------------------------------
    -- Book thickness bar options (width based on page count via P(###))
    ------------------------------------------------------------------------
    bookthickbar               = true,   -- set true to enable page-count-based bar width
    bookthickbar_unopenedbooks = false,  -- show empty bars for unopened books

    -- Page count is parsed from filename without extension via P(###),
    -- e.g. "Some Book P(320).epub" -> 320 pages.

    ------------------------------------------------------------------------
    -- Page-number and Folder Name badge options (uses same P(###) page count)
    ------------------------------------------------------------------------
    page_badge_font        = "source/SourceSans3-Regular.ttf",

    page_badge_enabled = true,

    -- Corner: "top_left", "top_right", "bottom_left", "bottom_right"
    page_badge_corner = "bottom_left",

    -- Offset from that corner (relative to inner cover rect)
    page_badge_x_offset = Screen:scaleBySize(-4),
    page_badge_y_offset = Screen:scaleBySize(4),

    -- Size: if width/height are nil, they'll be computed from text + padding
    page_badge_width  = nil,
    page_badge_height = nil,
    page_badge_radius = Screen:scaleBySize(2),

    -- Border
    page_badge_border_width = Screen:scaleBySize(0),
    page_badge_border_color = "#606060",

    -- Background and text
    page_badge_bg_color   = "#dadada",
    page_badge_text_color = "#333333",
    page_badge_text_size  = Screen:scaleBySize(8),
    page_badge_padding_x  = Screen:scaleBySize(4),
    page_badge_padding_y  = Screen:scaleBySize(4),

    -- Folder badge styling
    --   * suppress Project: Title’s own folder ribbons
    --   * draw the custom folder name + count badges instead
    style_folder_badges = true,

    folder_name_badge_font = "source/SourceSerif4-Regular.ttf",

    -- These control whether we actually draw name + count when style_folder_badges is on
    folder_name_badge_enabled = true,
    folder_badge_enabled      = true,

    -- Folder title badge colors (optional overrides for page badge colors)
    folder_name_badge_bg_color    = "#ffffff",        -- e.g. "#ffffff"
    folder_name_badge_border_color = nil,       -- e.g. "#8080c0"
    folder_name_badge_text_color  = nil,        -- e.g. "#000000"

    -- Folder title badge overrides
    folder_name_badge_x_offset = nil,  -- use page_badge_x_offset by default. use Screen:scaleBySize(#) to set a custom value
    folder_name_badge_y_offset = Screen:scaleBySize(0),  -- use page_badge_y_offset by default

    -- Debug logging
    debug_logging = true,
}

-- ============================================================================
-- COLOR CACHE
-- ============================================================================

local COLOR = nil

local function initColors()
    if COLOR then return end
    COLOR = {}

    -- Track & fill colors
    for key, val in pairs(SETTINGS.track_color) do
        COLOR["track_" .. key] = Blitbuffer.colorFromString(val)
    end
    for key, val in pairs(SETTINGS.fill_color) do
        COLOR["fill_" .. key] = Blitbuffer.colorFromString(val)
    end

    -- Borders
    COLOR.border             = Blitbuffer.colorFromString(SETTINGS.border_color)
    COLOR.last_opened_border = Blitbuffer.colorFromString(SETTINGS.last_opened_border_color)

    -- Last-opened fill override
    if SETTINGS.last_opened_fill_color then
        COLOR.fill_last_opened = Blitbuffer.colorFromString(SETTINGS.last_opened_fill_color)
    end

    -- Badge background (status badges)
    COLOR.badge_bg = Blitbuffer.colorFromString("#f0f0f0")

    -- Page badge colors
    COLOR.page_badge_border = Blitbuffer.colorFromString(SETTINGS.page_badge_border_color)
    COLOR.page_badge_bg     = Blitbuffer.colorFromString(SETTINGS.page_badge_bg_color)
    COLOR.page_badge_text   = Blitbuffer.colorFromString(SETTINGS.page_badge_text_color)

    -- Folder name badge colors (fallback to page badge colors if override is nil)
    COLOR.folder_name_badge_bg = Blitbuffer.colorFromString(
        SETTINGS.folder_name_badge_bg_color or SETTINGS.page_badge_bg_color
    )
    COLOR.folder_name_badge_border = Blitbuffer.colorFromString(
        SETTINGS.folder_name_badge_border_color or SETTINGS.page_badge_border_color
    )
    COLOR.folder_name_badge_text = Blitbuffer.colorFromString(
        SETTINGS.folder_name_badge_text_color or SETTINGS.page_badge_text_color
    )

end

-- ============================================================================
-- Helpers
-- ============================================================================

local function getColor(color_str)
    if SETTINGS.debug_logging then
        logger.info("[ProgressBar] Converting color: " .. tostring(color_str))
    end
    local color = Blitbuffer.colorFromString(color_str)
    if SETTINGS.debug_logging then
        logger.info("[ProgressBar] Color converted successfully")
    end
    return color
end

local function round(v)
    return math.floor(v + 0.5)
end

local function safeGetFace(name, size)
    -- If name is nil, go straight to ffont.
    name = name or "ffont"
    local face = Font:getFace(name, size)
    if not face then
        -- Fall back to ffont if the custom font cannot be loaded.
        logger.warn("[ProgressBar] Could not load font: " .. tostring(name) .. ", falling back to ffont")
        face = Font:getFace("ffont", size)
    end
    return face
end

-- Extract page count from filepath, based on P(###) in filename (no extension)
local function getPageCountFromPath(path)
    if not path then return nil end
    -- Strip directories
    local filename = path:match("([^/]+)$") or path
    -- Strip extension (last .xxx)
    local basename = filename:gsub("%.%w+$", "")
    local num_str = basename:match("P%((%d+)%)")
    if num_str then
        return tonumber(num_str)
    end
    return nil
end

-- Thickness fraction for bookthickbar:
-- <= 100 pages   -> 0.25
-- >= 650 pages   -> 1.0
-- between        -> linear interpolation
-- nil page_count -> 0.66
local function computeThicknessFraction(page_count)
    if not page_count then
        return 0.66
    end
    if page_count <= 100 then
        return 0.25
    end
    if page_count >= 650 then
        return 1.0
    end
    return 0.25 + (page_count - 100) * (1.0 - 0.25) / (650 - 100)
end

local function isStatusBadgeEnabledFor(status)
    if status == "reading" then
        return SETTINGS.status_badge_show_reading
    elseif status == "complete" then
        return SETTINGS.status_badge_show_complete
    elseif status == "abandoned" then
        return SETTINGS.status_badge_show_abandoned
    elseif status == "on_hold" then
        return SETTINGS.status_badge_show_on_hold
    end
    return false
end

-- ============================================================================
-- Patch
-- ============================================================================

local function patchCustomProgress(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    
    if not MosaicMenuItem then
        logger.warn("Could not find MosaicMenuItem")
        return
    end

    -- All BookInfoManager logic must be *inside* this function.
    local BookInfoManager = require("bookinfomanager")
    local BD          = require("ui/bidi")
    local IconWidget  = require("ui/widget/iconwidget")
    local orig_paintTo = MosaicMenuItem.paintTo
    local orig_update  = MosaicMenuItem.update

    ------------------------------------------------------------------------
    -- Folder-style gate: capture real PT setting, override what PT sees
    ------------------------------------------------------------------------
    -- Real user preference from Project:Title
    local show_name_grid_folders_pref = BookInfoManager:getSetting("show_name_grid_folders")

    -- If we want to style folder badges ourselves, make Project:Title think
    -- show_name_grid_folders is always false so it never inserts its frames.
    if SETTINGS.style_folder_badges then
        local orig_BIM_getSetting = BookInfoManager.getSetting

        function BookInfoManager:getSetting(key, ...)
            -- key is the setting name; self is implied because of the ':' syntax
            if key == "show_name_grid_folders" then
                return false
            end
            return orig_BIM_getSetting(self, key, ...)
        end
    end
    
    function MosaicMenuItem:update(...)
        orig_update(self, ...)

        -- Defaults
        self.dir_book_count   = nil
        self.dir_folder_count = nil
        self.dir_name         = nil

        if not self.is_directory then
            return
        end

        -- Folder name from filepath (last segment)
        if self.filepath then
            self.dir_name = self.filepath:match("([^/]+)/?$") or self.filepath
        end

        -- Parse counts out of self.mandatory (e.g. "24 books, 3 folders")
        if type(self.mandatory) == "string" then
            local numbers = {}
            for n in self.mandatory:gmatch("(%d+)") do
                numbers[#numbers + 1] = tonumber(n)
            end
            self.dir_book_count   = numbers[1] or 0
            self.dir_folder_count = numbers[2] or 0
        end
    end

    -- Get corner mark size from the original function
    local corner_mark_size = userpatch.getUpValue(orig_paintTo, "corner_mark_size") or Screen:scaleBySize(24)

    -- Default badge sizes to KOReader's corner mark size if not manually set
    if not SETTINGS.status_badge_background_size then
        SETTINGS.status_badge_background_size = corner_mark_size
    end
    if not SETTINGS.status_badge_icon_size then
        SETTINGS.status_badge_icon_size = math.floor(corner_mark_size * 0.75)
    end

    -- Initialize color cache
    initColors()

    -- Cache last-opened file once
    local last_opened_file
    do
        local ok, settings = pcall(function()
            return require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
        end)
        if ok and settings then
            last_opened_file = settings:readSetting("lastfile")
        end
    end

    local function isLastOpened(filepath)
        return last_opened_file and filepath == last_opened_file
    end

    -- IconWidget override for alpha / suppression
    local orig_IconWidget_new = IconWidget.new

    if not SETTINGS.show_status_badges then
        -- If disabling status badges, block original corner icons
        local ImageWidget = require("ui/widget/imagewidget")
        local orig_ImageWidget_paintTo = ImageWidget.paintTo

        ImageWidget.paintTo = function(self, bb, x, y)
            if self.file and (
                self.file:match("dogear") or
                self.file:match("resources/trophy") or
                self.file:match("resources/pause") or
                self.file:match("resources/new")
            ) then
                return
            end
            return orig_ImageWidget_paintTo(self, bb, x, y)
        end
    else
        -- If showing status badges, ensure IconWidget uses alpha for dogear/icons
        local corner_prefixes = {
            "dogear.reading",
            "dogear.abandoned",
            "dogear.complete",
        }

        function IconWidget:new(o)
            if o and o.icon then
                if o.icon == "star.white" then
                    o.alpha = true
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
        -- Only patch items that have a filepath (books / folders); otherwise
        -- let KOReader handle special items, info messages, etc.
        if not self.filepath then
            return orig_paintTo(self, bb, x, y)
        end

        -- Respect KOReader's "Show progress % instead of progress bars" option
        if BookInfoManager:getSetting("force_no_progressbars") then
            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] force_no_progressbars is enabled, using default rendering")
            end
            return orig_paintTo(self, bb, x, y)
        end

        if SETTINGS.debug_logging then
            logger.info("[ProgressBar] paintTo called for: " .. (self.filepath or "unknown"))
        end

        -- Store original values (including status flags + folder label text)
        local saved_percent        = self.percent_finished
        local saved_show_progress  = self.show_progress_bar
        local saved_status         = self.status
        local saved_been_opened    = self.been_opened
        local saved_do_hint_opened = self.do_hint_opened
        local saved_mandatory      = self.mandatory
        local saved_title          = self.title

        -- Hide progress & status from original renderer (kills ribbon + built-in badges)
        self.percent_finished  = nil
        self.show_progress_bar = false
        self.status            = nil
        self.been_opened       = false
        self.do_hint_opened    = false

        -- Call original painting (no stock progress bar or ribbon; no folder label)
        orig_paintTo(self, bb, x, y)

        -- Restore for custom drawing
        self.percent_finished  = saved_percent
        self.show_progress_bar = saved_show_progress
        self.status            = saved_status
        self.been_opened       = saved_been_opened
        self.do_hint_opened    = saved_do_hint_opened
        self.mandatory         = saved_mandatory
        self.title             = saved_title

        --------------------------------------------------------------------
        -- Decide how we're going to treat progress & page count
        --------------------------------------------------------------------

        -- Page count (for bookthickbar + page badge)
        local page_count = getPageCountFromPath(self.filepath)

        -- Progress fraction
        local pf = saved_percent

        -- If no percent_finished, but we want empty bars for unopened books
        -- when using bookthickbar, treat as pf = 0 instead of skipping bar.
        local treat_as_unopened_for_bar =
            (pf == nil) and
            SETTINGS.bookthickbar and
            SETTINGS.bookthickbar_unopenedbooks

        if treat_as_unopened_for_bar then
            pf = 0
            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] No percent_finished, showing empty bar for unopened book (bookthickbar_unopenedbooks)")
            end
        end

        -- If pf is still nil, we'll skip bar drawing but still allow badges / folder badge / page badge.
        local skip_bar = (pf == nil)

        if SETTINGS.debug_logging and skip_bar then
            logger.info("[ProgressBar] No percent_finished and not using unopened-book bar; skipping bar drawing")
        end

        -- Locate the cover frame (at self[1][1][1])
        local target = self[1] and self[1][1] and self[1][1][1]
        if not target or not target.dimen then
            if SETTINGS.debug_logging then
                logger.warn("[ProgressBar] Could not locate cover target or dimen")
            end
            return
        end

        if SETTINGS.debug_logging then
            logger.info(string.format(
                "[ProgressBar] Cover target found, dimen: %dx%d",
                target.dimen.w, target.dimen.h
            ))
        end

        -- Calculate outer cover position
        local fx = x + math.floor((self.width - target.dimen.w) / 2)
        local fy = y + math.floor((self.height - target.dimen.h) / 2)
        local fw, fh = target.dimen.w, target.dimen.h

        -- Calculate inner content rect (accounting for border and padding)
        local b   = target.bordersize or 0
        local pad = target.padding or 0
        local ix  = fx + b + pad
        local iy  = fy + b + pad
        local iw  = fw - 2 * (b + pad)
        local ih  = fh - 2 * (b + pad)

        if SETTINGS.debug_logging then
            logger.info(string.format(
                "[ProgressBar] Inner rect: x=%d y=%d w=%d h=%d",
                ix, iy, iw, ih
            ))
        end

        --------------------------------------------------------------------
        -- Status, last-opened, and badge logic
        --------------------------------------------------------------------
        local status = self.status or "default"
        if SETTINGS.debug_logging then
            logger.info("[ProgressBar] Book status: " .. tostring(status))
        end

        local is_last_opened = isLastOpened(self.filepath)
        if is_last_opened and SETTINGS.debug_logging then
            logger.info("[ProgressBar] This is the last opened book")
        end

        -- Determine if this status *can* have a badge at all
        local status_badge_allowed_for_status = isStatusBadgeEnabledFor(self.status)

        -- Determine if this book should show a status badge
        local should_show_badge = SETTINGS.show_status_badges
            and status_badge_allowed_for_status
            and (self.been_opened or self.do_hint_opened)

        --------------------------------------------------------------------
        -- Progress bar + status badge (only if not skip_bar)
        --------------------------------------------------------------------
        if not skip_bar and not self.is_directory then
            -- Determine horizontal span for progress bar
            local base_left  = ix + SETTINGS.margin_left
            local base_right = ix + iw - SETTINGS.margin_right
            local left       = base_left
            local right      = base_right

            -- If the page badge is enabled at bottom left/right,
            -- offset the bar horizontally so it "tucks up" against the badge.
            if SETTINGS.page_badge_enabled and page_count then
                local corner = SETTINGS.page_badge_corner
                if corner == "bottom_left" or corner == "bottom_right" then
                    -- Compute the page badge geometry (same logic as in the page badge block).
                    local text      = tostring(page_count)
                    local text_size = SETTINGS.page_badge_text_size
                    local face      = safeGetFace(SETTINGS.page_badge_font, text_size)
                    local rt = RenderText:sizeUtf8Text(
                        0, 1000, face, text, false, false
                    )
                    local text_w = rt.x
                    local text_h = rt.y_top + rt.y_bottom

                    local pad_x   = SETTINGS.page_badge_padding_x
                    local pad_y   = SETTINGS.page_badge_padding_y
                    local badge_w = SETTINGS.page_badge_width  or (text_w + 2 * pad_x)
                    local badge_h = SETTINGS.page_badge_height or (text_h + 2 * pad_y)

                    local x_off = SETTINGS.page_badge_x_offset
                    local y_off = SETTINGS.page_badge_y_offset

                    local bx, by
                    if corner == "bottom_left" then
                        bx = ix + x_off
                        by = iy + ih - badge_h - y_off
                    else -- "bottom_right"
                        bx = ix + iw - badge_w - x_off
                        by = iy + ih - badge_h - y_off
                    end

                    -- How much should we inset the bar so the rounded ends meet?
                    local pb_radius  = SETTINGS.page_badge_radius or 0
                    local bar_radius = SETTINGS.border_radius or 0
                    local combined_radius = pb_radius + bar_radius

                    if corner == "bottom_left" then
                        -- Distance from inner left edge to the badge's right edge
                        local dist_from_inner_left = (bx + badge_w) - ix
                        local offset = dist_from_inner_left - combined_radius
                        if offset < 0 then offset = 0 end
                        left = base_left + offset
                    else -- bottom_right
                        -- Distance from inner right edge to the badge's left edge
                        local inner_right = ix + iw
                        local dist_from_inner_right = inner_right - bx
                        local offset = dist_from_inner_right - combined_radius
                        if offset < 0 then offset = 0 end
                        right = base_right - offset
                    end

                    if SETTINGS.debug_logging then
                        logger.info(string.format(
                            "[ProgressBar] Adjusted bar for page badge (%s): left=%d right=%d",
                            corner, left, right
                        ))
                    end
                end
            end

            local badge_total_size = SETTINGS.status_badge_background_size

            if should_show_badge then
                if SETTINGS.status_badge_gap then
                    -- Dedicated gap to the left of the badge
                    right = base_right - (badge_total_size + SETTINGS.gap_with_status_badge)
                else
                    -- Overlay mode: shorten bar by badge radius so it ends under the badge
                    local badge_radius = math.floor(badge_total_size / 2)
                    right = base_right - badge_radius
                end
                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Right adjusted for badge, new right=" .. right)
                end
            end

            -- Apply bookthickbar (optional page-count-based width)
            if SETTINGS.bookthickbar then
                local full_slot_width = math.max(1, right - left)
                local frac = computeThicknessFraction(page_count)
                local used_width = math.max(1, math.floor(full_slot_width * frac + 0.5))
                right = left + used_width
                if SETTINGS.debug_logging then
                    logger.info(string.format(
                        "[ProgressBar] bookthickbar enabled: pages=%s, frac=%.3f, width=%d",
                        tostring(page_count), frac, used_width
                    ))
                end
            end

            -- Choose track & fill colors
            local track_color = COLOR["track_" .. status] or COLOR["track_default"]
            local fill_color  = COLOR["fill_" .. status]  or COLOR["fill_default"]

            -- Optional override: special fill color for last-opened book
            if is_last_opened and COLOR.fill_last_opened then
                fill_color = COLOR.fill_last_opened
            end

            -- Choose border for the PROGRESS BAR:
            -- Base bar border uses SETTINGS.border_width / border_color.
            -- Last-opened border replaces it only when badges are OFF.
            local bar_border_width = SETTINGS.border_width
            local bar_border_color = COLOR.border

            if is_last_opened and not SETTINGS.show_status_badges then
                bar_border_width = SETTINGS.last_opened_border_width
                bar_border_color = COLOR.last_opened_border
            end

            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Bar border_width=" .. tostring(bar_border_width))
            end

            -- For complete status, draw a short indicator (right-aligned)
            if status == "complete" then
                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Drawing complete indicator")
                end

                local slot_left  = left
                local slot_right = right
                local slot_width = math.max(1, slot_right - slot_left)

                local indicator_h = SETTINGS.height
                local outer_w     = math.min(SETTINGS.complete_width, slot_width)

                -- Inner width (bar body) reduced by total bar border width; height unchanged
                local inner_w = math.max(1, outer_w - 2 * bar_border_width)

                -- Anchor the whole indicator to the right edge of the slot
                local inner_x = round(slot_right - bar_border_width - inner_w)
                local inner_y = round(iy + ih - SETTINGS.margin_bottom - indicator_h)

                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Complete indicator inner: x=" .. inner_x .. " y=" .. inner_y ..
                                " w=" .. inner_w .. " h=" .. indicator_h)
                end

                -- Draw border around the inner bar, expanding outward
                if bar_border_width > 0 then
                    bb:paintRoundedRect(
                        inner_x - bar_border_width,
                        inner_y - bar_border_width,
                        inner_w + 2 * bar_border_width,
                        indicator_h + 2 * bar_border_width,
                        bar_border_color,
                        SETTINGS.border_radius + bar_border_width
                    )
                end

                -- Draw filled indicator
                bb:paintRoundedRect(
                    inner_x,
                    inner_y,
                    inner_w,
                    indicator_h,
                    fill_color,
                    SETTINGS.border_radius
                )

                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Complete indicator drawn successfully")
                end

            else
                -- Draw progress bar for non-complete books
                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Drawing progress bar for status: " .. tostring(status))
                end

                local slot_left  = left
                local slot_right = right
                local slot_width = math.max(1, slot_right - slot_left)

                local bar_h = SETTINGS.height

                -- Inner bar width reduced by total bar border width; height unchanged
                local bar_w = math.max(1, slot_width - 2 * bar_border_width)
                local bar_x = round(slot_left + bar_border_width)
                local bar_y = round(iy + ih - SETTINGS.margin_bottom - bar_h)

                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Bar inner dimensions: x=" .. bar_x .. " y=" .. bar_y ..
                                " w=" .. bar_w .. " h=" .. bar_h)
                end

                -- Draw border expanding around the inner bar
                if bar_border_width > 0 then
                    bb:paintRoundedRect(
                        bar_x - bar_border_width,
                        bar_y - bar_border_width,
                        bar_w + 2 * bar_border_width,
                        bar_h + 2 * bar_border_width,
                        bar_border_color,
                        SETTINGS.border_radius + bar_border_width
                    )
                end

                -- Draw track (background) exactly at the inner bar rect
                bb:paintRoundedRect(
                    bar_x,
                    bar_y,
                    bar_w,
                    bar_h,
                    track_color,
                    SETTINGS.border_radius
                )

                -- Draw fill (progress) with inset inside that rect
                local p = math.max(0, math.min(1, pf))
                local fill_w_full = math.floor(bar_w * p + 0.5)
                local fill_w = math.max(1, fill_w_full - 2 * SETTINGS.fill_inset_horizontal)
                local fill_h = bar_h - 2 * SETTINGS.fill_inset_vertical
                local fill_x = bar_x + SETTINGS.fill_inset_horizontal
                local fill_y = bar_y + SETTINGS.fill_inset_vertical

                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Fill dimensions: x=" .. fill_x .. " y=" .. fill_y ..
                                " w=" .. fill_w .. " h=" .. fill_h .. " progress=" .. p)
                end

                if fill_h > 0 and fill_w > 0 then
                    local fill_radius = math.max(
                        0,
                        SETTINGS.border_radius - math.max(SETTINGS.fill_inset_vertical, SETTINGS.fill_inset_horizontal)
                    )
                    bb:paintRoundedRect(fill_x, fill_y, fill_w, fill_h, fill_color, fill_radius)

                    if SETTINGS.debug_logging then
                        logger.info("[ProgressBar] Fill drawn successfully")
                    end
                else
                    if SETTINGS.debug_logging then
                        logger.warn("[ProgressBar] Fill dimensions invalid after border, skipping fill")
                    end
                end

                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Progress bar drawn successfully")
                end
            end

            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] paintTo (bar) completed for: " .. (self.filepath or "unknown"))
            end

            -- Draw status badge if enabled and appropriate
            if should_show_badge then
                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Drawing status badge for status: " .. (self.status or "unknown"))
                end

                local badge_size = SETTINGS.status_badge_background_size
                local icon_size  = SETTINGS.status_badge_icon_size or badge_size

                -- Position: anchored to inner cover, vertically aligned with progress bar
                local progress_bar_y = round(iy + ih - SETTINGS.margin_bottom - SETTINGS.height)
                local badge_x = round(ix + iw - SETTINGS.margin_right - badge_size)
                local badge_y = round(progress_bar_y + (SETTINGS.height - badge_size) / 2)

                if SETTINGS.debug_logging then
                    logger.info(string.format(
                        "[ProgressBar] Badge position: x=%d y=%d size=%d",
                        badge_x, badge_y, badge_size
                    ))
                end

                -- If this is the last opened book AND badges are enabled,
                -- draw the special border INSIDE the badge box.
                local badge_border_width = 0
                local badge_border_color

                if is_last_opened and SETTINGS.show_status_badges and SETTINGS.last_opened_border_width > 0 then
                    badge_border_width = SETTINGS.last_opened_border_width
                    badge_border_color = COLOR.last_opened_border
                end

                -- We'll potentially shrink the background circle if there's a border,
                -- but the OUTER badge box stays at badge_size x badge_size.
                local bg_x, bg_y, bg_size = badge_x, badge_y, badge_size

                if badge_border_width > 0 then
                    -- Outer circle in border color (fills the whole badge box)
                    bb:paintRoundedRect(
                        badge_x,
                        badge_y,
                        badge_size,
                        badge_size,
                        badge_border_color,
                        math.floor(badge_size / 2)
                    )

                    -- Inner background circle, shrunk uniformly on all sides
                    bg_size = math.max(1, badge_size - 2 * badge_border_width)
                    bg_x = badge_x + badge_border_width
                    bg_y = badge_y + badge_border_width
                end

                -- Background disk for the badge (centered, circular)
                bb:paintRoundedRect(
                    bg_x,
                    bg_y,
                    bg_size,
                    bg_size,
                    COLOR.badge_bg,
                    math.floor(bg_size / 2)
                )

                -- Icon centered inside the background
                local icon_x = bg_x + math.floor((bg_size - icon_size) / 2)
                local icon_y = bg_y + math.floor((bg_size - icon_size) / 2)

                local mark
                if self.status == "abandoned" then
                    mark = IconWidget:new{
                        icon   = BD.mirroredUILayout() and "dogear.abandoned.rtl" or "dogear.abandoned",
                        width  = icon_size,
                        height = icon_size,
                        alpha  = true,
                    }
                elseif self.status == "complete" then
                    mark = IconWidget:new{
                        icon   = BD.mirroredUILayout() and "dogear.complete.rtl" or "dogear.complete",
                        width  = icon_size,
                        height = icon_size,
                        alpha  = true,
                    }
                elseif self.status == "on_hold" then
                    -- Stand-in; swap to a dedicated pause icon if available
                    mark = IconWidget:new{
                        icon   = "dogear.reading",
                        width  = icon_size,
                        height = icon_size,
                        alpha  = true,
                    }
                else -- reading status
                    mark = IconWidget:new{
                        icon           = "dogear.reading",
                        rotation_angle = BD.mirroredUILayout() and 270 or 0,
                        width          = icon_size,
                        height         = icon_size,
                        alpha          = true,
                    }
                end

                if mark then
                    mark:paintTo(bb, icon_x, icon_y)
                    if SETTINGS.debug_logging then
                        logger.info("[ProgressBar] Status badge drawn successfully")
                    end
                end
            end
        end -- not skip_bar & not directory

        --------------------------------------------------------------------
        -- Page-number badge (P(###) in filename) -- only for books
        --------------------------------------------------------------------
        if SETTINGS.page_badge_enabled and page_count and not self.is_directory then
            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Drawing page badge, pages=" .. tostring(page_count))
            end

            local text      = tostring(page_count)
            local text_size = SETTINGS.page_badge_text_size
            local face      = safeGetFace(SETTINGS.page_badge_font, text_size)

            -- Measure text
            local rt = RenderText:sizeUtf8Text(
                0, 1000, face, text, false, false
            )
            local text_w = rt.x
            local text_h = rt.y_top + rt.y_bottom

            local pad_x = SETTINGS.page_badge_padding_x
            local pad_y = SETTINGS.page_badge_padding_y

            local badge_w = SETTINGS.page_badge_width
            local badge_h = SETTINGS.page_badge_height

            if not badge_w then
                badge_w = text_w + 2 * pad_x
            end
            if not badge_h then
                badge_h = text_h + 2 * pad_y
            end

            local radius   = SETTINGS.page_badge_radius
            local border_w = SETTINGS.page_badge_border_width

            -- Position badge in chosen corner relative to inner cover rect
            local bx, by
            local corner = SETTINGS.page_badge_corner

            if corner == "top_left" then
                bx = ix + SETTINGS.page_badge_x_offset
                by = iy + SETTINGS.page_badge_y_offset
            elseif corner == "top_right" then
                bx = ix + iw - badge_w - SETTINGS.page_badge_x_offset
                by = iy + SETTINGS.page_badge_y_offset
            elseif corner == "bottom_left" then
                bx = ix + SETTINGS.page_badge_x_offset
                by = iy + ih - badge_h - SETTINGS.page_badge_y_offset
            else -- "bottom_right" or fallback
                bx = ix + iw - badge_w - SETTINGS.page_badge_x_offset
                by = iy + ih - badge_h - SETTINGS.page_badge_y_offset
            end

            -- Outer border rect
            if border_w > 0 then
                bb:paintRoundedRect(
                    bx,
                    by,
                    badge_w,
                    badge_h,
                    COLOR.page_badge_border,
                    radius
                )
            end

            -- Inner background rect
            local bg_x = bx + border_w
            local bg_y = by + border_w
            local bg_w = badge_w - 2 * border_w
            local bg_h = badge_h - 2 * border_w

            if bg_w > 0 and bg_h > 0 then
                bb:paintRoundedRect(
                    bg_x,
                    bg_y,
                    bg_w,
                    bg_h,
                    COLOR.page_badge_bg,
                    math.max(0, radius - border_w)
                )
            else
                -- If badge is too small, skip shrinking and just use outer rect
                bg_x, bg_y, bg_w, bg_h = bx, by, badge_w, badge_h
            end

            -- Center text in background
            local text_x   = bg_x + math.floor((bg_w - text_w) / 2)
            local center_y = bg_y + bg_h / 2
            local baseline = center_y - (rt.y_bottom - rt.y_top) / 2
            baseline       = round(baseline)

            RenderText:renderUtf8Text(
                bb,
                text_x,
                baseline,
                face,
                text,
                false,
                false,
                COLOR.page_badge_text
            )

            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Page badge drawn")
            end
        end

        --------------------------------------------------------------------
        -- Folder-style gate for custom badges
        -- Only draw custom folder badges if:
        --  * our style is enabled, AND
        --  * Project:Title's "show_name_grid_folders" is enabled
        --------------------------------------------------------------------
        local folder_style_enabled =
            SETTINGS.style_folder_badges and (show_name_grid_folders_pref ~= false)

        --------------------------------------------------------------------
        -- Folder name badge (top-left) styled like page badge, single line
        -- Uses full available width, text clipped at edges. LEFT-aligned.
        --------------------------------------------------------------------
        if self.is_directory
           and folder_style_enabled
           and SETTINGS.folder_name_badge_enabled
           and self.dir_name then
            local text      = self.dir_name
            local text_size = SETTINGS.page_badge_text_size
            local face = safeGetFace(
                SETTINGS.folder_name_badge_font or SETTINGS.page_badge_font,
                text_size
            )

            -- Measure single-line text
            local rt = RenderText:sizeUtf8Text(
                0, 1000, face, text, false, false
            )

            -- Measure single-line text
            local rt = RenderText:sizeUtf8Text(
                0, 1000, face, text, false, false
            )
            local text_w = rt.x
            local text_h = rt.y_top + rt.y_bottom

            local pad_x = SETTINGS.page_badge_padding_x
            local pad_y = SETTINGS.page_badge_padding_y

            -- Offsets: folder-specific if set, otherwise fall back to page badge offsets
            local x_off = SETTINGS.folder_name_badge_x_offset
            if x_off == nil then
                x_off = SETTINGS.page_badge_x_offset or 0
            end

            local y_off = SETTINGS.folder_name_badge_y_offset
            if y_off == nil then
                y_off = SETTINGS.page_badge_y_offset or 0
            end

            -- Badge anchored by left offset but always ending at inner right edge.
            -- left  = ix + x_off
            -- right = ix + iw
            -- width = iw - x_off
            local badge_w = iw - x_off
            if badge_w < 10 then badge_w = 10 end

            local badge_h = SETTINGS.page_badge_height or (text_h + 2 * pad_y)

            local radius   = SETTINGS.page_badge_radius
            local border_w = SETTINGS.page_badge_border_width

            local bx = ix + x_off
            local by = iy + y_off

            -- Outer border rect
            if border_w > 0 then
                bb:paintRoundedRect(
                    bx,
                    by,
                    badge_w,
                    badge_h,
                    COLOR.folder_name_badge_border,
                    radius
                )
            end

            -- Inner background rect
            local bg_x = bx + border_w
            local bg_y = by + border_w
            local bg_w = badge_w - 2 * border_w
            local bg_h = badge_h - 2 * border_w

            if bg_w > 0 and bg_h > 0 then
                bb:paintRoundedRect(
                    bg_x,
                    bg_y,
                    bg_w,
                    bg_h,
                    COLOR.folder_name_badge_bg,
                    math.max(0, radius - border_w)
                )
            else
                bg_x, bg_y, bg_w, bg_h = bx, by, badge_w, badge_h
            end

            -- LEFT-align the text inside the badge, with horizontal padding
            local text_x   = bg_x + pad_x
            local center_y = bg_y + bg_h / 2
            local baseline = center_y - (rt.y_bottom - rt.y_top) / 2
            baseline       = round(baseline)

            RenderText:renderUtf8Text(
                bb,
                text_x,
                baseline,
                face,
                text,
                false,
                false,
                COLOR.folder_name_badge_text
            )

            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Folder name badge drawn (single-line, full width): " .. text)
            end
        end

        --------------------------------------------------------------------
        -- Folder count badge (bottom-left) styled like page badge
        --------------------------------------------------------------------
        if self.is_directory
           and folder_style_enabled
           and SETTINGS.folder_badge_enabled
           and self.dir_book_count then
            local book_count   = self.dir_book_count or 0
            local folder_count = self.dir_folder_count or 0

            -- Text: "24[3]" or "24" if no subfolders
            local badge_text
            if folder_count > 0 then
                badge_text = string.format("%d[%d]", book_count, folder_count)
            else
                badge_text = tostring(book_count)
            end

            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Drawing folder count badge: " .. badge_text)
            end

            local text_size = SETTINGS.page_badge_text_size
            local face      = safeGetFace(SETTINGS.page_badge_font, text_size)

            local rt = RenderText:sizeUtf8Text(
                0, 1000, face, badge_text, false, false
            )
            local text_w = rt.x
            local text_h = rt.y_top + rt.y_bottom

            local pad_x = SETTINGS.page_badge_padding_x
            local pad_y = SETTINGS.page_badge_padding_y

            local badge_w = SETTINGS.page_badge_width  or (text_w + 2 * pad_x)
            local badge_h = SETTINGS.page_badge_height or (text_h + 2 * pad_y)

            local radius   = SETTINGS.page_badge_radius
            local border_w = SETTINGS.page_badge_border_width

            -- Bottom-left inside inner cover rect, using same edge offsets as page badge
            local x_off = SETTINGS.page_badge_x_offset or 0
            local y_off = SETTINGS.page_badge_y_offset or 0
            local bx    = ix + x_off
            local by    = iy + ih - badge_h - y_off

            if border_w > 0 then
                bb:paintRoundedRect(
                    bx,
                    by,
                    badge_w,
                    badge_h,
                    COLOR.page_badge_border,
                    radius
                )
            end

            local bg_x = bx + border_w
            local bg_y = by + border_w
            local bg_w = badge_w - 2 * border_w
            local bg_h = badge_h - 2 * border_w

            if bg_w > 0 and bg_h > 0 then
                bb:paintRoundedRect(
                    bg_x,
                    bg_y,
                    bg_w,
                    bg_h,
                    COLOR.page_badge_bg,
                    math.max(0, radius - border_w)
                )
            else
                bg_x, bg_y, bg_w, bg_h = bx, by, badge_w, badge_h
            end

            local text_x   = bg_x + math.floor((bg_w - text_w) / 2)
            local center_y = bg_y + bg_h / 2
            local baseline = center_y - (rt.y_bottom - rt.y_top) / 2
            baseline       = round(baseline)

            RenderText:renderUtf8Text(
                bb,
                text_x,
                baseline,
                face,
                badge_text,
                false,
                false,
                COLOR.page_badge_text
            )

            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Folder count badge drawn")
            end
        end
    end

    logger.info("Custom progress bar styling patch applied")
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCustomProgress)
