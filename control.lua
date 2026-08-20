local util = require("scripts.util")
local eligibility = require("scripts.eligibility")
local needs = require("scripts.needs")
local robots = require("scripts.robots")
local transfer = require("scripts.transfer")

local BASE_TICK = 5
local FORCE_RESCAN_TICKS = 300

local init_storage = function()
  storage.tracked_players = storage.tracked_players or {}
  storage.cache = storage.cache or {}
  storage.ledger = storage.ledger or {}
  storage.vehicles = storage.vehicles or {}
end

---@param player_index number
---@return table
local cache_for = function(player_index)
  local cache = storage.cache[player_index]
  if not cache then
    cache = { dirty = true, last_scan_tick = 0 }
    storage.cache[player_index] = cache
  end
  return cache
end

---@param player_index number
local track_player = function(player_index)
  storage.tracked_players[player_index] = true
  local cache = cache_for(player_index)
  cache.dirty = true
  cache.needs = nil
  cache.protected_keys = nil
  cache.last_vehicle_pos = nil
  -- Cleared so the vehicle-swap check below cannot keep re-firing for a vehicle
  -- this mod never services and therefore never records a unit number for.
  cache.vehicle_unit_number = nil

  local player = game.get_player(player_index)
  if not player then return end
  local vehicle = player.vehicle
  -- Recorded on board, before the first scan, so a passenger who has not yet
  -- been serviced is still found when the vehicle is destroyed.
  if vehicle and vehicle.valid and eligibility.trunk_of(vehicle) then
    cache.vehicle_unit_number = vehicle.unit_number
    transfer.join_vehicle(player_index, vehicle)
  end
end

--- Forgets a player entirely: tracking, cache, ledger and vehicle occupancy.
---@param player_index number
local forget_player = function(player_index)
  storage.tracked_players[player_index] = nil
  storage.cache[player_index] = nil
  transfer.clear_ledger(player_index)
  transfer.unjoin_player(player_index)
end

--- Reconciles the tracked set against reality. The driving event never fires for
--- players who were already seated when the save was loaded or the mod added, so
--- the set cannot be event-driven alone.
local reconcile_tracked = function()
  for _, player in pairs(game.connected_players) do
    local vehicle = player.vehicle
    local in_vehicle = vehicle ~= nil and vehicle.valid
    local tracked = storage.tracked_players[player.index] == true

    if in_vehicle and not tracked then
      track_player(player.index)
    elseif not in_vehicle and tracked then
      forget_player(player.index)
    elseif in_vehicle and tracked then
      -- A swap between vehicles can happen without a driving event pairing that
      -- this loop would otherwise miss, leaving a debt recorded against the old
      -- vehicle. Settle that vehicle first so the new join cannot recapture a
      -- baseline that still contains another player's items, or repay V1 from V2.
      local cache = storage.cache[player.index]
      if cache and cache.vehicle_unit_number
        and cache.vehicle_unit_number ~= vehicle.unit_number then
        local previous = game.get_entity_by_unit_number(cache.vehicle_unit_number)
        if previous and previous.valid then
          transfer.return_borrowed(player, previous)
        else
          transfer.clear_ledger(player.index)
          transfer.unjoin_player(player.index)
        end
        track_player(player.index)
      end
    end
  end
end

--- Every tracked player's cache is invalidated. Used only when an event gives no
--- usable location.
local mark_all_dirty = function()
  for player_index in pairs(storage.tracked_players) do
    cache_for(player_index).dirty = true
  end
end

--- Where a build/mine/order event happened, when it can be determined.
---@param event table
---@return MapPosition|nil position, number|nil surface_index
local event_location = function(event)
  local entity = event.entity or event.ghost
  if entity and entity.valid then
    return entity.position, entity.surface.index
  end

  local tiles = event.tiles
  if tiles and tiles[1] and tiles[1].position then
    return tiles[1].position, event.surface_index
  end

  return nil, nil
end

--- Build orders are global, but a ghost created on the far side of the map can
--- never fall inside a vehicle's construction radius. Invalidating every cache
--- on every robot-placed entity would defeat caching exactly when construction
--- is busiest, so only caches whose last scan area covers the event are marked.
---@param event table
local mark_dirty_near = function(event)
  local position, surface_index = event_location(event)
  if not position then
    mark_all_dirty()
    return
  end

  for player_index in pairs(storage.tracked_players) do
    local cache = storage.cache[player_index]
    if cache and not cache.dirty then
      local last = cache.last_vehicle_pos
      if not last or not cache.surface_index then
        cache.dirty = true
      elseif surface_index == nil or surface_index == cache.surface_index then
        -- The cached position is allowed to be a quarter radius stale by design,
        -- so the comparison is deliberately generous.
        local reach = (cache.radius or 0) * 1.5 + 4
        if util.dist_sq(last, position) <= reach * reach then
          cache.dirty = true
        end
      end
    end
  end
