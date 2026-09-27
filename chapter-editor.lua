--[[
    chapter-editor.lua

    Interactive chapter editing for mpv.

    Keybindings:
      Ctrl+E  - Toggle chapter-editing mode ON/OFF
      Ctrl+M  - (only while mode is ON) Add a new chapter at the current
                position; prompts you to type a name (requires a recent
                mpv build with the mp.input API - falls back to
                auto-naming "Chapter N" on older mpv)
      Ctrl+N  - (only while mode is ON) Delete the chapter currently playing
      Ctrl+S  - Write the current chapter list into the file on disk via
                mkvpropedit.exe (works for .mkv files only). Available
                whether edit mode is on or off.

    IMPORTANT: set MKVPROPEDIT_PATH below to the actual location of
    mkvpropedit.exe on your system before this will work.

    Install: place this file in your mpv scripts directory, e.g.
      Linux/macOS: ~/.config/mpv/scripts/chapter-editor.lua
      Windows:     %APPDATA%\mpv\scripts\chapter-editor.lua
--]]

-- >>> EDIT THIS to point at your mkvpropedit.exe <<<
local MKVPROPEDIT_PATH = "C:/Program Files/MKVToolNix/mkvpropedit.exe"

local utils = require 'mp.utils'
local input_ok, input = pcall(require, 'mp.input')

local edit_mode = false
local legend_timer = nil

local LEGEND = "Chapter editing: ON  (Ctrl+M add | Ctrl+N delete | Ctrl+S save | Ctrl+E close)"

-- Show the persistent legend (no timeout) - only meaningful while edit_mode is on
local function show_legend()
    mp.osd_message(LEGEND, 999999)
end

-- Show a temporary status message; once it expires, restore the legend
-- if edit mode is still on. Used for all one-off feedback (add/delete/save).
local function osd(text, duration)
    duration = duration or 2.5
    mp.osd_message(text, duration)

    if legend_timer then
        legend_timer:kill()
        legend_timer = nil
    end

    if edit_mode then
        legend_timer = mp.add_timeout(duration, function()
            if edit_mode then
                show_legend()
            end
        end)
    end
end

--------------------------------------------------------------------
-- Mode toggle
--------------------------------------------------------------------

local function toggle_edit_mode()
    edit_mode = not edit_mode

    if legend_timer then
        legend_timer:kill()
        legend_timer = nil
    end

    if edit_mode then
        show_legend()
    else
        mp.osd_message("", 0) -- clear the OSD immediately
    end
end

--------------------------------------------------------------------
-- Add chapter (with optional typed name)
--------------------------------------------------------------------

