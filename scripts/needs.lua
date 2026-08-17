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

--- item-request-proxy payload shape differs between API revisions, so both the
--- 2.0 array form and the legacy name->count dictionary are handled.
---@param proxy LuaEntity
---@param out table
local collect_item_requests = function(proxy, out)
  local requests = proxy.item_requests
  if not requests then return end

  for key, value in pairs(requests) do
    if type(value) == "table" then
      local name = value.name or (value.id and value.id.name)
      local quality = value.quality or (value.id and value.id.quality)
      local count = value.count or value.items or 0
      if type(quality) == "table" then quality = quality.name end
      if name then util.add_item(out, name, quality, count) end
    elseif type(key) == "string" and type(value) == "number" then
      util.add_item(out, key, quality_name(proxy), value)
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
--- They are neutral-force entities, so they need their own unfiltered query, and
--- the required item comes from the cliff prototype rather than from a ghost.
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param out table
local collect_cliffs = function(surface, position, radius, out)
  local cliffs = surface.find_entities_filtered({
    position = position,
    radius = radius,
    type = "cliff",
    to_be_deconstructed = true,
  })

  for _, cliff in pairs(cliffs) do
    if cliff.valid then
      local explosive = cliff.prototype.cliff_explosive_prototype
      if explosive then
        util.add_item(out, explosive, "normal", 1)
      end
    end
  end
end

--- Gathers build sources around the vehicle, applying the scale probe described
--- in SPEC 4.4: small workloads skip sorting entirely.
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
  local total = surface.count_entities_filtered(base_filter)
  local entities = surface.find_entities_filtered(base_filter)

  local upgrades = surface.find_entities_filtered({
    position = position,
    radius = radius,
    force = force,
    to_be_upgraded = true,
  })
  for _, entity in pairs(upgrades) do
    entities[#entities + 1] = entity
  end
  total = total + #upgrades

  -- Deconstruction needs robots but no materials, and trees/rocks are not owned
  -- by the player force, so the force filter must be omitted here.
  local has_deconstruction = surface.count_entities_filtered({
    position = position,
    radius = radius,
    to_be_deconstructed = true,
    limit = 1,
  }) > 0

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
needs.scan = function(player, vehicle, trunk, radius)
  local required = {}
  local sources, has_work = gather_sources(vehicle.surface, vehicle.position, radius, vehicle.force)

  for _, entity in pairs(sources) do
    if entity.valid then
      local entity_type = entity.type
      if entity_type == "entity-ghost" or entity_type == "tile-ghost" then
        collect_ghost(entity, required)
      elseif entity_type == "item-request-proxy" then
        collect_item_requests(entity, required)
      else
        collect_upgrade(entity, required)
      end
    end
  end

  collect_cliffs(vehicle.surface, vehicle.position, radius, required)

  for key, entry in pairs(required) do
    local present = trunk.get_item_count({ name = entry.name, quality = entry.quality })
    util.subtract_item(required, key, present)
  end

  -- Gated on work existing rather than on materials being missing: deconstruction
  -- orders need robots while requiring nothing from the needs table.
  if has_work and util.setting(player, "vsi-share-robots", true) then
    robots.add_needs(player, vehicle, trunk, required)
  end

  return required
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

  local deconstruction = surface.count_entities_filtered({
    position = vehicle.position,
    radius = radius,
    to_be_deconstructed = true,
    limit = 1,
  }) > 0

  return ghosts, deconstruction
end

return needs
