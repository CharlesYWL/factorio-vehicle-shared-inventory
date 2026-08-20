local util = require("scripts.util")
local eligibility = require("scripts.eligibility")
local robots = require("scripts.robots")

local transfer = {}

local FULL_WARNING_COOLDOWN = 600

--- Item map of the player's ledger, creating an empty one bound to this vehicle.
---@param player_index number
---@param unit_number number|nil
---@return table
local ledger_items_for = function(player_index, unit_number)
  local ledger = storage.ledger[player_index]
  if not ledger or not ledger.items then
    ledger = { vehicle = unit_number, items = {} }
    storage.ledger[player_index] = ledger
  elseif unit_number and ledger.vehicle ~= unit_number then
    -- Swap should have settled first. A fresh ledger avoids paying the old
    -- vehicle's debt out of this trunk.
    ledger = { vehicle = unit_number, items = {} }
    storage.ledger[player_index] = ledger
  end
  return ledger.items
end

---@param player_index number
---@return table|nil
local ledger_items = function(player_index)
  local ledger = storage.ledger[player_index]
  return ledger and ledger.items or nil
end

--- Amount that must stay in the trunk for this item: the vehicle's boarding
--- stock plus every other occupant's still-open debt. The player being settled
--- is excluded so their own ledger is never counted as protection against them.
---@param player_index number
---@param unit_number number|nil
---@param name string
---@param quality string
---@return number
local protected_amount = function(player_index, unit_number, name, quality)
  if not unit_number then return 0 end
  local veh = storage.vehicles[unit_number]
  if not veh then return 0 end

  local key = util.item_key(name, quality)
  local reserved = 0
  local baseline = veh.baseline and veh.baseline[key]
  if baseline then reserved = baseline.count end

  if veh.occupants then
    for other_index in pairs(veh.occupants) do
      if other_index ~= player_index then
        local items = ledger_items(other_index)
        local entry = items and items[key]
        if entry then reserved = reserved + entry.count end
      end
    end
  end
  return reserved
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