local function finalize_add(time_pos, chapters, title)
    if title == nil or title == "" then
        title = string.format("Chapter %d", #chapters + 1)
    end
    table.insert(chapters, { title = title, time = time_pos })
    table.sort(chapters, function(a, b) return a.time < b.time end)
    mp.set_property_native("chapter-list", chapters)
    osd(string.format("Chapter added: \"%s\" at %s", title, mp.format_time(time_pos)))
end

local function add_chapter()
    if not edit_mode then return end

    local time_pos = mp.get_property_number("time-pos")
    if time_pos == nil then
        osd("Cannot add chapter: no time position available")
        return
    end

    local chapters = mp.get_property_native("chapter-list") or {}

    for _, ch in ipairs(chapters) do
        if math.abs(ch.time - time_pos) < 0.05 then
            osd("Chapter already exists near this position")
            return
        end
    end

    local default_title = string.format("Chapter %d", #chapters + 1)

    if input_ok then
        local submitted = false
        input.get({
            prompt = "New chapter name (Enter=confirm, Esc=cancel): ",
            default_text = default_title,
            submit = function(text)
                submitted = true
                input.terminate()
                finalize_add(time_pos, chapters, text)
            end,
            closed = function()
                if not submitted then
                    osd("Chapter add cancelled")
                end
            end,
        })
    else
        finalize_add(time_pos, chapters, nil)
        osd("Note: this mpv build lacks mp.input - auto-named chapter. Upgrade mpv to type names.")
    end
end

--------------------------------------------------------------------
-- Delete chapter
--------------------------------------------------------------------

local function delete_chapter()
    if not edit_mode then return end

    local chapters = mp.get_property_native("chapter-list") or {}
    if #chapters == 0 then
        osd("No chapters to delete")
        return
    end

    local current = mp.get_property_number("chapter") -- 0-based, -1 if before first chapter
    if current == nil or current < 0 then
        osd("No active chapter at current position")
        return
    end

    local idx = current + 1 -- to 1-based Lua index
    local removed = table.remove(chapters, idx)
    mp.set_property_native("chapter-list", chapters)

    if removed then
        osd(string.format("Chapter deleted: \"%s\" (%s)", removed.title or "untitled", mp.format_time(removed.time)))
    else
        osd("Chapter deleted")
    end
end

--------------------------------------------------------------------
-- Export chapters to disk via mkvpropedit
--------------------------------------------------------------------

local function seconds_to_mkvtime(seconds)
    if seconds < 0 then seconds = 0 end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    local whole_s = math.floor(s)
    local ns = math.floor((s - whole_s) * 1e9 + 0.5)
    return string.format("%02d:%02d:%02d.%09d", h, m, whole_s, ns)
end

local function xml_escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function build_chapters_xml(chapters)
    local parts = {
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        '<!DOCTYPE Chapters SYSTEM "matroskachapters.dtd">\n',
        '<Chapters>\n  <EditionEntry>\n',
    }
    for i, ch in ipairs(chapters) do
        local title = xml_escape(ch.title or ("Chapter " .. i))
        table.insert(parts, string.format(
            '    <ChapterAtom>\n      <ChapterTimeStart>%s</ChapterTimeStart>\n      <ChapterDisplay>\n        <ChapterString>%s</ChapterString>\n        <ChapterLanguage>eng</ChapterLanguage>\n      </ChapterDisplay>\n    </ChapterAtom>\n',
            seconds_to_mkvtime(ch.time), title))
    end
    table.insert(parts, '  </EditionEntry>\n</Chapters>\n')
    return table.concat(parts)
end

local function export_chapters_to_mkv()
    local path = mp.get_property("path")
    if not path then
        osd("No file loaded")
        return
    end

    local abs_path = path
    if not path:match("^%a:[/\\]") and not path:match("^/") then
        local wd = mp.get_property("working-directory")
        abs_path = utils.join_path(wd, path)
    end

    if not abs_path:lower():match("%.mkv$") then
        osd("Export only supported for .mkv files")
        return
    end

    local chapters = mp.get_property_native("chapter-list") or {}
    local xml = build_chapters_xml(chapters)

    local tmp_dir = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
    local tmp_path = utils.join_path(tmp_dir, "mpv_chapters_tmp.xml")

    local f, err = io.open(tmp_path, "w")
    if not f then
        osd("Failed to write temp chapter file: " .. tostring(err))
        return
    end
    f:write(xml)
    f:close()

    osd("Writing chapters via mkvpropedit...")

    local res = mp.command_native({
        name = "subprocess",
        args = { MKVPROPEDIT_PATH, abs_path, "--chapters", tmp_path },
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    })

    if res == nil then
        osd("mkvpropedit call failed to run - check MKVPROPEDIT_PATH")
        return
    end

    if res.status == 0 then
        osd("Chapters saved to file successfully")
    else
        print("mkvpropedit stdout:\n" .. (res.stdout or ""))
        print("mkvpropedit stderr:\n" .. (res.stderr or ""))
        osd(string.format("mkvpropedit failed (exit %s) - see mpv console/log", tostring(res.status)))
    end
end

--------------------------------------------------------------------
-- Keybindings
--------------------------------------------------------------------

mp.add_key_binding("ctrl+e", "chapter_edit_toggle", toggle_edit_mode)
mp.add_key_binding("ctrl+m", "chapter_edit_add", add_chapter)
mp.add_key_binding("ctrl+n", "chapter_edit_delete", delete_chapter)
mp.add_key_binding("ctrl+s", "chapter_edit_export", export_chapters_to_mkv)
