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

--- Gathers build sources around the vehicle, applying the scale probe described
--- in SPEC 4.4: small workloads skip sorting entirely.
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param force LuaForce
---@return LuaEntity[]
local gather_sources = function(surface, position, radius, force)
  local base_filter = {
    position = position,
    radius = radius,
    force = force,
    type = GHOST_TYPES,
  }

  local limit = settings.global["vsi-max-ghosts"].value
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

  if total <= limit then return entities end

  table.sort(entities, function(a, b)
    return util.dist_sq(a.position, position) < util.dist_sq(b.position, position)
  end)

  local trimmed = {}
  for index = 1, limit do
    trimmed[index] = entities[index]
  end
  return trimmed
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
  local sources = gather_sources(vehicle.surface, vehicle.position, radius, vehicle.force)

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

  for key, entry in pairs(required) do
    local present = trunk.get_item_count({ name = entry.name, quality = entry.quality })
    util.subtract_item(required, key, present)
  end

  -- Only lend robots when there is work to do, so an idle vehicle never drains
  -- the player's stock.
  if next(required) and player.mod_settings["vsi-share-robots"].value then
    robots.add_needs(player, vehicle, trunk, required)
  end

  return required
end

return needs
