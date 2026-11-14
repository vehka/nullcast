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

-- Every signal on air, ghosts included:
-- cb({ [mount] = { unit = n, listeners = n, looping = bool }, ... })
-- or cb(nil, err). Mounts that aren't safe for a shell are left out.
function Api.signals(cb)
  curl("'" .. Api.BASE .. "/health'", function(out, err)
    if not out then return cb(nil, err) end
    local body = out:match('"signals"%s*:%s*(%b{})')
    if not body then return cb(nil, "unexpected reply") end
    local list = {}
    for mount, obj in body:gmatch('"ice_([^"]+)"%s*:%s*(%b{})') do
      if safe(mount) then
        list[mount] = {
          unit = tonumber(obj:match('"unit"%s*:%s*"?(%d+)')),
          listeners = tonumber(obj:match('"listeners"%s*:%s*(%d+)')) or 0,
          looping = obj:match('"looping"%s*:%s*true') ~= nil,
        }
      end
    end
    cb(list)
  end)
end

-- Opt out of ghost transmission for this mount (fire and forget).
function Api.ghost_optout(mount, cb)
  local body = '{"mount":"/' .. mount .. '","optout":true}'
  curl("-X POST -H 'Content-Type: application/json' -d '" .. body .. "' '"
    .. Api.BASE .. "/admin/ghost-optout'", cb or function() end)
end

return Api