--- Slot indices of an inventory grouped by item key, built in a single pass so
--- that pushing many item types does not rescan the whole inventory each time.
---@param inventory LuaInventory
---@return table<string, number[]>
local index_slots = function(inventory)
  local slots = {}
  for index = 1, #inventory do
    local stack = inventory[index]
    if stack.valid_for_read then
      local key = util.item_key(stack.name, stack.quality and stack.quality.name or "normal")
      local list = slots[key]
      if not list then
        list = {}
        slots[key] = list
      end
      list[#list + 1] = index
    end
  end
  return slots
end

--- Moves missing materials from the character into the vehicle trunk and books
--- every moved item into the ledger so it can be returned later.
---
--- Stacks are moved rather than recreated from name/count: rebuilding would
--- reset spoilage, durability and ammo remaining, which both destroys item state
--- and hands out a free refresh on anything that spoils.
---@param player LuaPlayer
---@param trunk LuaInventory
---@param required table
---@return boolean moved_anything
transfer.push = function(player, trunk, required)
  local character_inventory = player.get_main_inventory()
  if not (character_inventory and character_inventory.valid) then return false end

  local vehicle = player.vehicle
  local unit_number = vehicle and vehicle.valid and vehicle.unit_number or nil
  local ledger = ledger_items_for(player.index, unit_number)
  local moved_anything = false
  local slots = index_slots(character_inventory)

  for _, entry in pairs(util.sorted_needs(required)) do
    local indices = slots[util.item_key(entry.name, entry.quality)]

    if indices then
      local remaining = entry.count
      local trunk_full = false

      for _, index in pairs(indices) do
        if remaining <= 0 then break end

        local stack = character_inventory[index]
        -- Re-checked rather than trusted: the index was built before any moves,
        -- and booking the wrong item into the ledger would hand back something
        -- that was never lent.
        local matches = stack.valid_for_read
          and stack.name == entry.name
          and (stack.quality and stack.quality.name or "normal") == entry.quality

        if matches then
          local wanted = math.min(remaining, stack.count)
          local moved = util.move_amount(stack, trunk, remaining)

          if moved > 0 then
            util.add_item(ledger, entry.name, entry.quality, moved)
            remaining = remaining - moved
            moved_anything = true
          end

          -- A short move means the trunk ran out of room, not that the player
          -- ran out of items: only the former is worth warning about.
          if moved < wanted then
            trunk_full = true
            break
          end
        end
      end

      if trunk_full then warn_trunk_full(player) end
    end
  end

  return moved_anything
end

--- Returns only what this player lent out, never the vehicle's own stock and
--- never another occupant's still-open debt.
---
--- Two independent caps apply, and the smaller wins:
---   * the ledger, so the vehicle's own stock is never handed over;
---   * the surplus above (boarding baseline + other occupants' ledgers), so
---     materials the robots already consumed reduce the debt instead of being
---     made up out of that protected stock.
---
--- Settlement is final either way. A debt that cannot be paid here cannot be
--- paid later: the vehicle is gone or the player has no character to receive the
--- items, and carrying the balance forward would only settle one vehicle's debt
--- against the next vehicle the player boards.
---
--- Robots are special only while airborne: robots waiting to be used sit in the
--- trunk as ordinary items, but ones already flying are entities and must be
--- recalled first. Busy robots stay with the vehicle, so the return may be
--- partial. The recall target includes the protected amount so the subsequent
--- baseline subtraction still leaves enough in the trunk to repay this player.
---@param player LuaPlayer
---@param vehicle LuaEntity
transfer.return_borrowed = function(player, vehicle)
  local ledger = storage.ledger[player.index]
  storage.ledger[player.index] = nil

  local items = ledger and ledger.items
  local should_return = items
    and util.setting(player, "vsi-return-on-exit", true)
    and vehicle
    and vehicle.valid

  if should_return then
    local trunk = eligibility.trunk_of(vehicle)
    local character_inventory = player.get_main_inventory()
    if trunk and character_inventory and character_inventory.valid then
      local unit_number = vehicle.unit_number

      for _, entry in pairs(items) do
        local reserved = protected_amount(player.index, unit_number, entry.name, entry.quality)

        if robots.is_robot_item(entry.name) then
          robots.recall_to_trunk(vehicle, trunk, entry.name, entry.quality, entry.count + reserved)
        end

        local present = trunk.get_item_count({ name = entry.name, quality = entry.quality })
        local remaining = math.min(entry.count, present - reserved)
        if remaining < 0 then remaining = 0 end

        -- Partial stacks must be split: `insert` merges lent items into the
        -- vehicle's existing stack, so a whole-stack-only rule would return
        -- nothing at all whenever the trunk already held the same item.
        for index = 1, #trunk do
          if remaining <= 0 then break end

          local stack = trunk[index]
          if stack.valid_for_read and stack.name == entry.name then
            local quality = stack.quality and stack.quality.name or "normal"
            if quality == entry.quality then
              remaining = remaining - util.move_amount(stack, character_inventory, remaining)
            end
          end
        end
      end
    end
  end

  -- Occupancy is released even when nothing was returned, so a later join on
  -- another vehicle cannot inherit this one as a phantom occupant.
  transfer.unjoin_player(player.index)
end

--- Drops bookkeeping without moving anything (death, vehicle destroyed).
---@param player_index number
transfer.clear_ledger = function(player_index)
  storage.ledger[player_index] = nil
end

--- First occupant snapshots the trunk; later occupants share that snapshot so
--- they cannot treat another player's still-lent items as vehicle stock.
---@param player_index number
---@param vehicle LuaEntity
transfer.join_vehicle = function(player_index, vehicle)
  if not (vehicle and vehicle.valid) then return end
  local unit_number = vehicle.unit_number
  if not unit_number then return end

  local veh = storage.vehicles[unit_number]
  if not veh then
    local baseline = {}
    local trunk = eligibility.trunk_of(vehicle)
    if trunk then
      for _, item in pairs(trunk.get_contents()) do
        util.add_item(baseline, item.name, item.quality, item.count)
      end
    end
    veh = { baseline = baseline, occupants = {} }
    storage.vehicles[unit_number] = veh
  end
  veh.occupants[player_index] = true
end

--- Removes the player from every vehicle occupant set. The vehicle record is
--- dropped when the last occupant leaves so the next boarding recaptures.
---@param player_index number
transfer.unjoin_player = function(player_index)
  local vehicles = storage.vehicles
  if not vehicles then return end

  local empty = {}
  for unit_number, veh in pairs(vehicles) do
    if veh.occupants then
      veh.occupants[player_index] = nil
      if not next(veh.occupants) then
        empty[#empty + 1] = unit_number
      end
    end
  end
  for _, unit_number in pairs(empty) do
    vehicles[unit_number] = nil
  end
end

--- How many of an item may be reclaimed: the amount above the protected floor.
---@param player_index number
---@param unit_number number|nil
---@param name string
---@param quality string
---@param present number
---@return number
local reclaimable_count = function(player_index, unit_number, name, quality, present)
  return present - protected_amount(player_index, unit_number, name, quality)
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

--- Moves deconstruction spoils back to the player once the trunk is running out
--- of room, so mining does not stall.
---
--- Three separate guards keep this from stealing: the protected floor covers
--- the vehicle's original stock and other occupants' debts, `protected_keys`
--- covers everything construction still needs, and the loop stops as soon as
--- enough space has been freed.
---@param player LuaPlayer
---@param trunk LuaInventory
---@param protected_keys table item keys that construction still needs
transfer.pull_overflow = function(player, trunk, protected_keys)
  local threshold = util.setting(player, "vsi-overflow-threshold", 20) / 100
  local wanted_free = math.ceil(#trunk * threshold)
  -- include_filtered already defaults to false; include_bar defaults to true,
  -- and a barred slot cannot be filled by robots, so it is not free for mining.
  local free = trunk.count_empty_stacks(false, false)
  if free > wanted_free then return end

  local character_inventory = player.get_main_inventory()
  if not (character_inventory and character_inventory.valid) then return end

  local vehicle = player.vehicle
  local unit_number = vehicle and vehicle.valid and vehicle.unit_number or nil
  local ledger = ledger_items(player.index)

  -- Budgets are computed up front because moving stacks mutates the inventory
  -- underneath us, making a live get_item_count unreliable mid-loop.
  local budget = {}
  for _, item in pairs(trunk.get_contents()) do
    local quality = item.quality or "normal"
    local key = util.item_key(item.name, quality)

    if not is_protected(item.name, quality, protected_keys)
      and character_inventory.get_item_count({ name = item.name, quality = quality }) > 0
    then
      local allowed = reclaimable_count(player.index, unit_number, item.name, quality, item.count)
      if allowed > 0 then budget[key] = allowed end
    end
  end

  if not next(budget) then return end

  -- Asked once: an inventory that supports no filters can skip the per-slot
  -- lookup entirely.
  local filtered_slots = trunk.is_filtered()
  local bar = trunk.supports_bar() and trunk.get_bar() or nil

  for index = 1, #trunk do
    -- Tracked incrementally rather than re-counted per slot: the count is a scan
    -- of the whole inventory, so asking once per slot is quadratic.
    if free > wanted_free then break end

    local stack = trunk[index]
    if stack.valid_for_read then
      local quality = stack.quality and stack.quality.name or "normal"
      local key = util.item_key(stack.name, quality)
      local allowed = budget[key]

      if allowed and allowed > 0 then
        local moved = util.move_amount(stack, character_inventory, allowed)
        if moved > 0 then
          budget[key] = allowed - moved
          if ledger then
            util.subtract_item(ledger, key, moved)
          end
          -- Only a fully drained slot frees space for mining, matching how the
          -- opening count was taken: filtered slots stay typed, barred slots
          -- stay unreachable to robots.
          if not stack.valid_for_read
            and not (filtered_slots and trunk.get_filter(index))
            and not (bar and index >= bar)
          then
            free = free + 1
          end
        end
      end
    end
  end
end

return transfer
