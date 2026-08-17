# Vehicle Shared Inventory — 设计规格 (SPEC)

Factorio 2.0 / Space Age mod。目标：玩家在载具内时，个人机器人建造所需材料可自动从玩家背包补给到载具后备箱，无需下车。

---

## 1. 问题陈述

原版行为：

- 玩家进入载具后，护甲装备栏（含个人机器人站）失效，起作用的是**载具的 equipment grid**。
- 载具机器人建造时只从载具后备箱取货（`car_trunk` / `spider_trunk`），引擎硬编码。
- 玩家背包里即使有材料，机器人也**不会**使用。

结果：野外开图 / 铺蓝图时必须反复下车倒货，体验割裂。

### 为什么不能真正"合并库存"

- Lua API 无法向建造机器人注入第二个取货来源。
- `LinkedContainerPrototype` 只对同 prototype 的容器生效，角色与载具都不适用。

**结论**：只能用"高频按需搬运"模拟共享。本 mod 采用 **ghost 驱动的按需拉取**。

---

## 2. 范围

### 2.1 支持的载具

凡是玩家可乘坐、拥有 equipment grid 且带 roboport equipment 的载具：

| 类型 | prototype type | 库存定义 |
|---|---|---|
| 蜘蛛机甲 / 模组蜘蛛 | `spider-vehicle` | `defines.inventory.spider_trunk` |
| 汽车 / 坦克 / 模组车辆 | `car` | `defines.inventory.car_trunk` |

**不支持**：火车车厢（`locomotive` / `cargo-wagon`）——本版本明确排除，后续可选加。

### 2.2 触发前提（全部满足才生效）

1. `player.vehicle` 存在且 type 在支持列表内。
2. `player.character` 存在（背包可读写）。
3. 载具 equipment grid 内存在**已通电的** roboport equipment（`type == "roboport-equipment"`）。
4. 玩家与载具在同一 surface（乘坐时天然成立）。
5. 该玩家未在设置中关闭本功能。

---

## 3. 核心算法

### 3.1 主循环（`on_nth_tick`，默认 15 tick）

```
for each active player in tracked_players:
    vehicle = player.vehicle
    if not is_eligible(player, vehicle): continue
    if not needs_recalc(player): reuse cached needs
    else: needs = scan_needs(vehicle)
    transfer(player.character_inventory -> vehicle_trunk, needs)
```

### 3.2 需求扫描 `scan_needs(vehicle)`

范围：`radius = 载具 grid 内所有 roboport equipment 的最大 construction_radius`。

扫描以下来源，累加为 `needs[{name, quality}] = count`：

| 来源 | 取材料的方式 |
|---|---|
| `entity-ghost` | `ghost.ghost_prototype.items_to_place_this`（含 count） |
| `tile-ghost` | 同上（地板类，**不可遗漏**） |
| `item-request-proxy` | `proxy.item_requests`（插模块） |
| 升级请求 (`to_be_upgraded`) | 目标 prototype 的 `items_to_place_this` |

随后扣除载具后备箱现有数量：`needs[k] -= trunk.get_item_count(k)`，`<= 0` 的丢弃。

**注意**：所有物品计数必须带 `quality`，键为 `name .. "/" .. quality`。禁止使用裸 item name。

### 3.3 搬运 `transfer`

```
for each (item, needed) in needs, sorted by needed ascending:
    available = character_inventory.get_item_count({name, quality})
    if available == 0: continue
    amount = min(needed, available)
    inserted = trunk.insert{name, quality, count = amount}
    if inserted > 0:
        character_inventory.remove{name, quality, count = inserted}
        ledger[player][item] += inserted        -- 记账，用于回流
    if inserted < amount: trunk 已满 -> 记录一次 "trunk full" 警告（节流）
```

**排序理由**：优先满足需求量小的品类，保证后备箱格子有限时覆盖更多**种类**（种类齐全比单品充足更能让机器人开工）。

### 3.4 回流 `return_borrowed`

触发时机：`on_player_driving_changed_state` 且玩家**离开**载具。

```
for each (item, amount) in ledger[player]:
    actual = min(amount, trunk.get_item_count(item))
    moved = character_inventory.insert{item, count = actual}
    trunk.remove{item, count = moved}
clear ledger[player]
```

原则：**只还借出的，不抢载具原有物资**。ledger 记录本 mod 净搬入的量；若期间被机器人消耗，`actual` 自然减少，不会凭空产生物品。

玩家背包满时：剩余留在载具，ledger 清空（避免无限累积），打印一次提示。

---

## 4. 性能设计

这是 mod 成败的关键。约束：不允许每 tick 全量扫描。

### 4.1 脏标记缓存

`scan_needs` 结果按玩家缓存。仅在下列事件触发时置脏：

- `on_built_entity` / `on_robot_built_entity` / `script_raised_built`（产生 ghost）
- `on_pre_ghost_deconstructed` / `on_robot_built_entity`（ghost 被消耗）
- `on_marked_for_deconstruction` / `on_marked_for_upgrade`
- `on_player_driving_changed_state`
- 载具移动超过 `radius / 4` 距离（每次主循环用平方距离比较，不开方）

无脏标记时复用缓存，主循环退化为 O(1)。