end

--- The cached needs snapshot is stale when flagged by an event, when the vehicle
--- has drifted a quarter of its build radius, or when the safety interval lapses.
---@param cache table
---@param vehicle LuaEntity
---@param radius number
---@return boolean
local needs_rescan = function(cache, vehicle, radius)
  if cache.dirty or not cache.needs then return true end
  if game.tick - cache.last_scan_tick >= FORCE_RESCAN_TICKS then return true end
  if cache.vehicle_unit_number ~= vehicle.unit_number then return true end
  if cache.surface_index ~= vehicle.surface.index then return true end

  local last = cache.last_vehicle_pos
  if not last then return true end

  local drift = radius * 0.25
  return util.dist_sq(last, vehicle.position) >= drift * drift
end

---@param player LuaPlayer
local service_player = function(player)
  local trunk, radius, vehicle = eligibility.resolve(player)
  if not trunk then return end

  local cache = cache_for(player.index)

  if needs_rescan(cache, vehicle, radius) then
    cache.needs, cache.protected_keys = needs.scan(player, vehicle, trunk, radius)
    cache.dirty = false
    cache.last_scan_tick = game.tick
    cache.vehicle_unit_number = vehicle.unit_number
    cache.surface_index = vehicle.surface.index
    cache.radius = radius
    cache.last_vehicle_pos = { x = vehicle.position.x, y = vehicle.position.y }
  end

  if next(cache.needs) then
    -- Only invalidate when something actually moved. Marking dirty on every pass
    -- with an unsatisfiable need would force a full rescan forever.
    if transfer.push(player, trunk, cache.needs) then
      cache.dirty = true
    end
  end

  if util.setting(player, "vsi-return-overflow", true) then
    transfer.pull_overflow(player, trunk, cache.protected_keys or {})
  end
end

local RECONCILE_TICKS = 60

local on_tick = function(event)
  -- Runs even when nothing is tracked: this is what recovers players who were
  -- already seated before the mod started observing them.
  if event.tick % RECONCILE_TICKS == 0 then
    reconcile_tracked()
  end

  if not next(storage.tracked_players) then return end

  for player_index in pairs(storage.tracked_players) do
    local player = game.get_player(player_index)
    if player and player.valid then
      local interval = util.setting(player, "vsi-interval", 15)
      if event.tick % interval == 0 then
        service_player(player)
      end
    else
      -- Cleared through forget_player so the cache, ledger and occupancy go too,
      -- rather than leaking one entry per departed player into the save.
      forget_player(player_index)
    end
  end
end

local on_driving_changed = function(event)
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end

  local previous_vehicle = event.entity
  local current_vehicle = player.vehicle

  local left_vehicle = previous_vehicle
    and previous_vehicle.valid
    and previous_vehicle ~= current_vehicle

  if left_vehicle then
    transfer.return_borrowed(player, previous_vehicle)
  end

  if current_vehicle and current_vehicle.valid then
    track_player(event.player_index)
  else
    forget_player(event.player_index)
  end
end

local on_player_died = function(event)
  forget_player(event.player_index)
end

--- Disconnecting must not quietly donate the borrowed items to the vehicle: the
--- character stays in the world, so the normal return path still works.
local on_player_left = function(event)
  local player = game.get_player(event.player_index)
  if player and player.valid then
    local vehicle = player.vehicle
    if vehicle and vehicle.valid then
      transfer.return_borrowed(player, vehicle)
    end
  end
  forget_player(event.player_index)
end

