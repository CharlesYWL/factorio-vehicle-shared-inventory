local util = {}

--- Builds a stable string key for an item stack identity (name + quality).
--- Quality must never be dropped: different qualities are distinct items.
---@param name string
---@param quality string|nil
---@return string
util.item_key = function(name, quality)
  return name .. "/" .. (quality or "normal")
end

--- Squared distance between two positions. Avoids sqrt in hot paths.
---@param a MapPosition
---@param b MapPosition
---@return number
util.dist_sq = function(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

--- Adds `count` of an item into a needs/ledger table keyed by item_key.
--- `priority` entries are transferred before everything else.
---@param tbl table
---@param name string
---@param quality string|nil
---@param count number
---@param priority boolean|nil
util.add_item = function(tbl, name, quality, count, priority)
  -- Guarded rather than assumed: API payloads such as item requests have shifted
  -- shape between revisions, and a non-number here would otherwise crash on the
  -- comparison instead of being ignored.
  if type(count) ~= "number" or count <= 0 then return end
  local key = util.item_key(name, quality)
  local entry = tbl[key]
  if entry then
    entry.count = entry.count + count
    entry.priority = entry.priority or priority or nil
    return
  end
  tbl[key] = { name = name, quality = quality or "normal", count = count, priority = priority or nil }
end

--- Subtracts `count` from an entry, removing it when it drops to zero or below.
---@param tbl table
---@param key string
---@param count number
util.subtract_item = function(tbl, key, count)
  local entry = tbl[key]
  if not entry then return end
  entry.count = entry.count - count
  if entry.count <= 0 then
    tbl[key] = nil
  end
end

--- Resolves the item stack required to place a given prototype.
--- Mirrors the engine behaviour of picking the first placement item.
---@param prototype LuaEntityPrototype|LuaTilePrototype
---@return string|nil name, number count
util.placement_item = function(prototype)
  local items = prototype and prototype.items_to_place_this
  if not items or not items[1] then return nil, 0 end
  local first = items[1]
  return first.name, first.count or 1
end

--- Orders transfers: robots first (materials are useless without them), then
--- ascending by count so that scarce trunk slots cover the widest variety of
--- item types: robots stall if any single type is missing.
---@param needs table
---@return table array of entries
util.sorted_needs = function(needs)
  local list = {}
  for _, entry in pairs(needs) do
    list[#list + 1] = entry
  end
  table.sort(list, function(a, b)
    local a_priority = a.priority and 1 or 0
    local b_priority = b.priority and 1 or 0
    if a_priority ~= b_priority then return a_priority > b_priority end
    if a.count ~= b.count then return a.count < b.count end
    if a.name ~= b.name then return a.name < b.name end
    -- Quality is part of the identity, so without it two entries for the same
    -- item at different qualities compare equal and their order is left to the
    -- input, which makes the transfer order arbitrary.
    return (a.quality or "normal") < (b.quality or "normal")
  end)
  return list
end

--- Reads a per-player setting tolerantly. Settings are registered during the
--- startup stage, so a newly added one is absent until Factorio is fully
--- restarted: reloading a save is not enough. Falling back to a default keeps
--- the mod running instead of crashing in that window.
---@param player LuaPlayer
---@param name string
---@param fallback any
---@return any
util.setting = function(player, name, fallback)
  local setting = player.mod_settings[name]
  if setting == nil then return fallback end
  return setting.value
end

--- Global settings share the same startup-registration caveat as per-player
--- ones, so a newly added key is absent until Factorio is fully restarted.
---@param name string
---@param fallback any
---@return any
util.global_setting = function(name, fallback)
  local setting = settings.global[name]
  if setting == nil then return fallback end
  return setting.value
end

--- Moves a stack between inventories while preserving per-item state such as
--- durability, spoilage progress, blueprint contents and nested inventories.
--- Rebuilding items from name/quality/count would silently destroy all of it.
---@param source LuaItemStack
---@param target LuaInventory
---@return number moved
util.move_stack = function(source, target)
  if not (source and source.valid_for_read) then return 0 end

  local available = source.count
  local inserted = target.insert(source)
  if inserted <= 0 then return 0 end

  if inserted >= available then
    source.clear()
  else
    source.count = available - inserted
  end
  return inserted
end

--- Moves at most `wanted` items out of a stack, preserving per-item state.
---
--- A partial move cannot go through `insert{ name = , count = }`: that rebuilds
--- the items from scratch and silently resets durability, spoilage and tags.
--- Shrinking the stack first makes the engine copy the real item, and the
--- untouched remainder is restored afterwards.
---
--- Shrinking really does discard the difference for the duration of the insert.
--- That is safe because a stack is homogeneous -- every item in it shares the
--- same durability and spoilage -- so the restored remainder is identical to
--- what was dropped. Items carrying individual state, such as blueprints and
--- armour, have a stack size of one and therefore always take the whole-stack
--- path above instead.
---@param source LuaItemStack
---@param target LuaInventory
---@param wanted number
---@return number moved
util.move_amount = function(source, target, wanted)
  if not (source and source.valid_for_read) then return 0 end
  if wanted <= 0 then return 0 end

  local available = source.count
  if wanted >= available then return util.move_stack(source, target) end

  source.count = wanted
  local inserted = target.insert(source)
  source.count = available - inserted
  return inserted
end

return util