### 4.2 强制刷新兜底

即使无脏标记，每 `force_rescan_interval`（默认 300 tick = 5s）也强制重扫一次，防止事件遗漏导致状态僵死。

### 4.3 玩家集合维护

维护 `storage.tracked_players`（在载具中的玩家 index 集合），由 `on_player_driving_changed_state` 增删。主循环只遍历该集合，而非 `game.players`。

### 4.4 扫描量上限

先用 `count_entities_filtered` 探测规模：

- 规模 <= `max_ghosts_per_scan`（默认 5000）：直接全扫，不做排序，零额外开销。
- 规模超限：取回后按到载具的平方距离升序排序，截取前 N 个。

截断只影响单次需求快照的完整性，不影响正确性 —— 被截掉的 ghost 会在后续轮次重新进入需求集合，且截断按就近原则，与机器人施工顺序一致。

---

## 5. Mod 设置

| 名称 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `vsi-enabled` | per-player bool | true | 总开关 |
| `vsi-interval` | per-player int-setting (allowed: 5/15/30/60) | 15 | 主循环 tick 间隔 |
| `vsi-return-on-exit` | per-player bool | true | 离开载具时回流借出物品 |
| `vsi-require-roboport` | per-player bool | true | 关闭后不检查载具 roboport（纯手动共享场景） |
| `vsi-vehicle-types` | startup string ("spider" / "spider-and-car") | spider-and-car | 支持的载具范围 |
| `vsi-max-ghosts` | runtime-global int | 5000 | 单次扫描 ghost 上限 |

---

## 6. 数据结构（`storage`）

```lua
storage = {
  tracked_players = { [player_index] = true },
  cache = {
    [player_index] = {
      needs = { ["iron-plate/normal"] = { name=, quality=, count= } },
      dirty = true,
      last_scan_tick = 0,
      last_vehicle_pos = { x=, y= },
      vehicle_unit_number = 123,
    }
  },
  ledger = {
    [player_index] = { ["iron-plate/normal"] = { name=, quality=, count= } }
  },
}
```

迁移：`on_configuration_changed` 中对缺失字段补默认值，不做破坏性重建。

---

## 7. 文件结构

```
factorio-vehicle-shared-inventory/
├── info.json
├── settings.lua
├── control.lua              -- 事件注册 + 主循环
├── scripts/
│   ├── eligibility.lua      -- 载具/roboport 判定
│   ├── needs.lua            -- ghost 扫描与需求计算
│   ├── transfer.lua         -- 搬运与回流
│   └── util.lua             -- item key 编解码、平方距离等
├── locale/
│   ├── en/strings.cfg
│   └── zh-CN/strings.cfg
├── changelog.txt
├── README.md
└── SPEC.md
```

---

## 8. 边界情况清单

| 情况 | 处理 |
|---|---|
| 载具后备箱已满 | 部分搬运，节流打印提示，不报错 |
| 玩家在载具内死亡 | ledger 清空（物品已随尸体处理） |
| 载具被摧毁 | ledger 清空，`on_entity_died` 监听 |
| 换乘另一台载具 | 先对旧载具执行回流，再重建 cache |
| 多人游戏 | 全部状态按 `player_index` 隔离，无全局共享 |
| 玩家使用 remote 控制蜘蛛（非乘坐） | 不生效（`player.vehicle` 为 nil），明确不支持 |
| 载具跨星球（太空平台） | surface 变化触发 cache 失效重扫 |
| 物品带 quality | 全流程以 `{name, quality}` 为单位，不合并不同 quality |
| 蓝图中的 `items_to_place_this` 有多个候选 | 取第一个（与引擎行为一致） |
| roboport 无电 | 视为不满足前提，跳过 |

---

## 9. 兼容性

- **Spidertron Enhancements**：无冲突，功能互补。
- **Enhanced Remote Vehicle Control**：其"附身"模式下 `player.vehicle` 行为需实测，可能需要特判。
- **Vehicle Equipment Grids / Krastorio 2**：给汽车加 grid，正是本 mod 的目标场景，天然兼容。
- **AAI Vehicles / 模组蜘蛛**：按 prototype `type` 判定而非硬编码名字，自动支持。
- **Constructron-Continued**：其 Constructron 无玩家乘坐，不受影响。

---

## 10. 验收标准

1. 坐在蜘蛛里，背包有铁板，蜘蛛后备箱空，在机器人范围内放置传送带 ghost → 材料自动进入后备箱，机器人完成建造。
2. 铺地板 ghost（tile ghost）同样生效。
3. 离开蜘蛛 → 未消耗的借出材料自动回到玩家背包，蜘蛛原有物资不被拿走。
4. 空转（无 ghost）时，`/measured-command` 显示主循环耗时可忽略（目标 < 0.05 ms/tick）。
5. 多人游戏中两名玩家各自坐蜘蛛互不干扰。
6. 关闭 `vsi-enabled` 后完全无行为、无残留计时器。

---

## 11. 非目标（本版本明确不做）

- 火车车厢支持
- 远程遥控蜘蛛（非乘坐）时的共享
- 载具之间互相共享
- 修改建造机器人本身的取货逻辑（API 不允许）
- 弹药 / 燃料栏的自动补给（可作为 v2 功能）
