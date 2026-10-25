-- The ways a reader asks for author photos (metadata/author_images does the
-- finding and saving):
--
--   findOne(name, on_done)    -- an author's hold menu. Replaces the
--                                author's photo: the reader asked for it.
--   findAll(names, on_done)   -- the Authors view's hold menu. Every author
--                                with no photo yet, after a confirm that says
--                                how many and where they come from.
--   remove(name, on_done)     -- an author's hold menu, when a photo is set.
--
-- Both lookups wait for Wi-Fi the KOReader way (runWhenOnline asks; nothing
-- connects by itself) and run each author in a forked child, so the UI keeps
-- answering and the progress message's dismiss stops the work.

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")
local icons = require("common/inline_icon_map")
local logger = require("common/zen_logger").new("author_image_actions")

local M = {}

-- Consecutive authors that reached neither source before the bulk pass gives
-- up: a dropped connection should cost a few seconds, not one timeout per
-- author in the library.
M.MAX_UNREACHABLE = 3

local function images()
    return require("modules/filebrowser/metadata/author_images")
end

local function unreachable_text()
    return _("Couldn't reach Open Library or Wikipedia.")
end

local function fail_text(why, name)
    if why == "unreachable" then return unreachable_text() end
    if why == "no storage" then return _("Couldn't create the author images folder.") end
    return T(_("No photo found for %1."), name)
end

local function when_online(fn)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(fn)
    end)
end

local function notify(on_done)
    images().invalidate()
    if type(on_done) == "function" then
        local ok, err = pcall(on_done)
        if not ok then logger.warn("refresh after author image failed:", tostring(err)) end
    end
end

-- lookup(name, trap) -> completed, found, why. One author in a forked child;
-- the child saves the photo itself and answers with one line.
local function lookup(Trapper, name, trap)
    local completed, out = Trapper:dismissableRunInSubprocess(function()
        local path, why = require("modules/filebrowser/metadata/author_images").fetch(name)
        return (path and "found" or "missed") .. "\n" .. tostring(why or "")
    end, trap, true)
    if not completed then return false end
    local what, why = tostring(out or ""):match("^(%a+)\n(.*)$")
    return true, what == "found", why
end

function M.findOne(name, on_done)
    if type(name) ~= "string" or name == "" or images().isPlaceholder(name) then return end
    when_online(function()
        local Trapper = require("ui/trapper")
        local notice = InfoMessage:new{
            text = T(_("Looking for a photo of %1…"), name),
        }
        UIManager:show(notice)
        UIManager:forceRePaint()
        local completed, found, why = lookup(Trapper, name, notice)
        UIManager:close(notice)
        if not completed then return end
        if not found then
            UIManager:show(InfoMessage:new{ text = fail_text(why, name) })
            return
        end
        notify(on_done)
    end)
end

-- holdAwake(on): a pass over a few hundred authors runs for minutes, and the
-- device must not suspend in the middle of one.
local held_prev
local function hold_awake(on)
    local ok_share, PluginShare = pcall(require, "pluginshare")
    if on and held_prev == nil then
        held_prev = (ok_share and PluginShare.pause_auto_suspend) and true or false
        if ok_share then PluginShare.pause_auto_suspend = true end
        pcall(function() UIManager:preventStandby() end)
    elseif not on and held_prev ~= nil then
        if ok_share then PluginShare.pause_auto_suspend = held_prev end
        held_prev = nil
        pcall(function() UIManager:allowStandby() end)
    end
end

local running = false

-- run(names, on_done) -- the bulk pass itself, once confirmed.
function M.run(names, on_done)
    local AuthorImages = images()
    local todo = {}
    for _i, name in ipairs(names or {}) do
        if not AuthorImages.isPlaceholder(name) then todo[#todo + 1] = name end
    end
    if #todo == 0 then return end
    if running then
        UIManager:show(InfoMessage:new{
            text = _("Author images are already being fetched."), timeout = 3 })
        return
    end
    when_online(function()
        local Trapper = require("ui/trapper")
        running = true
        hold_awake(true)
        local found, asked, unreachable_run = 0, 0, 0
        local stopped, offline = false, false
        local notice
        local ok_run, err_run = xpcall(function()
            for index, name in ipairs(todo) do
                local previous = notice
                notice = InfoMessage:new{
                    text = T(_("Finding author images: %1 of %2"), index, #todo)
                        .. "\n" .. name .. "\n\n" .. _("Tap to stop."),
                }
                UIManager:show(notice)
                if previous then UIManager:close(previous) end
                UIManager:forceRePaint()
                local completed, got, why = lookup(Trapper, name, notice)
                if not completed then stopped = true; break end
                asked = asked + 1
                if got then found = found + 1 end
                if why == "unreachable" then
                    unreachable_run = unreachable_run + 1
                    if unreachable_run >= M.MAX_UNREACHABLE then offline = true; break end
                else
                    unreachable_run = 0
                end
                if why == "no storage" then break end
            end
        end, debug.traceback)
        if notice then UIManager:close(notice) end
        hold_awake(false)
        running = false
        if not ok_run then
            logger.warn("author images pass failed:", tostring(err_run))
        end
        if found > 0 then notify(on_done) end
        local text = T(_("Found images for %1 of %2 authors."), found, asked)
        if offline then
            text = text .. "\n\n" .. unreachable_text()
        elseif stopped and asked < #todo then
            text = text .. "\n\n" .. T(_("Stopped before %1 more."), #todo - asked)
        end
        UIManager:show(InfoMessage:new{ text = text })
    end)
end

function M.findAll(names, on_done)
    local todo = images().missing(names)
    if #todo == 0 then
        local any_author = false
        for _i, name in ipairs(names or {}) do
            if not images().isPlaceholder(name) then any_author = true; break end
        end
        UIManager:show(InfoMessage:new{
            text = any_author and _("Every author already has an image.")
                or _("No authors found."),
            timeout = 3,
        })
        return
    end
    local ask = #todo == 1
        and T(_("Look for a photo of %1, the one author with no image yet?"), todo[1])
        or T(_("Look for photos of the %1 authors with no image yet?"), #todo)
    UIManager:show(ConfirmBox:new{
        text = ask .. "\n\n" .. _("Photos come from Open Library, or Wikipedia when it has none. Images you already have are kept."),
        ok_text = _("Find images"),
        ok_callback = function() M.run(todo, on_done) end,
    })
end

function M.remove(name, on_done)
    if images().remove(name) then notify(on_done) end
end

-- holdButtons(name, close_dialog, on_done) -> button rows for an author's
-- hold menu.
function M.holdButtons(name, close_dialog, on_done)
    if type(name) ~= "string" or name == "" or images().isPlaceholder(name) then
        return {}
    end
    local has = images().has(name)
    local rows = {{{
        text = icons.download .. "  " .. (has and _("Replace author image online")
            or _("Find author image online")),
        align = "left",
        callback = function()
            close_dialog()
            M.findOne(name, on_done)
        end,
    }}}
    if has then
        rows[#rows + 1] = {{
            text = icons.delete .. "  " .. _("Remove author image"),
            align = "left",
            callback = function()
                close_dialog()
                M.remove(name, on_done)
            end,
        }}
    end
    return rows
end

return M
