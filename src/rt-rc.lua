--[[--------------------------------------------------------------------------
  rt-rc.lua —— VLC interface script for VLC RT Marker

  Runs inside VLC (started by: --extraintf luaintf --lua-intf rt-rc).
  Two jobs:
    1. bring up a loopback control server on 127.0.0.1:4212
    2. spawn the hidden key watcher (PowerShell daemon) once the server is up

  Why an own server: VLC 3 loads only ONE extra interface module, and this
  project needs that slot to run code at VLC startup. So we implement the small
  subset of VLC's RC protocol that the daemon needs.

  Commands: get_time  get_length  seek <sec>  status  play_next  add <url>  quit
  Exit: returning from the top level ends the script; VLC keeps running.
--------------------------------------------------------------------------]]

-- Port resolution: %APPDATA%\vlc\rt-marker\port.txt > VLC_RT_PORT env > 4212
local function resolve_port()
    local f = io.open((os.getenv("APPDATA") or "") .. "\\vlc\\rt-marker\\port.txt", "r")
    if f then
        local v = f:read("*l")
        f:close()
        local n = tonumber(v)
        if n then return n end
    end
    return tonumber(os.getenv("VLC_RT_PORT") or "4212")
end

local PORT = resolve_port()
local HOST = "127.0.0.1"
local TEMP = os.getenv("TEMP") or "."
local LOGFILE = TEMP .. "\\rt-rc.log"
local LAUNCHER = (os.getenv("APPDATA") or "") .. "\\vlc\\rt-launch.cmd"

local function log(msg)
    local f = io.open(LOGFILE, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S ") .. tostring(msg) .. "\n")
        f:close()
    end
end

-- ------------------------------------------------------------- daemon spawn --
local function spawn_daemon()
    local f = io.open(LAUNCHER, "r")
    if not f then
        log("spawn skipped: launcher not found -> " .. LAUNCHER)
        return false
    end
    f:close()
    local ok, err = pcall(function() return os.execute('cmd /c "' .. LAUNCHER .. '"') end)
    log("spawn -> ok=" .. tostring(ok) .. " err=" .. tostring(err))
    return ok
end

-- ------------------------------------------------------------ VLC accessors --
local function current_input()
    local ok, i = pcall(vlc.object.input)
    if ok and i then return i end
    return nil
end

local function current_uri()
    local tries = {
        function() local it = vlc.input.item(); return it and it:uri() end,
        function() return vlc.var.get(current_input(), "uri") end,
        function() local it = vlc.input.item(); return it and it:name() end,
    }
    for _, fn in ipairs(tries) do
        local ok, v = pcall(fn)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    return ""
end

-- Position in seconds (float, millisecond resolution).
local function current_seconds()
    local i = current_input()
    if not i then return 0 end
    local ok, us = pcall(function() return vlc.var.get(i, "time") end)
    if ok and type(us) == "number" then return us / 1000000 end
    return 0
end

-- Media length in seconds. vlc.input.length() does not exist in VLC 3 Lua,
-- so we read the input variable (microseconds) and fall back to item duration (seconds).
local function total_seconds()
    local i = current_input()
    if i then
        local ok, us = pcall(function() return vlc.var.get(i, "length") end)
        if ok and type(us) == "number" and us > 0 then
            return math.floor(us / 1000000)
        end
    end
    local ok2, d = pcall(function()
        local it = vlc.input.item()
        return it and it:duration()
    end)
    if ok2 and type(d) == "number" and d > 0 then return d end
    return 0
end

local function seek_to(sec)
    local i = current_input()
    if not i then return false end
    local ok = pcall(function() return vlc.var.set(i, "time", math.floor(sec * 1000000)) end)
    log("seek_to " .. tostring(sec) .. " ok=" .. tostring(ok))
    return ok
end

-- ------------------------------------------------------------ client session --
local last_uri = ""

local function send(c, s)
    pcall(vlc.net.send, c, s)
end

local function emit_input_change(c)
    local uri = current_uri()
    if uri ~= "" and uri ~= last_uri then
        last_uri = uri
        send(c, "status change: ( new input: " .. uri .. " )\n")
        log("input -> " .. uri)
    end
end

local function handle_command(c, line)
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return true end
    log("<< " .. line)

    if line == "get_time" or line == "get_title" then
        emit_input_change(c)
        send(c, string.format("%.3f", current_seconds()) .. "\n")

    elseif line == "get_length" then
        send(c, tostring(total_seconds()) .. "\n")

    elseif line:match("^seek%s+") then
        local sec = tonumber(line:match("^seek%s+([%-%d%.]+)"))
        if sec then
            seek_to(sec)
            send(c, "seek: returned 0 (no error)\n")
        else
            send(c, "seek: bad argument\n")
        end

    elseif line == "status" then
        emit_input_change(c)
        send(c, "status change: ( new input: " .. current_uri() .. " )\n")

    elseif line == "play_next" then
        pcall(function() return vlc.playlist.next() end)
        send(c, "ok\n")

    elseif line:match("^add%s+") then
        local url = line:match("^add%s+(.+)$")
        pcall(function() return vlc.playlist.add({ { path = url } }) end)
        pcall(function() return vlc.playlist.play() end)
        send(c, "ok\n")

    elseif line == "quit" or line == "close" then
        send(c, "Bye\n")
        return false

    else
        send(c, "unknown command\n")
    end
    return true
end

local function serve_client(c)
    log("client connected fd=" .. tostring(c))
    local buf = ""
    while true do
        local pollfds = {}
        pollfds[c] = vlc.net.POLLIN
        local okp, n = pcall(vlc.net.poll, pollfds)
        if not okp or not n or n <= 0 then break end

        local okr, data = pcall(vlc.net.recv, c, 4096)
        if not okr or not data then break end

        buf = buf .. data
        while true do
            local i = buf:find("\n")
            if not i then break end
            local line = buf:sub(1, i - 1)
            buf = buf:sub(i + 1)
            if not handle_command(c, line) then
                pcall(vlc.net.close, c)
                log("client closed by command")
                return
            end
        end
    end
    pcall(vlc.net.close, c)
    log("client disconnected")
end

-- -------------------------------------------------------------------- main --
local function main()
    log("=== rt-rc start (port " .. PORT .. ") ===")

    local ok, listener = pcall(vlc.net.listen_tcp, HOST, PORT)
    if not ok or not listener then
        log("listen FAILED on " .. HOST .. ":" .. PORT .. " -> " .. tostring(listener))
        log("daemon NOT started (port busy?). Change VLC_RT_PORT or free the port.")
        return
    end
    log("listening on " .. HOST .. ":" .. PORT .. " fd=" .. tostring(listener:fds()))

    -- Only spawn the watcher once the control channel is actually available.
    spawn_daemon()

    while true do
        local pollfds = {}
        pollfds[listener:fds()] = vlc.net.POLLIN
        local okp, n = pcall(vlc.net.poll, pollfds)
        if not okp then
            log("poll error, stopping listener")
            break
        end
        if n and n > 0 then
            local okc, client = pcall(function() return listener:accept() end)
            if okc and client then
                serve_client(client)
            else
                log("accept failed ok=" .. tostring(okc) .. " client=" .. tostring(client))
            end
        end
    end
end

local ok, err = xpcall(main, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
if not ok then log("FATAL: " .. tostring(err)) end
log("=== rt-rc exit ===")
