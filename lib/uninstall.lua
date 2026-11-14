-- uninstall.lua: called by modhousekeeper before it deletes the mod.
-- Removes what the installer put in (darkice, curl if it installed them),
-- stops any transmission and deletes the mod's data. Leaves the mod's
-- directory and system.mods to the caller.
return function(on_done)
  local root = _path.code .. "nullcast/lib/"
  local transmit = dofile(root .. "transmit.lua")
  transmit.stop()
  local deps = dofile(root .. "deps.lua")
  local d = deps.new { name = "nullcast", dir = _path.data .. "nullcast/deps" }
  d:remove(nil, { on_done = function(ok)
    if ok then os.execute("rm -rf '" .. _path.data .. "nullcast'") end
    on_done(ok)
  end })
end
