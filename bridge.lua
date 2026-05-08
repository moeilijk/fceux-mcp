-- bridge.lua
-- Loaded into FCEUX via `fceux --loadlua bridge.lua <rom>`. Listens on a
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
  return (src:match("@(.*/)")) or "./"
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

local function detect_platform()
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

local socket = require("socket")
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

-- Bridge-level pause: setting this flag suppresses emu.frameadvance() in the
-- main loop. We don't call FCEUX's emu.pause() because that would also block
-- frameadvance, which is how we get a tick to drive pump() — the bridge would
-- stop responding. Same observable effect for the agent (no frames advance).
--
-- Default to paused so an LLM agent owns the timeline: frames only tick on
-- emu.step. Call emu.unpause to switch into continuous (real-time) mode.
local paused = true

handlers["emu.pause"] = function(_)
  paused = true
  return true
end

handlers["emu.unpause"] = function(_)
  paused = false
  return true
end

handlers["emu.paused"] = function(_)
  return paused
end

-- Synchronous step: advance N frames inside the handler, then return.
-- Calling emu.frameadvance() from a handler is fine — it just yields to FCEUX
-- for one frame and returns; the response goes out afterwards, so a follow-up
-- memory.readbyte sees post-step state.
handlers["emu.step"] = function(p)
  local n = 1
  if type(p) == "table" and type(p.frames) == "number" then
    n = math.max(1, math.floor(p.frames))
  end
  for _ = 1, n do
    emu.frameadvance()
  end
  return emu.framecount()
end

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
-- gui.savescreenshotas is deferred: FCEUX queues the write to flush during
-- the next frame render. We advance one frame to force that flush so the
-- file exists by the time the response is sent. Side effect: capturing the
-- screen ticks the emulator by 1 frame.
handlers["gui.screenshot"] = function(p)
  local path = default_tmp_path("fceux-mcp-cap.png")
  if type(p) == "table" and type(p.path) == "string" and #p.path > 0 then
    path = p.path
  end
  gui.savescreenshotas(path)
  emu.frameadvance()
  return { path = path, framecount = emu.framecount() }
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

handlers["emu.loadrom"] = function(p)
  if type(p) ~= "table" or type(p.filename) ~= "string" then
    bad_params("emu.loadrom: params.filename (string) required")
  end
  emu.loadrom(p.filename)
  -- FCEUX silently falls back to the most-recent ROM if the path can't
  -- be loaded, so report what's actually loaded now.
  return { filename = rom.getfilename(), framecount = emu.framecount() }
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
--   1. savestate.persist crashes the embedded Lua, so we can't make a
--      single state survive across multiple loads via that route.
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

----------------------------------------------------------------------
-- JSON request / response
----------------------------------------------------------------------

-- Methods whose handlers internally call emu.frameadvance (which yields).
-- Lua 5.1 cannot yield across a pcall boundary, so these run unprotected.
-- Their handlers must be written so they never error in practice.
local YIELDING_METHODS = { ["emu.step"] = true, ["gui.screenshot"] = true }

-- Strip Lua's "<source>:<line>: " prefix from a runtime error message.
local function clean_lua_error(s)
  s = tostring(s)
  return (s:gsub("^[^:]+:%d+:%s*", ""))
end

local function dispatch(req)
  if type(req) ~= "table" then
    return { id = json.null, error = { code = "parse_error", message = "request must be an object" } }
  end

  local id = req.id
  local method = req.method
  local handler = handlers[method]

  if not handler then
    return { id = id, error = { code = "method_not_found", message = "no handler for '" .. tostring(method) .. "'" } }
  end

  if YIELDING_METHODS[method] then
    return { id = id, result = handler(req.params) }
  end

  local ok, result = pcall(handler, req.params)
  if not ok then
    -- Structured error from bad_params(): { code = ..., message = ... }
    if type(result) == "table" and type(result.code) == "string" then
      return { id = id, error = { code = result.code, message = tostring(result.message or "") } }
    end
    -- Plain Lua runtime error: strip "file:line: " prefix to keep messages clean.
    return { id = id, error = { code = "lua_error", message = clean_lua_error(result) } }
  end
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
-- TCP server
----------------------------------------------------------------------

local server, err = socket.bind(HOST, PORT)
if not server then
  emu.message("bridge.lua: bind failed: " .. tostring(err))
  error("bridge.lua: bind failed: " .. tostring(err))
end
server:settimeout(0)
local listen_ip, listen_port = server:getsockname()
emu.message(string.format("bridge.lua listening on %s:%d", listen_ip, listen_port))
print(string.format("bridge.lua listening on %s:%d", listen_ip, listen_port))

-- One client at a time for v1.
local client = nil
local rxbuf  = ""

local function close_client(reason)
  if client then
    if reason then print("bridge.lua: client closed (" .. reason .. ")") end
    pcall(function() client:close() end)
    client = nil
    rxbuf  = ""
  end
end

local function pump()
  -- Accept new connection if we don't already have one.
  if not client then
    local c = server:accept()
    if c then
      c:settimeout(0)
      client = c
      rxbuf  = ""
      print("bridge.lua: client connected")
    end
  end

  if not client then return end

  -- Drain whatever bytes are available right now (non-blocking).
  while true do
    local data, rerr, partial = client:receive(4096)
    local chunk = data or partial
    if chunk and #chunk > 0 then rxbuf = rxbuf .. chunk end
    if rerr == "closed" then close_client("eof"); return end
    if rerr == "timeout" or not chunk or #chunk < 4096 then break end
  end

  -- Process complete lines.
  while true do
    local nl = rxbuf:find("\n", 1, true)
    if not nl then break end
    local line = rxbuf:sub(1, nl - 1):gsub("\r$", "")
    rxbuf = rxbuf:sub(nl + 1)
    if #line > 0 then
      local resp = handle_line(line)
      local encoded = json.encode(resp) .. "\n"
      local _, serr = client:send(encoded)
      if serr then close_client("send: " .. serr); return end
    end
  end
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------

-- Prime: the first emu.frameadvance after a script loads acts as a yield-only
-- warm-up under FCEUX 2.6.6 (it does not bump emu.framecount), so do it once
-- here before any agent-driven step would otherwise see an off-by-one.
emu.frameadvance()

while true do
  pump()
  if paused then
    socket.sleep(0.005)  -- bridge stays responsive while not advancing frames
  else
    emu.frameadvance()
  end
end
