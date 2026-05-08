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
local paused = false

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

handlers["emu.message"] = function(p)
  if type(p) ~= "table" or type(p.text) ~= "string" then
    error("emu.message: params.text (string) required")
  end
  emu.message(p.text)
  return true
end

handlers["memory.readbyte"] = function(p)
  if type(p) ~= "table" or type(p.address) ~= "number" then
    error("memory.readbyte: params.address (number) required")
  end
  return memory.readbyte(p.address)
end

handlers["memory.readbyterange"] = function(p)
  if type(p) ~= "table" or type(p.address) ~= "number"
     or type(p.length) ~= "number" then
    error("memory.readbyterange: params.address and params.length required")
  end
  local s = memory.readbyterange(p.address, p.length)
  local out = {}
  for i = 1, #s do out[i] = s:byte(i) end
  return out
end

handlers["memory.writebyte"] = function(p)
  if type(p) ~= "table" or type(p.address) ~= "number"
     or type(p.value) ~= "number" then
    error("memory.writebyte: params.address and params.value required")
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
    error("joypad.set: params.input (table) required")
  end
  local player = p.player or 1
  joypad.set(player, p.input)
  return true
end

----------------------------------------------------------------------
-- JSON request / response
----------------------------------------------------------------------

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

  local ok, result = pcall(handler, req.params)
  if not ok then
    return { id = id, error = { code = "internal_error", message = tostring(result) } }
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

while true do
  pump()
  if paused then
    socket.sleep(0.005)  -- bridge stays responsive while not advancing frames
  else
    emu.frameadvance()
  end
end
