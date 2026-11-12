-- api.lua: talk to nullband.org with curl, without blocking matron.
--
-- Every call is asynchronous (norns.system_cmd) and ends in exactly one
-- callback: cb(result) on success or cb(nil, err) on failure. A watchdog
-- reports a timeout if curl's output never arrives.

local Api = {}

Api.BASE = "https://nullband.org"
Api.SERVER = "nullband.org"
Api.PORT = 8000
Api.USER = "source"

local TIMEOUT = 20 -- seconds, a bit more than curl's own -m

-- tokens end up in shell commands and in the darkice config: accept only
-- the characters nullband uses (e.g. "nb-j7ctya4n")
local function safe(s)
  return type(s) == "string" and s:match("^[%w%-_]+$") ~= nil
end
Api.safe = safe

local function escape_pattern(s)
  return (s:gsub("%W", "%%%0"))
end

local function curl(args, cb)
  local done = false
  local function finish(out, err)
    if done then return end
    done = true
    cb(out, err)
  end
  clock.run(function()
    clock.sleep(TIMEOUT)
    finish(nil, "timeout")
  end)
  norns.system_cmd("curl -sS -m 15 " .. args .. " 2>&1 || echo CURL_FAILED",
    function(out)
      out = out or ""
      if out:find("CURL_FAILED") then
        finish(nil, (out:gsub("CURL_FAILED", "")):match("curl: %(%d+%) ([^\n]*)")
          or "network error")
      else
        finish(out)
      end
    end)
end

-- One-time credentials, the same ones the iOS flow hands out:
-- cb({ token = "nb-...", mount = "live-nb-..." }) or cb(nil, err)
function Api.request_credentials(cb)
  curl("'" .. Api.BASE .. "/transmit/mobile-credentials'", function(out, err)
    if not out then return cb(nil, err) end
    local token = out:match('"token"%s*:%s*"([^"]+)"')
    local mount = out:match('"mount"%s*:%s*"([^"]+)"')
    if mount then mount = mount:gsub("^/", "") end
    if not mount and token then mount = "live-" .. token end
    if not (safe(token) and safe(mount)) then
      return cb(nil, "unexpected reply")
    end
    cb({ token = token, mount = mount })
  end)
end

-- Is our mount on air? cb({ live = bool, unit = n or nil }) or cb(nil, err)
function Api.health(mount, cb)
  curl("'" .. Api.BASE .. "/health'", function(out, err)
    if not out then return cb(nil, err) end
    if not out:find("{") then return cb(nil, "unexpected reply") end
    local id = escape_pattern('"ice_' .. mount .. '"')
    local live = out:find(id) ~= nil
    local unit
    local obj = out:match(id .. "%s*:%s*(%b{})")
    if obj then unit = tonumber(obj:match('"unit"%s*:%s*"?(%d+)')) end
    cb({ live = live, unit = unit })
  end)
end

-- Opt out of ghost transmission for this mount (fire and forget).
function Api.ghost_optout(mount, cb)
  local body = '{"mount":"/' .. mount .. '","optout":true}'
  curl("-X POST -H 'Content-Type: application/json' -d '" .. body .. "' '"
    .. Api.BASE .. "/admin/ghost-optout'", cb or function() end)
end

return Api
