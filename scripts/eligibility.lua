local util = require("scripts.util")

local eligibility = {}

local TRUNK_BY_TYPE = {
  ["spider-vehicle"] = defines.inventory.spider_trunk,
  ["car"] = defines.inventory.car_trunk,
}

--- Startup setting decides whether cars/tanks participate at all.
---@param vehicle_type string
---@return boolean
local is_type_allowed = function(vehicle_type)
  if vehicle_type == "spider-vehicle" then return true end
  local setting = settings.startup["vsi-vehicle-types"]
  if setting == nil then return true end
  return setting.value == "spider-and-car"
end

--- Largest construction radius among powered roboport equipment in the grid.
--- Returns 0 when the vehicle cannot build.
---@param vehicle LuaEntity
---@return number
eligibility.construction_radius = function(vehicle)
  local grid = vehicle.grid
  if not grid then return 0 end

  local best = 0
  for _, equipment in pairs(grid.equipment) do
    if equipment.type == "roboport-equipment" and equipment.energy > 0 then
      local radius = equipment.prototype.logistic_parameters.construction_radius
      if radius > best then best = radius end
    end
  end
  return best
end

--- Full precondition check. Returns the trunk inventory and build radius when
--- the player/vehicle pair should be serviced this tick.
---@param player LuaPlayer
---@return LuaInventory|nil trunk, number radius, LuaEntity|nil vehicle
eligibility.resolve = function(player)
  if not (player and player.valid) then return nil, 0, nil end
  if not util.setting(player, "vsi-enabled", true) then return nil, 0, nil end

  local character = player.character
  if not (character and character.valid) then return nil, 0, nil end

  local vehicle = player.vehicle
  if not (vehicle and vehicle.valid) then return nil, 0, nil end

  local trunk_index = TRUNK_BY_TYPE[vehicle.type]
  if not trunk_index then return nil, 0, nil end
  if not is_type_allowed(vehicle.type) then return nil, 0, nil end

  local trunk = vehicle.get_inventory(trunk_index)
  if not (trunk and trunk.valid) then return nil, 0, nil end

  local radius = eligibility.construction_radius(vehicle)
  if util.setting(player, "vsi-require-roboport", true) and radius <= 0 then
    return nil, 0, nil
  end
  -- Without a roboport the check is bypassed, but we still need a sane scan
  -- area, so fall back to the vanilla personal roboport radius.
  if radius <= 0 then radius = 15 end

  return trunk, radius, vehicle
end

--- Trunk inventory of an arbitrary vehicle, used by the return-on-exit path
--- where the player is no longer riding it.
---@param vehicle LuaEntity
---@return LuaInventory|nil
eligibility.trunk_of = function(vehicle)
  if not (vehicle and vehicle.valid) then return nil end
  local trunk_index = TRUNK_BY_TYPE[vehicle.type]
  if not trunk_index then return nil end
  local trunk = vehicle.get_inventory(trunk_index)
  if trunk and trunk.valid then return trunk end
  return nil
end

return eligibility
