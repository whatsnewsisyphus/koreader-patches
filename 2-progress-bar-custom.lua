--[[
    KOReader User Patch: Custom Progress Bar Styling for Project: Title
    
    This patch allows full customization of the progress bar appearance:
    - Height and border radius
    - Position (left, right, bottom margins)
    - Track background color based on book status
    - Fill color based on book status (reading, abandoned, complete)
    - Border width and color
    - Last opened book highlighting with different border
    - Completed books show as short right-aligned bars
    - Optional status badges
    
    Compatible with Project: Title plugin.
    
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

-- ============================================================================
-- CUSTOM SETTINGS - Edit these to customize your progress bar appearance
-- ============================================================================

local SETTINGS = {
    -- Dimensions
    height = Screen:scaleBySize(9),
    border_radius = Screen:scaleBySize(5),
    border_width = Screen:scaleBySize(0),
    
    -- Fill insets (padding inside the track)
    fill_inset_vertical = Screen:scaleBySize(2),
    fill_inset_horizontal = Screen:scaleBySize(2),
    
    -- Position (distance from inner cover edges)
    margin_left = Screen:scaleBySize(4),
    margin_right = Screen:scaleBySize(4),
    margin_bottom = Screen:scaleBySize(6),
    
    -- Corner icon settings
    show_status_badges = false,
    gap_with_status_badge = Screen:scaleBySize(4),
    status_badge_gap = false,  -- if true, progress bar width shrinks to leave a gap, if false, the end of the progress bar extends under the badge to form a single shape.
    
    -- Status badge appearance
    -- If left nil, these will default to KOReader's corner_mark_size in patchCustomProgress
    status_badge_icon_size = Screen:scaleBySize(13),       -- Size of the icon itself
    status_badge_background_size = Screen:scaleBySize(17), -- Size of the circular background
    
    -- Complete book indicator
    complete_width = Screen:scaleBySize(8),
    
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
    --   these are used as the border around the PROGRESS BAR of last-opened book.
    -- When show_status_badges = true:
    --   these are used as the border around the BADGE background instead.
    last_opened_border_width = Screen:scaleBySize(0),
    last_opened_border_color = "#555555",

    -- Track color override for last opened book (optional)
    -- If nil, last-opened books use the same track_color as their status.
    last_opened_fill_color = "#111111",
    
    -- Debug logging
    debug_logging = false,
}

-- ============================================================================
-- COLOR CACHE
-- ============================================================================

local COLOR = nil

local function initColors()
    if COLOR then return end
    COLOR = {}

    -- Track colors
    for key, val in pairs(SETTINGS.track_color) do
        COLOR["track_" .. key] = Blitbuffer.colorFromString(val)
    end

    -- Fill colors
    for key, val in pairs(SETTINGS.fill_color) do
        COLOR["fill_" .. key] = Blitbuffer.colorFromString(val)
    end

    -- Borders
    COLOR.border = Blitbuffer.colorFromString(SETTINGS.border_color)
    COLOR.last_opened_border = Blitbuffer.colorFromString(SETTINGS.last_opened_border_color)

    -- Last-opened track override (optional)
    if SETTINGS.last_opened_fill_color then
        COLOR.fill_last_opened = Blitbuffer.colorFromString(SETTINGS.last_opened_fill_color)
    end

    -- Badge background (can be changed if desired)
    COLOR.badge_bg = Blitbuffer.colorFromString("#f0f0f0")
end

-- ============================================================================

local function patchCustomProgress(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    
    if not MosaicMenuItem then
        logger.warn("Could not find MosaicMenuItem")
        return
    end
    
    local BookInfoManager = require("bookinfomanager")
    local BD = require("ui/bidi")
    local IconWidget = require("ui/widget/iconwidget")
    local orig_paintTo = MosaicMenuItem.paintTo
    
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

    -- IconWidget override for alpha
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
        -- If showing status badges, ensure IconWidget uses alpha for dogear/icons (name-prefix based)
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
    
    -- Helper to convert color strings (for ad-hoc use)
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
    
    function MosaicMenuItem:paintTo(bb, x, y)
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
        
        -- Store original values (including status flags)
        local saved_percent        = self.percent_finished
        local saved_show_progress  = self.show_progress_bar
        local saved_status         = self.status
        local saved_been_opened    = self.been_opened
        local saved_do_hint_opened = self.do_hint_opened
        
        -- Hide progress & status from original renderer (kills ribbon + built-in badges)
        self.percent_finished  = nil
        self.show_progress_bar = false
        self.status            = nil
        self.been_opened       = false
        self.do_hint_opened    = false
        
        -- Call original painting (no stock progress bar or ribbon)
        orig_paintTo(self, bb, x, y)
        
        -- Restore for custom drawing
        self.percent_finished  = saved_percent
        self.show_progress_bar = saved_show_progress
        self.status            = saved_status
        self.been_opened       = saved_been_opened
        self.do_hint_opened    = saved_do_hint_opened
        
        -- Only proceed if we have a progress value
        local pf = saved_percent
        if not pf then
            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] No percent_finished, skipping custom progress bar")
            end
            return
        end
        
        if SETTINGS.debug_logging then
            logger.info("[ProgressBar] percent_finished: " .. tostring(pf))
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
            logger.info("[ProgressBar] Cover target found, dimen: " .. target.dimen.w .. "x" .. target.dimen.h)
        end
        
        -- Calculate outer cover position
        local fx = x + math.floor((self.width - target.dimen.w) / 2)
        local fy = y + math.floor((self.height - target.dimen.h) / 2)
        local fw, fh = target.dimen.w, target.dimen.h
        
        -- Calculate inner content rect (accounting for border and padding)
        local b = target.bordersize or 0
        local pad = target.padding or 0
        local ix = fx + b + pad
        local iy = fy + b + pad
        local iw = fw - 2 * (b + pad)
        local ih = fh - 2 * (b + pad)
        
        if SETTINGS.debug_logging then
            logger.info("[ProgressBar] Inner rect: x=" .. ix .. " y=" .. iy .. " w=" .. iw .. " h=" .. ih)
        end
        
        -- Determine horizontal span for progress bar
        local left  = ix + SETTINGS.margin_left
        local right = ix + iw - SETTINGS.margin_right
        
        -- Use the background size for spacing calculations
        local badge_total_size = SETTINGS.status_badge_background_size
        
        -- Determine if this book should show a status badge
        local should_show_badge = SETTINGS.show_status_badges and
            (self.been_opened or self.do_hint_opened) and
            (self.status == "reading" or self.status == "complete" or
             self.status == "abandoned" or self.status == "on_hold")
        
        -- Adjust progress bar width if we want a gap for the badge
        if should_show_badge and SETTINGS.status_badge_gap then
            right = right - (badge_total_size + SETTINGS.gap_with_status_badge)
            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Adjusted for status badge gap, new right=" .. right)
            end
        end
        
        -- Get status & last-opened flag
        local status = self.status or "default"
        if SETTINGS.debug_logging then
            logger.info("[ProgressBar] Book status: " .. tostring(status))
        end
        
        local is_last_opened = isLastOpened(self.filepath)
        if is_last_opened and SETTINGS.debug_logging then
            logger.info("[ProgressBar] This is the last opened book")
        end
        
        -- Choose track & fill colors
        local track_color = COLOR["track_" .. status] or COLOR["track_default"]
        local fill_color  = COLOR["fill_" .. status]  or COLOR["fill_default"]

        -- Optional override: special track color for last-opened book
        if is_last_opened and COLOR.fill_last_opened then
            fill_color = COLOR.fill_last_opened
        end

        -- Choose border for the PROGRESS BAR
        -- - Base bar border always uses SETTINGS.border_width / border_color
        -- - Last-opened border (width/color) replaces it only when badges are OFF.
        local bar_border_width = SETTINGS.border_width
        local bar_border_color = COLOR.border

        if is_last_opened and not SETTINGS.show_status_badges then
            bar_border_width = SETTINGS.last_opened_border_width
            bar_border_color = COLOR.last_opened_border
        end
        
        if SETTINGS.debug_logging then
            logger.info("[ProgressBar] Bar border_width=" .. tostring(bar_border_width))
        end
        
        -- For complete status, draw a small square/circle indicator
        if status == "complete" then
            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Drawing complete indicator")
            end

            -- Slot for the complete indicator (horizontally within left/right)
            local slot_left  = left
            local slot_right = right
            local slot_width = math.max(1, slot_right - slot_left)

            local indicator_h = SETTINGS.height
            local outer_w = math.min(SETTINGS.complete_width, slot_width)

            -- Inner width (bar body) reduced by total bar border width; height unchanged
            local inner_w = math.max(1, outer_w - 2 * bar_border_width)

            -- Anchor the whole indicator to the right edge of the slot
            local inner_x = round(slot_right - bar_border_width - inner_w)
            local inner_y = round(iy + ih - SETTINGS.margin_bottom - indicator_h)

            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Complete indicator inner: x=" .. inner_x .. " y=" .. inner_y .. " w=" .. inner_w .. " h=" .. indicator_h)
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

            -- Draw filled indicator (height unchanged)
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

            -- Slot between left/right is the final bar width (including border)
            local slot_left  = left
            local slot_right = right
            local slot_width = math.max(1, slot_right - slot_left)

            local bar_h = SETTINGS.height

            -- Inner bar width reduced by total bar border width; height unchanged
            local bar_w = math.max(1, slot_width - 2 * bar_border_width)
            local bar_x = round(slot_left + bar_border_width)
            local bar_y = round(iy + ih - SETTINGS.margin_bottom - bar_h)

            if SETTINGS.debug_logging then
                logger.info("[ProgressBar] Bar inner dimensions: x=" .. bar_x .. " y=" .. bar_y .. " w=" .. bar_w .. " h=" .. bar_h)
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
                logger.info("[ProgressBar] Fill dimensions: x=" .. fill_x .. " y=" .. fill_y .. " w=" .. fill_w .. " h=" .. fill_h .. " progress=" .. p)
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
                logger.info("[ProgressBar] Badge position: x=" .. badge_x .. " y=" .. badge_y .. " size=" .. badge_size)
            end

            -- If this is the last opened book AND badges are enabled,
            -- draw the special border around the BADGE background instead of the bar.
            local badge_border_width = 0
            local badge_border_color

            if is_last_opened and SETTINGS.show_status_badges and SETTINGS.last_opened_border_width > 0 then
                badge_border_width = SETTINGS.last_opened_border_width
                badge_border_color = COLOR.last_opened_border
            end

            if badge_border_width > 0 then
                bb:paintRoundedRect(
                    badge_x - badge_border_width,
                    badge_y - badge_border_width,
                    badge_size + 2 * badge_border_width,
                    badge_size + 2 * badge_border_width,
                    badge_border_color,
                    math.floor(badge_size / 2) + badge_border_width
                )
            end
            
            -- Background disk for the badge
            bb:paintRoundedRect(
                badge_x,
                badge_y,
                badge_size,
                badge_size,
                COLOR.badge_bg,
                math.floor(badge_size / 2)
            )
            
            -- Icon centered inside the background
            local icon_x = badge_x + math.floor((badge_size - icon_size) / 2)
            local icon_y = badge_y + math.floor((badge_size - icon_size) / 2)
            
            local mark
            if self.status == "abandoned" then
                mark = IconWidget:new{
                    icon = BD.mirroredUILayout() and "dogear.abandoned.rtl" or "dogear.abandoned",
                    width = icon_size,
                    height = icon_size,
                    alpha = true,
                }
            elseif self.status == "complete" then
                mark = IconWidget:new{
                    icon = BD.mirroredUILayout() and "dogear.complete.rtl" or "dogear.complete",
                    width = icon_size,
                    height = icon_size,
                    alpha = true,
                }
            elseif self.status == "on_hold" then
                -- Using reading dogear as a stand-in; swap to a pause icon if available.
                mark = IconWidget:new{
                    icon = "dogear.reading",
                    width = icon_size,
                    height = icon_size,
                    alpha = true,
                }
            else -- reading status
                mark = IconWidget:new{
                    icon = "dogear.reading",
                    rotation_angle = BD.mirroredUILayout() and 270 or 0,
                    width = icon_size,
                    height = icon_size,
                    alpha = true,
                }
            end
            
            if mark then
                mark:paintTo(bb, icon_x, icon_y)
                if SETTINGS.debug_logging then
                    logger.info("[ProgressBar] Status badge drawn successfully")
                end
            end
        end
    end
    
    logger.info("Custom progress bar styling patch applied")
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCustomProgress)