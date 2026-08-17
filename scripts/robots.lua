local util = require("scripts.util")

local robots = {}

--- Item prototype names whose placement result is a construction robot, mapped
--- to the entity name they place. Resolved lazily and cached for the session so
--- modded robots are picked up without hardcoding names. Logistic robots are
--- deliberately excluded: vehicle roboport equipment cannot operate them.
local construction_robot_items = nil
local entity_to_item = nil

---@return table<string, string>
local get_robot_items = function()
  if construction_robot_items then return construction_robot_items end

  construction_robot_items = {}
  entity_to_item = {}
  for name, prototype in pairs(prototypes.item) do
    local result = prototype.place_result
    if result and result.type == "construction-robot" then
      construction_robot_items[name] = result.name
      entity_to_item[result.name] = name
    end
  end
  return construction_robot_items
end

---@return table<string, string>
local get_entity_to_item = function()
  get_robot_items()
  return entity_to_item
end

--- Total robots the vehicle's roboport equipment can hold.
---@param vehicle LuaEntity
---@return number
robots.capacity = function(vehicle)
  local grid = vehicle.grid
  if not grid then return 0 end

  local total = 0
  for _, equipment in pairs(grid.equipment) do
    if equipment.type == "roboport-equipment" and equipment.energy > 0 then
      total = total + (equipment.prototype.logistic_parameters.robot_limit or 0)
    end
  end
  return total
end

--- Robots already available to the vehicle: everything its logistic network owns
--- (docked, flying or charging) plus any still sitting loose in the trunk.
--- Counting the whole network matters because robots that are out building are
--- not docked, and a naive docked-only count would keep topping the vehicle up.
---@param vehicle LuaEntity
---@param trunk LuaInventory
---@return number
robots.present = function(vehicle, trunk)
  local total = 0

  local cell = vehicle.logistic_cell
  if cell and cell.valid then
    local network = cell.logistic_network
    if network and network.valid then
      total = total + network.all_construction_robots
    else
      total = total + cell.stationed_construction_robot_count
    end
  end

  for name in pairs(get_robot_items()) do
    total = total + trunk.get_item_count(name)
  end

  return total
end

--- Robot stacks in the character inventory, best quality first so the vehicle
--- gets the fastest and most durable robots available.
---@param player LuaPlayer
---@return table[] entries of { name = , quality = , count = }
robots.available_in_inventory = function(player)
  local inventory = player.get_main_inventory()
  if not (inventory and inventory.valid) then return {} end

  local found = {}
  local robot_items = get_robot_items()

  for _, item in pairs(inventory.get_contents()) do
    if robot_items[item.name] then
      found[#found + 1] = {
        name = item.name,
        quality = item.quality or "normal",
        count = item.count,
      }
    end
  end

  table.sort(found, function(a, b)
    local a_level = prototypes.quality[a.quality] and prototypes.quality[a.quality].level or 0
    local b_level = prototypes.quality[b.quality] and prototypes.quality[b.quality].level or 0
    if a_level ~= b_level then return a_level > b_level end
    return a.name < b.name
  end)

  return found
end

--- Adds a robot shortfall into the needs table. Only called when there is actual
--- construction work nearby, so idle vehicles never drain the player's robots.
---@param player LuaPlayer
---@param vehicle LuaEntity
---@param trunk LuaInventory
---@param required table
robots.add_needs = function(player, vehicle, trunk, required)
  local capacity = robots.capacity(vehicle)
  if capacity <= 0 then return end

  local shortfall = capacity - robots.present(vehicle, trunk)
  if shortfall <= 0 then return end

  for _, entry in pairs(robots.available_in_inventory(player)) do
    if shortfall <= 0 then break end
    local amount = math.min(shortfall, entry.count)
    util.add_item(required, entry.name, entry.quality, amount, true)
    shortfall = shortfall - amount
  end
end

--- Item keys that represent robots, used to skip the trunk-stock subtraction
--- that applies to build materials.
---@param name string
---@return boolean
robots.is_robot_item = function(name)
  return get_robot_items()[name] ~= nil
end

--- Pulls idle robots out of the vehicle's roboport back into the trunk so the
--- normal return path can move them to the player. Only robots that are docked
--- and doing nothing are taken: ones in flight or carrying cargo are left alone
--- so no in-progress work or held item is destroyed.
---@param vehicle LuaEntity
---@param trunk LuaInventory
---@param name string
---@param quality string
---@param wanted number
robots.recall_to_trunk = function(vehicle, trunk, name, quality, wanted)
  local already = trunk.get_item_count({ name = name, quality = quality })
  local missing = wanted - already
  if missing <= 0 then return end

  local entity_name = get_robot_items()[name]
  if not entity_name then return end

  local cell = vehicle.logistic_cell
  if not (cell and cell.valid) then return end

  local network = cell.logistic_network
  if not (network and network.valid) then return end

  for _, robot in pairs(network.robots or {}) do
    if missing <= 0 then break end

    if robot.valid and robot.name == entity_name then
      local robot_quality = robot.quality and robot.quality.name or "normal"
      local cargo = robot.get_inventory(defines.inventory.robot_cargo)
      local is_idle = robot.robot_order_queue == nil or #robot.robot_order_queue == 0
      local is_empty = cargo == nil or cargo.is_empty()

      if robot_quality == quality and is_idle and is_empty then
        local inserted = trunk.insert({ name = name, quality = quality, count = 1 })
        if inserted > 0 then
          robot.destroy()
          missing = missing - 1
        else
          break
        end
      end
    end
  end
end

return robots