local on_entity_died = function(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if not eligibility.trunk_of(entity) then return end

  -- Driving-changed does not fire when a vehicle is destroyed, so occupants
  -- must be forgotten here. The occupant set is the source of truth; the cache
  -- unit number is a fallback for anyone who was tracked before a join ran.
  local unit_number = entity.unit_number
  local seen = {}
  local veh = storage.vehicles[unit_number]
  if veh and veh.occupants then
    local occupants = {}
    for player_index in pairs(veh.occupants) do
      occupants[#occupants + 1] = player_index
    end
    for _, player_index in pairs(occupants) do
      seen[player_index] = true
      forget_player(player_index)
    end
  end

  for player_index in pairs(storage.tracked_players) do
    if not seen[player_index] then
      local cache = storage.cache[player_index]
      if cache and cache.vehicle_unit_number == unit_number then
        forget_player(player_index)
      end
    end
  end
end

script.on_init(function()
  init_storage()
  reconcile_tracked()
end)

script.on_configuration_changed(function()
  init_storage()
  -- Existing saves have no baselines, and without one overflow reclaim cannot
  -- tell the vehicle's own stock apart from spoils. Re-tracking captures it.
  --
  -- The ledger has to go with it: a debt recorded against the old baseline would
  -- be settled against the new one, returning items that were never lent.
  -- Pre-0.2.1 saves also keyed the baseline per player; that map is dropped so
  -- it cannot be mixed with the per-vehicle records.
  for player_index in pairs(storage.tracked_players) do
    forget_player(player_index)
  end
  storage.baseline = nil
  storage.ledger = {}
  storage.vehicles = {}
  reconcile_tracked()
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.get_player(event.player_index)
  if player and player.vehicle and player.vehicle.valid then
    track_player(event.player_index)
  end
end)

script.on_nth_tick(BASE_TICK, on_tick)

script.on_event(defines.events.on_player_driving_changed_state, on_driving_changed)
script.on_event(defines.events.on_pre_player_died, on_player_died)
script.on_event(defines.events.on_player_left_game, on_player_left)
script.on_event(defines.events.on_entity_died, on_entity_died, {
  -- Unfiltered this would run for every biter, tree and rock that dies anywhere
  -- on the map, which is a real cost during combat.
  { filter = "type", type = "car" },
  { filter = "type", type = "spider-vehicle" },
})

local dirty_events = {
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.on_robot_built_tile,
  defines.events.on_player_built_tile,
  defines.events.on_pre_ghost_deconstructed,
  defines.events.on_marked_for_deconstruction,
  defines.events.on_marked_for_upgrade,
  defines.events.on_cancelled_upgrade,
  defines.events.on_cancelled_deconstruction,
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity,
  defines.events.on_player_mined_tile,
  defines.events.on_robot_mined_tile,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
  defines.events.script_raised_destroy,
}

for _, event_id in pairs(dirty_events) do
  script.on_event(event_id, mark_dirty_near)
end

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "vsi-enabled" or event.setting == "vsi-require-roboport" then
    mark_all_dirty()
  end
end)

commands.add_command("vsi-debug", "Vehicle Shared Inventory diagnostics", function(command)
  -- Absent when the command is run from the server console, where there is no
  -- player to report to.
  if not command.player_index then return end
  local player = game.get_player(command.player_index)
  if not player then return end

  local say = function(text) player.print(text) end

  say("--- vsi-debug ---")
  say("enabled: " .. tostring(util.setting(player, "vsi-enabled", true)))
  say("tracked: " .. tostring(storage.tracked_players[player.index] == true))
  say("character: " .. tostring(player.character ~= nil))
  local vehicle = player.vehicle
  if not (vehicle and vehicle.valid) then
    say("vehicle: NONE -- you must be riding it (remote control is not supported)")
    return
  end
  say("vehicle: " .. vehicle.name .. " (type=" .. vehicle.type .. ")")

  local radius = eligibility.construction_radius(vehicle)
  say("powered roboport radius: " .. radius)
  if vehicle.grid then
    for _, equipment in pairs(vehicle.grid.equipment) do
      if equipment.type == "roboport-equipment" then
        say("  roboport " .. equipment.name .. " energy=" .. equipment.energy)
      end
    end
  else
    say("  vehicle has NO equipment grid")
  end

  local trunk, resolved_radius = eligibility.resolve(player)
  if not trunk then
    say("resolve: FAILED -- mod will not act")
    return
  end
  say("resolve: OK, scan radius=" .. resolved_radius)

  local counted = vehicle.surface.count_entities_filtered({
    position = vehicle.position,
    radius = resolved_radius,
    force = vehicle.force,
    type = { "entity-ghost", "tile-ghost", "item-request-proxy" },
  })
  say("ghosts in radius: " .. counted)
  local has_ghosts, has_deconstruction = needs.probe_work(vehicle, resolved_radius)
  say("work nearby: ghosts=" .. tostring(has_ghosts) .. " deconstruction=" .. tostring(has_deconstruction))
  say("robot capacity: " .. robots.capacity(vehicle) .. ", present: " .. robots.present(vehicle, trunk))
  say("trunk: " .. trunk.count_empty_stacks(false, false) .. " free of " .. #trunk .. " slots")

  local required = needs.scan(player, vehicle, trunk, resolved_radius)
  local veh = storage.vehicles[vehicle.unit_number]
  local baseline = veh and veh.baseline
  local baseline_types = 0
  local occupants = 0
  if baseline then
    for _ in pairs(baseline) do baseline_types = baseline_types + 1 end
  end
  if veh and veh.occupants then
    for _ in pairs(veh.occupants) do occupants = occupants + 1 end
  end
  if baseline then
    say("vehicle baseline: " .. baseline_types .. " item types protected, occupants=" .. occupants)
  else
    say("vehicle baseline: NONE")
  end

  local lines = 0
  for _, entry in pairs(required) do
    say("  missing " .. entry.name .. " [" .. entry.quality .. "] x" .. entry.count)
    lines = lines + 1
    if lines >= 15 then
      say("  ...")
      break
    end
  end
  if lines == 0 then say("  nothing missing") end
end)
