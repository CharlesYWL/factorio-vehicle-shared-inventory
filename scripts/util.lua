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
  if count <= 0 then return end
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
    return a.name < b.name
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

return util
