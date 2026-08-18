local util = require("scripts.util")
local robots = require("scripts.robots")

local needs = {}

local GHOST_TYPES = { "entity-ghost", "tile-ghost", "item-request-proxy" }

--- Quality name of a ghost/entity, tolerating prototypes without quality.
---@param entity LuaEntity
---@return string
local quality_name = function(entity)
  local quality = entity.quality
  if not quality then return "normal" end
  if type(quality) == "string" then return quality end
  return quality.name or "normal"
end

--- Total count carried by an insert-plan style `items` payload, which nests the
--- amounts per target inventory slot instead of exposing a flat count.
---@param items table
---@return number
local insert_plan_count = function(items)
  if type(items) ~= "table" then return 0 end

  local total = items.grid_count or 0
  local in_inventory = items.in_inventory
  if type(in_inventory) == "table" then
    for _, position in pairs(in_inventory) do
      total = total + (position.count or 1)
    end
  end
  return total
end

--- Item request payloads differ between API revisions, so the flat 2.0 array
--- form, the insert-plan form and the legacy name->count dictionary are all
--- handled. Entity ghosts carry these too: a blueprinted machine records its
--- modules on the ghost long before the item request proxy exists.
---@param source LuaEntity ghost or item request proxy
---@param out table
local collect_item_requests = function(source, out)
  local requests = source.item_requests
  if not requests then return end

  for key, value in pairs(requests) do
    if type(value) == "table" then
      local id = value.id
      local name = value.name or (id and id.name)
      local quality = value.quality or (id and id.quality)
      if type(name) == "table" then name = name.name end
      if type(quality) == "table" then quality = quality.name end

      local count = value.count
      if type(count) ~= "number" then count = insert_plan_count(value.items) end

      if name then util.add_item(out, name, quality, count) end
    elseif type(key) == "string" and type(value) == "number" then
      util.add_item(out, key, quality_name(source), value)
    end
  end
end

---@param ghost LuaEntity
---@param out table
local collect_ghost = function(ghost, out)
  local name, count = util.placement_item(ghost.ghost_prototype)
  if not name then return end
  util.add_item(out, name, quality_name(ghost), count)
end

---@param entity LuaEntity
---@param out table
local collect_upgrade = function(entity, out)
  local target, target_quality = entity.get_upgrade_target()
  if not target then return end
  local name, count = util.placement_item(target)
  if not name then return end
  local quality = target_quality and target_quality.name or "normal"
  util.add_item(out, name, quality, count)
end

--- Cliffs marked for deconstruction consume explosives rather than being mined.
--- They are neutral-force entities, so the query cannot filter by force; instead
--- each hit is checked against the vehicle's own force so one player's vehicle
--- never services another force's orders.
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param out table
---@param force LuaForce
local collect_cliffs = function(surface, position, radius, out, force)
  local cliffs = surface.find_entities_filtered({
    position = position,
    radius = radius,
    type = "cliff",
    to_be_deconstructed = true,
  })

  for _, cliff in pairs(cliffs) do
    if cliff.valid and cliff.is_registered_for_deconstruction(force) then
      local explosive = cliff.prototype.cliff_explosive_prototype
      if explosive then
        util.add_item(out, explosive, "normal", 1)
      end
    end
  end
end

--- Whether any deconstruction order near the position belongs to the given force.
--- Trees, rocks and cliffs are neutral-force entities, so the query itself cannot
--- be force-filtered and each candidate must be checked individually.
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param force LuaForce
---@return boolean
local has_deconstruction_for = function(surface, position, radius, force)
  local candidates = surface.find_entities_filtered({
    position = position,
    radius = radius,
    to_be_deconstructed = true,
  })

  for _, entity in pairs(candidates) do
    if entity.valid and entity.is_registered_for_deconstruction(force) then
      return true
    end
  end

  -- Tiles marked for deconstruction (concrete, bricks) are a separate query and
  -- also count as work needing robots.
  local tiles = surface.find_tiles_filtered({
    position = position,
    radius = radius,
    to_be_deconstructed = true,
    limit = 1,
  })
  return #tiles > 0
end

