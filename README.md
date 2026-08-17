# Vehicle Shared Inventory

Factorio 2.0 / Space Age mod.

**English** | [中文](./README.zh-CN.md)

Building from inside a spidertron (or car, or tank) is awkward: construction robots only pull materials from the vehicle trunk, so anything sitting in your character inventory is useless until you climb out and transfer it by hand. This mod moves what is missing into the trunk automatically, and gives it back when you leave.

## Features

- **Automatic resupply** — scans entity ghosts, **tile ghosts**, module requests and upgrade orders within the vehicle's construction radius, and transfers only what is actually missing.
- **Cliff explosives** — cliffs marked for deconstruction are neutral-force entities with no ghost, so they are detected separately and the required explosive is supplied.
- **Robot sharing** — lends construction robots from your inventory up to the vehicle's roboport capacity, triggered by construction *or* deconstruction work nearby, so an idle vehicle never drains your stock. Highest quality first.
- **Overflow reclaim** — when the trunk runs low on free slots, deconstruction spoils are moved back into your inventory so mining does not stall. Only item types you already carry are taken, and ammo, fuel and robots are never reclaimed.
- **Ledger-based return** — on exit, only the items this mod lent are returned. **The vehicle's own stock is never taken.**
- **Quality aware** — items of different qualities are tracked separately and never merged.
- **Broad vehicle support** — spidertrons, cars and tanks, matched by prototype type so modded vehicles work automatically.
- **Performance first** — dirty-flag caching and a scale probe keep the main loop near O(1) when idle.

## Why this is not a true "merged inventory"

The engine hardcodes the construction source for vehicle roboports (`car_trunk` / `spider_trunk`), and the Lua API offers no way to inject a second source. `LinkedContainerPrototype` sharing only applies between containers of the same prototype, so neither the character nor the vehicle qualifies.

A genuine inventory merge is therefore impossible at the API level. This mod simulates one through **on-demand transfer**.

## Settings

| Setting | Default | Description |
|---|---|---|
| Enable shared inventory | on | Master switch (per player) |
| Share construction robots | on | Lend robots up to roboport capacity |
| Update interval | 15 ticks | 5 / 15 / 30 / 60 |
| Return borrowed items when leaving | on | Turn off for one-way lending |
| Reclaim spoils when trunk fills up | on | Move deconstruction output back to you |
| Trunk free space threshold | 20% | Reclaim starts below this much free space |
| Require a roboport in the vehicle | on | Turn off to share without a roboport |
| Supported vehicles | Spidertrons, cars and tanks | Startup setting |
| Max ghosts per scan | 5000 | Global setting |

> Adding or changing settings requires a **full restart of Factorio**, not just reloading a save: settings are registered during the startup stage.

## Installation (in development)

Place the folder (or a `vehicle-shared-inventory_0.1.0.zip` archive) into:

```
%APPDATA%\Factorio\mods\
```

The folder must be named `vehicle-shared-inventory_0.1.0`.

For development, a symlink works well:

```powershell
New-Item -ItemType SymbolicLink `
  -Path "$env:APPDATA\Factorio\mods\vehicle-shared-inventory_0.1.0" `
  -Target "<path to this repo>"
```

## Diagnostics

Run in the console while riding a vehicle:

```
/vsi-debug
```

Reports whether the player is tracked, the powered roboport radius, ghost count in range, robot capacity versus robots present, and the computed shortfall.

## Known limitations

- Does not work while remote-controlling a spidertron (only while riding).
- Train wagons are not supported.
- Ammo and fuel slots are not resupplied.
- Robots that are in flight or carrying cargo are not recalled on exit. They stay with the vehicle rather than being destroyed, so a return may be partial — nothing is lost.

See [SPEC.md](./SPEC.md) for the full design.

## License

MIT
