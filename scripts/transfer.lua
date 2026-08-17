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
---@return boolean moved_anything
transfer.push = function(player, trunk, required)
  local character_inventory = player.get_main_inventory()
  if not (character_inventory and character_inventory.valid) then return false end

  local ledger = ledger_for(player.index)
  local moved_anything = false

  for _, entry in pairs(util.sorted_needs(required)) do
    local stack_id = { name = entry.name, quality = entry.quality }
    local available = character_inventory.get_item_count(stack_id)

    if available > 0 then
      local amount = math.min(entry.count, available)
      local inserted = trunk.insert({ name = entry.name, quality = entry.quality, count = amount })

      if inserted > 0 then
        character_inventory.remove({ name = entry.name, quality = entry.quality, count = inserted })
        util.add_item(ledger, entry.name, entry.quality, inserted)
        moved_anything = true
      end

      if inserted < amount then
        warn_trunk_full(player)
      end
    end
  end

  return moved_anything
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

  if not util.setting(player, "vsi-return-on-exit", true) then return end

  local trunk = eligibility.trunk_of(vehicle)
  if not trunk then return end

  local character_inventory = player.get_main_inventory()
  if not (character_inventory and character_inventory.valid) then return end

  for _, entry in pairs(ledger) do
    if robots.is_robot_item(entry.name) then
      robots.recall_to_trunk(vehicle, trunk, entry.name, entry.quality, entry.count)
    end

    local remaining = entry.count

    -- Moved stack by stack so durability, spoilage and nested contents survive.
    for index = 1, #trunk do
      if remaining <= 0 then break end

      local stack = trunk[index]
      if stack.valid_for_read and stack.name == entry.name then
        local quality = stack.quality and stack.quality.name or "normal"
        if quality == entry.quality and stack.count <= remaining then
          local moved = util.move_stack(stack, character_inventory)
          remaining = remaining - moved
        end
      end
    end
  end
end

--- Drops bookkeeping without moving anything (death, vehicle destroyed).
---@param player_index number
transfer.clear_ledger = function(player_index)
  storage.ledger[player_index] = nil
end

--- Snapshot of what the trunk held when the player boarded. Anything at or below
--- this level is the vehicle's own stock and must never be reclaimed; only the
--- surplus above it can be deconstruction spoils.
---@param player_index number
---@param trunk LuaInventory
transfer.capture_baseline = function(player_index, trunk)
  local baseline = {}
  for _, item in pairs(trunk.get_contents()) do
    util.add_item(baseline, item.name, item.quality, item.count)
  end
  storage.baseline[player_index] = baseline
end

---@param player_index number
transfer.clear_baseline = function(player_index)
  storage.baseline[player_index] = nil
end

--- Items that must never be pulled back into the player inventory.
---@param name string
---@param quality string
---@param protected_keys table
---@return boolean
local is_protected = function(name, quality, protected_keys)
  if robots.is_robot_item(name) then return true end
  if protected_keys[util.item_key(name, quality)] then return true end

  local prototype = prototypes.item[name]
  if not prototype then return false end

  return prototype.type == "ammo" or prototype.fuel_value > 0
end

--- How many of an item may be reclaimed: the amount above the boarding baseline,
--- capped by what the player already carries being non-zero.
---@param player_index number
---@param name string
---@param quality string
---@param present number
---@return number
local reclaimable_count = function(player_index, name, quality, present)
  local baseline = storage.baseline[player_index]
  if not baseline then return 0 end

  local reserved = baseline[util.item_key(name, quality)]
  return present - (reserved and reserved.count or 0)
end

--- Moves deconstruction spoils back to the player once the trunk is running out
--- of room, so mining does not stall.
---
--- Three separate guards keep this from stealing: the boarding baseline protects
--- the vehicle's original stock, `protected_keys` covers everything construction
--- still needs, and the loop stops as soon as enough space has been freed.
---@param player LuaPlayer
---@param trunk LuaInventory
---@param protected_keys table item keys that construction still needs
transfer.pull_overflow = function(player, trunk, protected_keys)
  local threshold = util.setting(player, "vsi-overflow-threshold", 20) / 100
  local wanted_free = math.ceil(#trunk * threshold)
  if trunk.count_empty_stacks(true) > wanted_free then return end

  local character_inventory = player.get_main_inventory()
  if not (character_inventory and character_inventory.valid) then return end

  local ledger = storage.ledger[player.index]

  -- Budgets are computed up front because moving stacks mutates the inventory
  -- underneath us, making a live get_item_count unreliable mid-loop.
  local budget = {}
  for _, item in pairs(trunk.get_contents()) do
    local quality = item.quality or "normal"
    local key = util.item_key(item.name, quality)

    if not is_protected(item.name, quality, protected_keys)
      and character_inventory.get_item_count({ name = item.name, quality = quality }) > 0
    then
      local allowed = reclaimable_count(player.index, item.name, quality, item.count)
      if allowed > 0 then budget[key] = allowed end
    end
  end

  if not next(budget) then return end

  for index = 1, #trunk do
    if trunk.count_empty_stacks(true) > wanted_free then break end

    local stack = trunk[index]
    if stack.valid_for_read then
      local quality = stack.quality and stack.quality.name or "normal"
      local key = util.item_key(stack.name, quality)
      local allowed = budget[key]

      -- Whole stacks only. Splitting a stack would mean rebuilding part of it
      -- from name/count, which discards durability, spoilage and other state.
      if allowed and allowed >= stack.count then
        local moved = util.move_stack(stack, character_inventory)
        if moved > 0 then
          budget[key] = allowed - moved
          if ledger then
            util.subtract_item(ledger, key, moved)
          end
        end
      end
    end
  end
end

return transfer