--- Gathers build sources around the vehicle, applying the scale probe described
--- in SPEC 4.4: small workloads skip sorting entirely.
---
--- Returns the material-bearing sources plus a flag for whether any construction
--- work at all exists nearby. Deconstruction counts as work but consumes no
--- materials, so it must be tracked separately from the needs table.
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param force LuaForce
---@return LuaEntity[] sources, boolean has_work
local gather_sources = function(surface, position, radius, force)
  local base_filter = {
    position = position,
    radius = radius,
    force = force,
    type = GHOST_TYPES,
  }

  local limit = util.global_setting("vsi-max-ghosts", 5000)
  local entities = surface.find_entities_filtered(base_filter)
  local total = #entities

  -- Ghosts can themselves be marked for upgrade, so the two queries overlap.
  -- Without the guard such an entity is collected twice, and the second pass
  -- reads it as a plain ghost and asks for the old item instead of the new one.
  local seen = {}
  for _, entity in pairs(entities) do
    seen[entity.unit_number or entity] = true
  end

  local upgrades = surface.find_entities_filtered({
    position = position,
    radius = radius,
    force = force,
    to_be_upgraded = true,
  })
  for _, entity in pairs(upgrades) do
    local id = entity.unit_number or entity
    if not seen[id] then
      seen[id] = true
      entities[#entities + 1] = entity
      total = total + 1
    end
  end

  -- Deconstruction needs robots but no materials. It cannot be force-filtered in
  -- the query because trees, rocks and cliffs are neutral, so each candidate is
  -- checked against this force individually.
  local has_deconstruction = has_deconstruction_for(surface, position, radius, force)

  local has_work = total > 0 or has_deconstruction

  if total <= limit then return entities, has_work end

  table.sort(entities, function(a, b)
    return util.dist_sq(a.position, position) < util.dist_sq(b.position, position)
  end)

  local trimmed = {}
  for index = 1, limit do
    trimmed[index] = entities[index]
  end
  return trimmed, has_work
end

--- Computes what the trunk is still missing to satisfy nearby build orders.
--- Robots are appended after the material subtraction because their shortfall is
--- computed against roboport capacity, not against ghost requirements.
---@param player LuaPlayer
---@param vehicle LuaEntity
---@param trunk LuaInventory
---@param radius number
---@return table needs keyed by item_key
--- Computes what the trunk is still missing to satisfy nearby build orders.
--- Robots are appended after the material subtraction because their shortfall is
--- computed against roboport capacity, not against ghost requirements.
---
--- Also returns the set of item keys construction needs *in full*, before the
--- trunk stock is subtracted. Overflow reclaim must consult that full set: the
--- shortfall alone would mark already-satisfied materials as reclaimable, so
--- they would be pulled out and pushed back forever.
---@param player LuaPlayer
---@param vehicle LuaEntity
---@param trunk LuaInventory
---@param radius number
---@return table needs keyed by item_key, table protected_keys
needs.scan = function(player, vehicle, trunk, radius)
  local required = {}
  local sources, has_work = gather_sources(vehicle.surface, vehicle.position, radius, vehicle.force)

  for _, entity in pairs(sources) do
    if entity.valid then
      local entity_type = entity.type
      if entity_type == "entity-ghost" then
        collect_ghost(entity, required)
        -- Modules and other insert requests ride along on the ghost itself.
        collect_item_requests(entity, required)
      elseif entity_type == "tile-ghost" then
        collect_ghost(entity, required)
      elseif entity_type == "item-request-proxy" then
        collect_item_requests(entity, required)
      else
        collect_upgrade(entity, required)
      end
    end
  end

  collect_cliffs(vehicle.surface, vehicle.position, radius, required, vehicle.force)

  local protected_keys = {}
  for key in pairs(required) do
    protected_keys[key] = true
  end

  for key, entry in pairs(required) do
    local present = trunk.get_item_count({ name = entry.name, quality = entry.quality })
    util.subtract_item(required, key, present)
  end

  -- Gated on work existing rather than on materials being missing: deconstruction
  -- orders need robots while requiring nothing from the needs table.
  if has_work and util.setting(player, "vsi-share-robots", true) then
    robots.add_needs(player, vehicle, trunk, required)
  end

  return required, protected_keys
end

--- Whether any construction work exists near the vehicle, including
--- deconstruction orders that require no materials.
---@param vehicle LuaEntity
---@param radius number
---@return boolean has_ghosts, boolean has_deconstruction
needs.probe_work = function(vehicle, radius)
  local surface = vehicle.surface
  local ghosts = surface.count_entities_filtered({
    position = vehicle.position,
    radius = radius,
    force = vehicle.force,
    type = GHOST_TYPES,
    limit = 1,
  }) > 0

  local deconstruction = has_deconstruction_for(surface, vehicle.position, radius, vehicle.force)

  return ghosts, deconstruction
end

return needs
