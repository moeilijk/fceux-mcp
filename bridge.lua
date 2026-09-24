-- bridge.lua
-- Loaded into FCEUX via `fceux --loadlua bridge.lua <rom>` (SDL builds) or
-- `fceux.exe -lua C:\\full\\path\\bridge.lua <rom>` (Windows). Listens on a
-- loopback TCP port and dispatches JSON requests to FCEUX's Lua API.
--
-- See docs/ARCHITECTURE.md for the design.

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------

local HOST = "127.0.0.1"
local PORT = tonumber(os.getenv("FCEUX_BRIDGE_PORT")) or 9999

----------------------------------------------------------------------
-- Resolve script directory and vendor paths
----------------------------------------------------------------------

local function script_dir()
  local src = debug.getinfo(1, "S").source
  return (src:match("@(.*[/\\])")) or "./"
end

-- Default path for files we drop in the platform tmp dir. /tmp is universal
-- on macOS/Linux; on Windows we read %TEMP% / %TMP% with a sane fallback.
local function default_tmp_path(name)
  if package.config:sub(1, 1) == "\\" then
    local base = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
    return base .. "\\" .. name
  end
  return "/tmp/" .. name
end

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
-- The Windows driver build (win32, win64) preloads its built-in LuaSocket core;
-- the Qt build (macOS, Linux, and win64-QtSDL on Windows) does not
-- (src/lua-engine.cpp, #if defined(__WIN_DRIVER__)). Read before anything
-- requires it.
local IS_WIN_DRIVER = package.preload["socket.core"] ~= nil

local function detect_platform()
  if IS_WINDOWS then return "windows" end
  local f = io.popen("uname -sm 2>/dev/null")
  if not f then return "macos-arm64" end
  local out = f:read("*a") or ""
  f:close()
  if out:match("Darwin") and out:match("arm64") then return "macos-arm64"
  elseif out:match("Darwin") and out:match("x86_64") then return "macos-x86_64"
  elseif out:match("Linux") and out:match("x86_64") then return "linux-x86_64"
  else return "macos-arm64" end
end

local HERE     = script_dir()
local PLATFORM = detect_platform()
local LSOCK    = HERE .. "vendor/luasocket/" .. PLATFORM
local JSONDIR  = HERE .. "vendor/json"

package.cpath = LSOCK .. "/lib/lua/5.1/?.so;"
             .. LSOCK .. "/lib/lua/5.1/?/core.so;"
             .. package.cpath

package.path  = LSOCK   .. "/share/lua/5.1/?.lua;"
             .. LSOCK   .. "/share/lua/5.1/?/init.lua;"
             .. JSONDIR .. "/?.lua;"
             .. package.path

-- The win32 and win64 builds of FCEUX have LuaSocket 2.0.2's C core built in
-- (package.preload["socket.core"], src/lua-engine.cpp) but not its Lua half
-- (socket.lua), so socket.bind is missing there; it is rebuilt here from the
-- core's own calls. On macOS and Linux the vendored LuaSocket is used.
local socket
if package.preload["socket.core"] then
  socket = require("socket.core")
  socket.bind = socket.bind or function(host, port, backlog)
    local sock, err = socket.tcp()
    if not sock then return nil, err end
    sock:setoption("reuseaddr", true)
    local ok, berr = sock:bind(host, port)
    if not ok then return nil, berr end
    sock:listen(backlog or 32)
    return sock
  end
else
  -- FCEUX's Qt build on Windows (win64-QtSDL) ships no LuaSocket: only the
  -- Windows driver build links it in (luaperks.lib). Every FCEUX build has
  -- Lua compiled into its executable without exporting Lua's C API, so no C
  -- module such as LuaSocket can be added either; the bridge then talks
  -- through files instead (see "File transport" below).
  local ok, mod = pcall(require, "socket")
  socket = ok and mod or nil
end
local json   = require("json")

----------------------------------------------------------------------
-- Dispatch table
----------------------------------------------------------------------

local handlers = {}

-- Throw a structured invalid_params error from a handler. pcall wraps the
-- thrown table as the second return; dispatch() recognizes the shape and
-- surfaces it as { code = "invalid_params", message = ... }.
local function bad_params(msg)
  error({ code = "invalid_params", message = msg })
end

handlers["ping"] = function(_)
  return "pong"
end

handlers["emu.framecount"] = function(_)
  return emu.framecount()
end

-- Pausing. Between requests FCEUX itself is paused (emu.pause), so its window,
-- sound and close keep working, and requests are read from a gui.register
-- callback: FCEUX calls it on every pass of its main loop, paused or not
-- (fceu.cpp FCEUI_Emulate -> FCEU_PutImage -> FCEU_LuaGui, v2.6.6). While
-- paused, FCEUX does not resume the script's main coroutine; a request that
-- runs frames (a "job", see JOBS below) unpauses FCEUX and the main coroutine
-- runs it at the start of the next frame.
--
-- `hold` is what the agent asked for: true (the default) means FCEUX pauses
-- again after every job, so frames only tick on emu.step; emu.unpause
-- switches into continuous (real-time) mode.
local hold = true

handlers["emu.pause"] = function(_)
  hold = true
  emu.pause()
  return true
end

handlers["emu.unpause"] = function(_)
  hold = false
  emu.unpause()
  return true
end

handlers["emu.paused"] = function(_)
  return hold
end

----------------------------------------------------------------------
-- Jobs: requests that run frames. Each has a `check` (in the callback,
-- protected; errors become invalid_params), a `run` (in the main coroutine,
-- unprotected because it yields; it must not error) and a `result` (in the
-- callback after the job's last frame). `run` calls finish() right before its
-- last emu.frameadvance: that pauses FCEUX again when `hold` is set, so a job
-- of N frames runs exactly N frames.
----------------------------------------------------------------------

local JOBS = {}
local job = nil -- { id, method, params, state = "queued" | "running" | "done" }

local function finish()
  if hold then emu.pause() end
  job.state = "done"
end

local BUTTONS = { "A", "B", "select", "start", "up", "down", "left", "right" }

-- emu.step: { frames = n } advances n frames with whatever input is set
-- (joypad.set applies to the next frame only). { steps = [{ buttons, frames,
-- reset }] } plays each step's buttons for its frames: all eight buttons are
-- set on every frame (true when listed, false otherwise), and `reset` gives a
-- soft reset before the step's first frame, as an FM2 movie's reset command.
local function step_plan(p)
  if type(p) == "table" and type(p.steps) == "table" then
    local plan, total = {}, 0
    for i, s in ipairs(p.steps) do
      if type(s) ~= "table" then bad_params("emu.step: steps[" .. i .. "] must be an object") end
      local n = s.frames == nil and 1 or s.frames
      if type(n) ~= "number" or n < 0 then bad_params("emu.step: steps[" .. i .. "].frames must be a number >= 0") end
      local input = {}
      if s.buttons ~= nil and type(s.buttons) ~= "table" then bad_params("emu.step: steps[" .. i .. "].buttons must be an object") end
      for _, b in ipairs(BUTTONS) do input[b] = (s.buttons ~= nil and s.buttons[b] == true) end
      plan[#plan + 1] = { input = input, frames = math.floor(n), reset = s.reset == true }
      total = total + math.floor(n)
    end
    return plan, total
  end
  local n = 1
  if type(p) == "table" and type(p.frames) == "number" then n = math.max(1, math.floor(p.frames)) end
  return { { frames = n } }, n
end

JOBS["emu.step"] = {
  check = function(p)
    local _, total = step_plan(p)
    if total < 1 then bad_params("emu.step: no frames to run") end
  end,
  run = function(p)
    local plan, total = step_plan(p)
    local done = 0
    for _, s in ipairs(plan) do
      for i = 1, s.frames do
        if i == 1 and s.reset then emu.softreset() end
        if s.input then joypad.set(1, s.input) end
        done = done + 1
        if done == total then finish() end
        emu.frameadvance()
      end
    end
  end,
  result = function(_) return emu.framecount() end,
}

handlers["emu.message"] = function(p)
  if type(p) ~= "table" or type(p.text) ~= "string" then
    bad_params("emu.message: params.text (string) required")
  end
  emu.message(p.text)
  return true
end

handlers["memory.readbyte"] = function(p)
  if type(p) ~= "table" or type(p.address) ~= "number" then
    bad_params("memory.readbyte: params.address (number) required")
  end
  return memory.readbyte(p.address)
end

handlers["memory.readbyterange"] = function(p)
  if type(p) ~= "table" or type(p.address) ~= "number"
     or type(p.length) ~= "number" then
    bad_params("memory.readbyterange: params.address and params.length required")
  end
  local s = memory.readbyterange(p.address, p.length)
  local out = {}
  for i = 1, #s do out[i] = s:byte(i) end
  return out
end

handlers["memory.writebyte"] = function(p)
  if type(p) ~= "table" or type(p.address) ~= "number"
     or type(p.value) ~= "number" then
    bad_params("memory.writebyte: params.address and params.value required")
  end
  memory.writebyte(p.address, p.value)
  return true
end

handlers["joypad.get"] = function(p)
  local player = (type(p) == "table" and p.player) or 1
  return joypad.get(player)
end

handlers["joypad.set"] = function(p)
  if type(p) ~= "table" or type(p.input) ~= "table" then
    bad_params("joypad.set: params.input (table) required")
  end
  local player = p.player or 1
  joypad.set(player, p.input)
  return true
end

-- Writes the emulated screen to a PNG via FCEUX's PNG encoder. Returns the
-- absolute path and the framecount of the captured frame.
--
-- gui.savescreenshotas is deferred: FCEUX writes the file at the start of its
-- next FCEU_PutImage (video.cpp), which also runs while paused. So this job
-- runs no frames: `start` (in the callback) asks for the file, and the reply
-- goes out on the callback's next pass, after the file is written.
local function screenshot_path(p)
  if type(p) == "table" and type(p.path) == "string" and #p.path > 0 then return p.path end
  return default_tmp_path("fceux-mcp-cap.png")
end

JOBS["gui.screenshot"] = {
  start = function(p) gui.savescreenshotas(screenshot_path(p)) end,
  result = function(p) return { path = screenshot_path(p), framecount = emu.framecount() } end,
}

-- The emulated screen as RGB, from gui.gdscreenshot(true): FCEUX's own copy
-- of the frame before anything is drawn over it (XBackBuf, lua-engine.cpp), so
-- no message, Lua overlay or "Snapshot Saved." is in it, and FCEUX shows no
-- message for it either. Returns { width, height, rgb } with rgb as base64:
-- each pixel is 3 bytes, so exactly one base64 quartet. Runs no frames.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_12 = {}
for v = 0, 4095 do
  local hi, lo = math.floor(v / 64), v % 64
  B64_12[v] = B64:sub(hi + 1, hi + 1) .. B64:sub(lo + 1, lo + 1)
end

handlers["gui.screen"] = function(_)
  local gd = gui.gdscreenshot(true)
  -- GD truecolor header: 2 bytes signature, 2 bytes width, 2 bytes height, then 5 more; pixels are A,R,G,B.
  local width = gd:byte(3) * 256 + gd:byte(4)
  local height = gd:byte(5) * 256 + gd:byte(6)
  local out = {}
  local byte, floor = string.byte, math.floor
  for p = 0, width * height - 1 do
    local r, g, b = byte(gd, 13 + p * 4, 15 + p * 4)
    local v = r * 65536 + g * 256 + b
    out[p + 1] = B64_12[floor(v / 4096)] .. B64_12[v % 4096]
  end
  return { width = width, height = height, rgb = table.concat(out) }
end

----------------------------------------------------------------------
-- Additional handlers (savestate, loadrom, more memory/gui/rom)
----------------------------------------------------------------------

-- Emulator lifecycle
handlers["emu.poweron"] = function(_)
  emu.poweron()
  return { framecount = emu.framecount() }
end

handlers["emu.softreset"] = function(_)
  emu.softreset()
  return { framecount = emu.framecount() }
end

-- emu.loadrom. In the Windows driver build it is immediate: FCEUX's
-- emu.loadrom calls ALoad, which loads the ROM, powers it on and clears FCEUX's
-- on-screen messages (lua-engine.cpp, fceu.cpp FCEUI_LoadGame), so it runs no
-- frames there. In the Qt build (win64-QtSDL included) the swap is handed to
-- the emulator thread and takes effect on the next frame render
-- (LoadGameFromLua), so the job runs one frame to flush it; side effect: each
-- ROM switch ticks the timeline by one frame there. A file FCEUX cannot open
-- is refused here: the Windows driver build would show a modal error window
-- and then reload its most recent ROM from power-on.
local function loaded_rom() return { filename = rom.getfilename(), framecount = emu.framecount() } end
local function check_rom_path(p)
  if type(p) ~= "table" or type(p.filename) ~= "string" then
    bad_params("emu.loadrom: params.filename (string) required")
  end
  local f = io.open(p.filename, "rb")
  if not f then bad_params("emu.loadrom: cannot open " .. p.filename) end
  f:close()
end

if IS_WIN_DRIVER then
  handlers["emu.loadrom"] = function(p)
    check_rom_path(p)
    emu.loadrom(p.filename)
    return loaded_rom()
  end
  -- The loaded ROM again, from power-on: FCEUX's own ReloadRom (emu.loadrom
  -- without a file name). Unlike emu.poweron, which shows "Power on" over the
  -- game, a load clears FCEUX's messages.
  handlers["emu.reload"] = function(_)
    emu.loadrom()
    return loaded_rom()
  end
else
  -- The Qt build's emu.loadrom needs a file name (no reload without one), and
  -- its Lua does not know the full path of the loaded ROM.
  handlers["emu.reload"] = function(_)
    bad_params("emu.reload: not in FCEUX's Qt build; use emu.loadrom with the ROM's path")
  end
  JOBS["emu.loadrom"] = {
    check = check_rom_path,
    -- The emulator thread takes the load a frame or more later (measured on
    -- win64-QtSDL: the reply after one frame still showed the old frame
    -- count), so the job runs frames until the frame count starts again, at
    -- most 120; from frame 0 or 1 a new start would not show, so it first
    -- runs two.
    run = function(p)
      if emu.framecount() < 2 then emu.frameadvance(); emu.frameadvance() end
      local before = emu.framecount()
      emu.loadrom(p.filename)
      for _ = 1, 120 do
        emu.frameadvance()
        if emu.framecount() < before then break end
      end
      finish()
      emu.frameadvance()
    end,
    result = function(_) return loaded_rom() end,
  }
end

-- Savestates. Slot 1-10 uses FCEUX's persistent slots (saved to disk).
-- Without a slot, save/load operate on a single shared anonymous state
-- kept alive in memory via savestate.persist (otherwise FCEUX deletes
-- anonymous states after the first load).
local anon_state = nil

local function require_slot(p, fn)
  if type(p) ~= "table" or type(p.slot) ~= "number" then
    return nil
  end
  local slot = math.floor(p.slot)
  if slot < 1 or slot > 10 then
    bad_params(fn .. ": slot must be in 1-10 (got " .. tostring(p.slot) .. ")")
  end
  return slot
end

-- Two FCEUX 2.6.6 quirks shape the savestate handlers below:
--   1. savestate.persist crashes the embedded Lua on a state never saved or
--      an unwritable path (it does not check fopen/fwrite), so the slots do
--      not use it; savestate.savefile below does, with both cases ruled out.
--   2. savestate.object(N) returns a fresh handle each call, so a save
--      via one call to object(N) and a load via another call to object(N)
--      operate on different objects — the load sees no state.
-- We therefore cache the savestate object per slot for the script's
-- lifetime, which makes slots 1-10 reusable across many save/load cycles
-- (in-memory; not written to disk without persist). Anonymous saves stay
-- single-use because FCEUX deletes anon state on load.
local slot_objects = {}

handlers["savestate.save"] = function(p)
  local slot = require_slot(p, "savestate.save")
  if slot then
    local s = slot_objects[slot]
    if not s then
      s = savestate.object(slot)
      slot_objects[slot] = s
    end
    savestate.save(s)
    return { slot = slot, framecount = emu.framecount() }
  end
  anon_state = savestate.object()
  savestate.save(anon_state)
  return { framecount = emu.framecount() }
end

handlers["savestate.load"] = function(p)
  local slot = require_slot(p, "savestate.load")
  if slot then
    local s = slot_objects[slot]
    if not s then
      bad_params("savestate.load: slot " .. slot .. " has no saved state "
                 .. "in this session — call savestate.save first")
    end
    savestate.load(s)
    return { slot = slot, framecount = emu.framecount() }
  end
  if not anon_state then
    bad_params("savestate.load: no anonymous savestate available "
               .. "(anon states are single-use; call savestate.save again, "
               .. "or use a numbered slot for repeated rewinds)")
  end
  savestate.load(anon_state)
  anon_state = nil
  return { framecount = emu.framecount() }
end

-- Savestates as files, for a host that keeps a session's state between runs of
-- FCEUX. savestate.object(path) reads the file when it exists; savestate.persist
-- writes the saved state to that path. persist() calls fopen/fwrite without a
-- check (lua-engine.cpp LuaSaveState::persist), so the path is opened for
-- writing here first, and the state is always saved before it is persisted.
local function file_path(p, fn)
  if type(p) ~= "table" or type(p.path) ~= "string" or #p.path == 0 then
    bad_params(fn .. ": params.path (string) required")
  end
  return p.path
end

handlers["savestate.savefile"] = function(p)
  local path = file_path(p, "savestate.savefile")
  local f = io.open(path, "wb")
  if not f then bad_params("savestate.savefile: cannot write " .. path) end
  f:close()
  local s = savestate.object(path)
  savestate.save(s)
  savestate.persist(s)
  return { path = path, framecount = emu.framecount() }
end

handlers["savestate.loadfile"] = function(p)
  local path = file_path(p, "savestate.loadfile")
  local f = io.open(path, "rb")
  if not f then bad_params("savestate.loadfile: no file " .. path) end
  local size = f:seek("end")
  f:close()
  if size == 0 then bad_params("savestate.loadfile: " .. path .. " is empty") end
  savestate.load(savestate.object(path))
  return { path = path, framecount = emu.framecount() }
end

-- Memory: word reads + CPU register access
handlers["memory.readword"] = function(p)
  if type(p) ~= "table" or type(p.address) ~= "number" then
    bad_params("memory.readword: params.address (number) required")
  end
  if type(p.address_high) == "number" then
    return memory.readword(p.address, p.address_high)
  end
  return memory.readword(p.address)
end

local VALID_REGISTERS = { a = true, x = true, y = true, s = true, p = true, pc = true }

handlers["memory.getregister"] = function(p)
  if type(p) ~= "table" or type(p.name) ~= "string" then
    bad_params("memory.getregister: params.name (string) required")
  end
  local name = p.name:lower()
  if not VALID_REGISTERS[name] then
    bad_params("memory.getregister: name must be one of a, x, y, s, p, pc")
  end
  return memory.getregister(name)
end

-- ROM info
handlers["rom.getfilename"] = function(_)
  return rom.getfilename()
end

handlers["rom.gethash"] = function(p)
  local hashtype = "md5"
  if type(p) == "table" and type(p.type) == "string" then
    hashtype = p.type
  end
  if hashtype ~= "md5" and hashtype ~= "base64" then
    bad_params("rom.gethash: type must be 'md5' or 'base64'")
  end
  return rom.gethash(hashtype)
end

-- GUI overlay drawing. These are one-shot per call: FCEUX paints them on
-- the next rendered frame and clears between frames. To make an overlay
-- persist, the agent has to call them every step.
handlers["gui.text"] = function(p)
  if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number"
     or type(p.text) ~= "string" then
    bad_params("gui.text: params x (number), y (number), text (string) required")
  end
  if p.color ~= nil then
    gui.text(p.x, p.y, p.text, p.color)
  else
    gui.text(p.x, p.y, p.text)
  end
  return true
end

handlers["gui.box"] = function(p)
  if type(p) ~= "table" or type(p.x1) ~= "number" or type(p.y1) ~= "number"
     or type(p.x2) ~= "number" or type(p.y2) ~= "number" then
    bad_params("gui.box: params x1, y1, x2, y2 (numbers) required")
  end
  gui.box(p.x1, p.y1, p.x2, p.y2, p.fillcolor, p.outlinecolor)
  return true
end

handlers["gui.pixel"] = function(p)
  if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" then
    bad_params("gui.pixel: params x, y (numbers) required")
  end
  if p.color ~= nil then
    gui.pixel(p.x, p.y, p.color)
  else
    gui.pixel(p.x, p.y)
  end
  return true
end

-- Run arbitrary Lua inside FCEUX. The agent's chunk uses `return EXPR` to
-- send back a value; the value must be JSON-serializable (table / number /
-- string / boolean / nil — no functions or userdata). The full FCEUX Lua
-- API is in scope: emu.*, memory.*, ppu.*, joypad.*, gui.*, etc.
--
-- emu.frameadvance is intentionally shadowed: lua.exec runs inside the
-- dispatcher's pcall, and even an *attempted* yield across pcall corrupts
-- FCEUX's frame-loop state (subsequent emu.frameadvance calls hang). The
-- shadow errors before any yield is attempted, keeping FCEUX healthy.
-- Agents wanting to advance frames should call the typed `emu.step`
-- handler, which runs unprotected and yields safely.
local function make_safe_emu()
  return setmetatable({
    frameadvance = function()
      error("emu.frameadvance cannot be called from lua.exec; "
            .. "use the emu.step handler to advance frames")
    end,
  }, { __index = emu })
end

handlers["lua.exec"] = function(p)
  if type(p) ~= "table" or type(p.code) ~= "string" then
    bad_params("lua.exec: params.code (string) required")
  end
  local fn, perr = loadstring(p.code, "agent_code")
  if not fn then
    bad_params("lua.exec: parse error: " .. tostring(perr))
  end
  -- Sandboxed env: agent sees our shimmed emu table; all other globals
  -- (memory, joypad, gui, etc.) fall through to _G via __index.
  local env = setmetatable({ emu = make_safe_emu() }, { __index = _G })
  setfenv(fn, env)
  return fn()
end

----------------------------------------------------------------------
-- JSON request / response
----------------------------------------------------------------------

-- Methods switched off for this session. FCEUX_BRIDGE_DISABLE is a
-- comma-separated list of method names (e.g. "lua.exec,memory.writebyte"),
-- for a host that hands the bridge to an agent that must not change the game.
local DISABLED = {}
for m in (os.getenv("FCEUX_BRIDGE_DISABLE") or ""):gmatch("[^,%s]+") do DISABLED[m] = true end

-- Asked for by emu.exit; done after its reply has gone out.
local exit_requested = false

handlers["emu.exit"] = function(_)
  exit_requested = true
  return true
end

-- Strip Lua's "<source>:<line>: " prefix from a runtime error message.
local function clean_lua_error(s)
  s = tostring(s)
  return (s:gsub("^[^:]+:%d+:%s*", ""))
end

local function error_response(id, err)
  -- Structured error from bad_params(): { code = ..., message = ... }
  if type(err) == "table" and type(err.code) == "string" then
    return { id = id, error = { code = err.code, message = tostring(err.message or "") } }
  end
  -- Plain Lua runtime error: strip "file:line: " prefix to keep messages clean.
  return { id = id, error = { code = "lua_error", message = clean_lua_error(err) } }
end

-- Returns the response, or nil when the request became a job: its reply goes
-- out when the job is done (see poll).
local function dispatch(req)
  if type(req) ~= "table" then
    return { id = json.null, error = { code = "parse_error", message = "request must be an object" } }
  end

  local id = req.id
  local method = req.method

  if DISABLED[method] then
    return { id = id, error = { code = "method_not_found", message = "'" .. tostring(method) .. "' is disabled (FCEUX_BRIDGE_DISABLE)" } }
  end

  local def = JOBS[method]
  if def then
    local ok, err = pcall(def.check or function() end, req.params)
    if not ok then return error_response(id, err) end
    job = { id = id, method = method, params = req.params, state = "queued" }
    if def.start then
      ok, err = pcall(def.start, req.params)
      if not ok then job = nil; return error_response(id, err) end
      job.state = "done"
    else
      emu.unpause()
    end
    return nil
  end

  local handler = handlers[method]
  if not handler then
    return { id = id, error = { code = "method_not_found", message = "no handler for '" .. tostring(method) .. "'" } }
  end

  local ok, result = pcall(handler, req.params)
  if not ok then return error_response(id, result) end
  return { id = id, result = result }
end

local function handle_line(line)
  local ok, req = pcall(json.decode, line)
  if not ok then
    return { id = json.null, error = { code = "parse_error", message = tostring(req) } }
  end
  return dispatch(req)
end

----------------------------------------------------------------------
-- Transports: TCP (LuaSocket), or files where LuaSocket cannot load
----------------------------------------------------------------------

local server
if socket then
  local err
  server, err = socket.bind(HOST, PORT)
  if not server then
    emu.message("bridge.lua: bind failed: " .. tostring(err))
    error("bridge.lua: bind failed: " .. tostring(err))
  end
  server:settimeout(0)
  local listen_ip, listen_port = server:getsockname()
  emu.message(string.format("bridge.lua listening on %s:%d", listen_ip, listen_port))
  print(string.format("bridge.lua listening on %s:%d", listen_ip, listen_port))
end

-- File transport. The same JSON lines, through files in one folder:
-- FCEUX_BRIDGE_DIR, or "ipc" next to this script. A client claims one of
-- FILE_SLOTS places by creating client-<k> exclusively, with a token of its
-- own inside; it writes requests to <token>-in-<n> and reads replies from
-- <token>-out-<n> (n = 1, 2, ...), each file written under another name and
-- then renamed, so a file that exists is complete. Removing client-<k> closes
-- the client. Checking whether a file exists does not block, so this runs in
-- the same pass of FCEUX's loop as the TCP server.
local FILE_DIR = os.getenv("FCEUX_BRIDGE_DIR") or (HERE .. "ipc")
if FILE_DIR:sub(-1) ~= "/" and FILE_DIR:sub(-1) ~= "\\" then FILE_DIR = FILE_DIR .. (IS_WINDOWS and "\\" or "/") end
local FILE_SLOTS = 8
local FILE_SCAN_PASSES = 30  -- the slots are read every 30 passes (~0.5 s paused)
local file_pass = FILE_SCAN_PASSES
if not socket then
  emu.message("bridge.lua: no LuaSocket here; talking through files in " .. FILE_DIR)
  print("bridge.lua: no LuaSocket here; talking through files in " .. FILE_DIR)
end

local function read_file(name)
  local f = io.open(name, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(name, data)
  local tmp = name .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return os.rename(tmp, name) ~= nil
end

-- Several clients at once, each with its own receive buffer: a host may have
-- more than one process talking to the bridge (one that plays, one that saves
-- states), and each keeps its connection open, so a request is read on the
-- first pass after it arrives. Jobs still run one at a time: while one runs,
-- every client's next request waits in its buffer, and a job's reply goes to
-- the client that asked for it.
local clients = {}   -- list of { sock = ... } or { slot, token, inseq, outseq }, with rxbuf and outbuf

local function close_client(c, reason)
  if reason then print("bridge.lua: client closed (" .. reason .. ")") end
  if c.sock then pcall(function() c.sock:close() end) end
  for i, other in ipairs(clients) do
    if other == c then table.remove(clients, i); break end
  end
end

-- Sends what the socket takes now. The sockets are non-blocking, and a large
-- reply (gui.screen, ~245 KB) does not fit in the send buffer at once: LuaSocket
-- then returns nil, "timeout" and the index of the last byte sent, and the
-- rest goes out on the next passes of FCEUX's loop.
local function flush(c)
  if c.closed or #c.outbuf == 0 then return end
  if c.token then
    if write_file(FILE_DIR .. c.token .. "-out-" .. c.outseq, c.outbuf) then
      c.outseq = c.outseq + 1
      c.outbuf = ""
    end
    return
  end
  local i, err, last = c.sock:send(c.outbuf)
  local sent = i or last or 0
  if sent > 0 then c.outbuf = c.outbuf:sub(sent + 1) end
  if err and err ~= "timeout" then c.closed = true; close_client(c, "send: " .. err) end
end

local function send(c, resp)
  -- Encode in a pcall: a handler may return a non-JSON-serializable value
  -- (e.g. lua.exec returning a userdata or function). Fall back to an
  -- error response in that case rather than failing the poll.
  local ok, encoded = pcall(json.encode, resp)
  if not ok then
    encoded = json.encode({
      id = resp.id,
      error = { code = "lua_error",
                message = "result is not JSON-serializable: " .. tostring(encoded) }
    })
  end
  if not c or c.closed then return end
  c.outbuf = c.outbuf .. encoded .. "\n"
  flush(c)
end

-- Takes one complete line from the client's buffer, or nil.
local function next_line(c)
  local nl = c.rxbuf:find("\n", 1, true)
  if not nl then return nil end
  local line = c.rxbuf:sub(1, nl - 1):gsub("\r$", "")
  c.rxbuf = c.rxbuf:sub(nl + 1)
  return line
end

-- Runs in the gui.register callback, on every pass of FCEUX's main loop.
-- Never blocks: the sockets are non-blocking.
local function poll()
  -- A job that is done replies first. Its last frame (or, for a job without
  -- frames, FCEUX's deferred write) happened before this pass.
  if job and job.state == "done" then
    local def = JOBS[job.method]
    local ok, result = pcall(def.result, job.params)
    send(job.client, ok and { id = job.id, result = result } or error_response(job.id, result))
    job = nil
  end

  -- What did not fit in a send buffer before goes out first.
  for _, c in ipairs(clients) do flush(c) end

  -- Accept every waiting connection.
  while server do
    local s = server:accept()
    if not s then break end
    s:settimeout(0)
    clients[#clients + 1] = { sock = s, rxbuf = "", outbuf = "" }
    print("bridge.lua: client connected")
  end

  -- File clients: a new token in client-<k> is a new client, a missing file a
  -- closed one.
  file_pass = file_pass + 1
  if not socket and file_pass >= FILE_SCAN_PASSES then
    file_pass = 0
    for k = 1, FILE_SLOTS do
      local token = read_file(FILE_DIR .. "client-" .. k)
      token = token and token:match("^%s*(%w+)")
      local known
      for _, c in ipairs(clients) do if c.slot == k and not c.closed then known = c end end
      if known and known.token ~= token then known.closed = true; known = nil end
      if token and not known then
        clients[#clients + 1] = { slot = k, token = token, inseq = 1, outseq = 1, rxbuf = "", outbuf = "" }
        print("bridge.lua: file client " .. k .. " connected")
      end
    end
  end

  -- Drain whatever bytes are available right now (non-blocking).
  for i = #clients, 1, -1 do
    local c = clients[i]
    while c.token and not c.closed do
      local name = FILE_DIR .. c.token .. "-in-" .. c.inseq
      local data = read_file(name)
      if not data then break end
      os.remove(name)
      c.rxbuf = c.rxbuf .. data
      c.inseq = c.inseq + 1
    end
    while c.sock do
      local data, rerr, partial = c.sock:receive(4096)
      local chunk = data or partial
      if chunk and #chunk > 0 then c.rxbuf = c.rxbuf .. chunk end
      if rerr == "closed" then
        -- Requests that arrived before the close are still handled below.
        c.closed = true
        break
      end
      if rerr == "timeout" or not chunk or #chunk < 4096 then break end
    end
  end

  -- Handle complete lines, client by client, until a job starts: while a
  -- job runs, the next requests wait in their buffers.
  for _, c in ipairs(clients) do
    while not job do
      local line = next_line(c)
      if not line then break end
      if #line > 0 then
        local resp = handle_line(line)
        if resp then send(c, resp) elseif job then job.client = c end
        if exit_requested then
          -- emu.exit takes effect when the script next yields (lua-engine.cpp);
          -- unpausing lets the main coroutine run and yield.
          emu.exit()
          emu.unpause()
          return
        end
      end
    end
    if job then break end
  end

  -- Forget clients that closed and have nothing left to handle.
  for i = #clients, 1, -1 do
    local c = clients[i]
    if c.closed and not c.rxbuf:find("\n", 1, true) and not (job and job.client == c) then close_client(c, "eof") end
  end
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------

gui.register(function()
  local ok, perr = pcall(poll)
  if not ok then print("bridge.lua: poll failed: " .. tostring(perr)) end
end)

-- The main coroutine only runs while FCEUX is unpaused: a job, or every
-- frame in continuous mode. A job's run() returns at the start of a frame
-- (its last emu.frameadvance resumed there), and that frame belongs to the
-- next job, so it only yields when no job is queued.
emu.pause()
while true do
  if job and job.state == "queued" then
    job.state = "running"
    JOBS[job.method].run(job.params)
  else
    emu.frameadvance()
  end
end
