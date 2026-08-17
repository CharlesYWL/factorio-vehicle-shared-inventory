local util = require("scripts.util")
local eligibility = require("scripts.eligibility")
local robots = require("scripts.robots")

local transfer = {}

local FULL_WARNING_COOLDOWN = 600

---@param player_index number
---@return table
local ledger_for = function(player_index)
  local ledger = storage.ledger[player_index]
  if not ledger then
    ledger = {}
    storage.ledger[player_index] = ledger
  end
  return ledger
end

---@param player LuaPlayer
local warn_trunk_full = function(player)
  local cache = storage.cache[player.index]
  if not cache then return end
  local tick = game.tick
  if cache.last_full_warning and tick - cache.last_full_warning < FULL_WARNING_COOLDOWN then
    return
  end
  cache.last_full_warning = tick
  player.create_local_flying_text({
    text = { "vsi.trunk-full" },
    create_at_cursor = true,
  })
end

--- Moves missing materials from the character into the vehicle trunk and books
--- every moved item into the ledger so it can be returned later.
---@param player LuaPlayer
---@param trunk LuaInventory
---@param required table
transfer.push = function(player, trunk, required)
  local character_inventory = player.get_main_inventory()
  if not (character_inventory and character_inventory.valid) then return end

  local ledger = ledger_for(player.index)

  for _, entry in pairs(util.sorted_needs(required)) do
    local stack_id = { name = entry.name, quality = entry.quality }
    local available = character_inventory.get_item_count(stack_id)

    if available > 0 then
      local amount = math.min(entry.count, available)
      local inserted = trunk.insert({ name = entry.name, quality = entry.quality, count = amount })

      if inserted > 0 then
        character_inventory.remove({ name = entry.name, quality = entry.quality, count = inserted })
        util.add_item(ledger, entry.name, entry.quality, inserted)
      end

      if inserted < amount then
        warn_trunk_full(player)
      end
    end
  end
end

--- Returns only what this mod lent out, never the vehicle's own stock.
--- Items already consumed by robots simply reduce the returnable amount.
---
--- Robots are a special case: once the roboport equipment absorbs them they are
--- no longer stack items in the trunk, so they must be recalled into the trunk
--- first. Robots that are still flying cannot be recalled and simply stay with
--- the vehicle: nothing is lost, but the return may be partial.
---@param player LuaPlayer
---@param vehicle LuaEntity
transfer.return_borrowed = function(player, vehicle)
  local ledger = storage.ledger[player.index]
  if not ledger then return end

  storage.ledger[player.index] = nil

  if not player.mod_settings["vsi-return-on-exit"].value then return end

  local trunk = eligibility.trunk_of(vehicle)
  if not trunk then return end

  local character_inventory = player.get_main_inventory()
  if not (character_inventory and character_inventory.valid) then return end

  for _, entry in pairs(ledger) do
    local stack_id = { name = entry.name, quality = entry.quality }

    if robots.is_robot_item(entry.name) then
      robots.recall_to_trunk(vehicle, trunk, entry.name, entry.quality, entry.count)
    end

    local returnable = math.min(entry.count, trunk.get_item_count(stack_id))

    if returnable > 0 then
      local moved = character_inventory.insert({
        name = entry.name,
        quality = entry.quality,
        count = returnable,
      })
      if moved > 0 then
        trunk.remove({ name = entry.name, quality = entry.quality, count = moved })
      end
    end
  end
end

--- Drops bookkeeping without moving anything (death, vehicle destroyed).
---@param player_index number
transfer.clear_ledger = function(player_index)
  storage.ledger[player_index] = nil
end

return transfer
