# Roomba Hive v0.3.4

Roomba Hive is a coordinated quarry system for **CC:Tweaked**. One Advanced Computer manages up to four mining turtles, while an optional Advanced Wireless or Ender Pocket Computer provides a secure remote dashboard.

The project is designed around safe recovery rather than blind movement. Workers report their state, preserve fuel, queue updates until they are docked, and refuse automatic movement when their saved position is not trustworthy.

## What v0.3.4 changes

- Reformatted controller and pocket menus so each numbered action has its own row.
- Long action names wrap underneath their own number with indentation instead of running into the next option.
- The central column below the controller is now safely excavated when a worker enters or leaves it.
- Central-route excavation still refuses lava, ComputerCraft blocks, chests, barrels, shulker boxes, and detected inventories.
- Added controller, worker, and secure pocket emergency vertical recovery.
- Emergency recovery mines straight upward in the turtle's current column and stops at logical `Y=-1`.
- Emergency recovery saves after every vertical move and can be reissued after an interrupted Minecraft session.
- Added progress and failure tracking for multi-worker rescue.
- Fixed a completed Safe Update remaining stuck at `committing` after the new controller boots.
- No map, pairing, dock, or protocol reset is required.


## What v0.3.4 changes

- Repairs controller state saving after Minecraft is closed during an active quarry.
- Recovery, Abort, worker commands, and heartbeat processing no longer fail when runtime tables share references.
- No reset or recalibration is required.

## Core v0.3 features

- Secure Roomba Pocket application with pairing, signed commands, replay protection, permissions, local PIN locking, alerts, and remote administration.
- Safe remote update workflow for the workers, controller, and pocket.
- Mandatory preflight checks before every quarry job.
- One-layer test runs.
- Fuel estimates expressed in both movement units and coal equivalents at **80 fuel units per coal item**.
- Relocation mode that preserves maps and settings while clearing stale physical dock assignments.
- Conservative recovery checkpoints and position-confidence protection.
- Separate program and network-protocol versions.
- Transactional installation with automatic rollback after repeated failed starts.
- Job history, event logs, controller backups, and backup restore.
- Clear worker states for output, fuel, blockage, update, recovery, and compatibility problems.
- Detailed setup and operating documentation.

## System architecture

```text
Roomba Pocket
     |
     | authenticated remote commands
     v
Main Controller
     |
     | worker commands, status, jobs, fuel lock, updates
     v
1-4 Mining Turtles
```

The pocket never controls a turtle directly. The controller remains the single authority for maps, jobs, worker assignments, shared fuel access, safety checks, and update coordination.

---

# 1. Requirements

## Required hardware

- 1 Advanced Computer for the controller.
- 1 wireless or Ender modem attached to the controller.
- 1-4 mining turtles.
- 1 wireless or Ender modem equipped on every turtle.
- 1 output chest or compatible inventory directly above every turtle.
- 1 shared fuel chest above the controller.
- Fuel accepted by CC:Tweaked.
- A clear vertical shaft beneath each worker.

Advanced turtles are recommended because their colour screens make status messages easier to read, but the mining and networking logic is the important part.

## Optional hardware

- Advanced Wireless Pocket Computer for nearby remote control.
- Advanced Ender Pocket Computer for long-range or cross-dimensional control.
- Ender modem on the controller for use with an Ender Pocket Computer.
- Item pipes above the four output chests.
- Pipes that route suitable fuel from output storage into the shared fuel chest.
- Larger external storage connected to the output chests.

**Pipes are optional.** Roomba Hive never assumes a pipe exists and does not call pipe APIs. The layout merely leaves convenient space for players who want automatic item extraction or automatic fuel recycling.

## Software requirements

- CC:Tweaked with HTTP enabled.
- GitHub repository files uploaded at the repository root.
- Rednet-capable modem upgrades.

---

# 2. Physical build

## Controller coordinate system

The Advanced Computer is logical coordinate `0,0,0`.

```text
0,3,0  shared fuel chest
0,2,0  optional pipe/routing space
0,1,0  controller modem
0,0,0  Advanced Computer
```

CC:Tweaked names block sides from the computer block's own facing perspective. When you stand in front of the controller screen, the computer's technical `right` side is visually on your left, and its technical `left` side is visually on your right.

Roomba Hive therefore displays the sides as the player sees them:

```text
Technical front  -> Front / screen side
Technical right  -> Left side on screen
Technical back   -> Back / rear
Technical left   -> Right side on screen
```

The internal north/east/south/west dock identifiers remain unchanged for saved-map and movement compatibility. Only labels, menus, logs, and pocket displays use the corrected player-facing names.

## Top view at controller level, Y=0

Every turtle touches the controller and faces **away** from it.

```text
                         clear outward block
                                ^
                                |
                          [ FRONT TURTLE ]
                           faces outward
                                |
                                |
[clear] <- [ LEFT TURTLE ] [ CONTROLLER ] [ RIGHT TURTLE ] -> [clear]
              faces left                       faces right
                                |
                                |
                           [ BACK TURTLE ]
                            faces outward
                                |
                                v
                         clear outward block
```

The outward block beside each turtle must remain clear because the worker uses it to begin the fuel-station route.

## Top view of required blocks

```text
Legend:
C = controller
T = turtle
O = clear outward route

          O
          T
      O T C T O
          T
          O
```

## Side view through one worker

```text
Y=3             [ shared fuel chest at centre ]
                      ^ turtle sucks from side
                  [refuel approach position]

Y=2      optional pipe above output chest / routing space

Y=1             [output chest]       [controller modem]

Y=0      [clear] [worker turtle]     [controller]
                faces outward

Y=-1             quarry layer 1
Y=-2             quarry layer 2
Y=-3             quarry layer 3
...
```

The worker's fuel trip is:

1. Move one block outward at Y=0.
2. Move up three blocks.
3. Turn around.
4. Move one block inward.
5. Face the shared fuel chest at the centre and take fuel.
6. Reverse the same route to its dock.

The output chest above the turtle does not block this route because the turtle moves outward before ascending.

## Output chests and optional pipes

Each worker requires an inventory directly above it. Roomba Hive unloads mined items with `turtle.dropUp()`.

An optional item pipe may be placed above or connected to the output chest. Common uses include:

- Sending mined items to bulk storage.
- Filtering coal or charcoal toward the shared fuel chest.
- Keeping the local output chest empty during long jobs.

Roomba Hive only checks that an inventory exists above the turtle. Pipe speed, filters, and storage capacity are the player's responsibility.

## Quarry outline for calibration

The map outline is built on **layer 1**, which is one block below the controller level at Y=-1 relative to the hive.

- The outline must be closed.
- The area below the controller and each dock shaft must allow the calibration turtle to enter.
- The controller must remain in the same position and orientation relative to the outline whenever that saved map is reused.
- The perimeter walls should not contain gaps that allow the flood fill to escape.

---

# 3. Repository files

Upload these files directly to the root of `AlNoMansLand/roomba-hive`:

```text
install.lua
roomba_controller.lua
roomba_worker.lua
roomba_pocket.lua
roomba_crypto.lua
roomba_boot.lua
roomba.lua
startup_controller.lua
startup_worker.lua
startup_pocket.lua
README.md
CHANGELOG.md
```

Delete obsolete patch files such as:

```text
patch_v012.lua
roomba_reset.lua
```

Uploading a file with the same exact name and path replaces the current repository version in a new Git commit. Previous versions remain available in Git history.

---

# 4. Installation

## Clean controller installation

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=034 controller
```

## Clean worker installation

Run this on every turtle:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=034 worker
```

## Pocket installation

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=034 pocket
```

## Updating from v0.3.0 or later

The safest migration is:

1. Finish or safely abort the current quarry job.
2. Confirm all workers are physically docked.
3. Upload every v0.3.4 file to GitHub.
4. From the existing controller choose `Operations > Safe update hive`, or use `Quick Actions > Safe update hive` on an Administrator pocket. You may also stop the controller UI and run:

```text
roomba update
```

The installer broadcasts the update request before replacing the controller files. Each reachable worker downloads v0.3.4, validates it, installs it, and reboots. A pocket-initiated Safe Update updates the pocket last.

A worker that is offline or whose program has fully stopped cannot receive the request. Use the manual worker command above for that turtle.

## Factory reset

```text
roomba reset
```

Remote installer form:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=034 reset
```

Factory reset deletes programs, maps, jobs, backups, pairings, labels, and device state. It is **not** required for normal updates, relocation, or moving the quarry downward.

---

# 5. First-time setup

## Step 1: Start the devices

Power on the controller and all turtles. Workers without assignments display that they are waiting for dock detection.

## Step 2: Detect docks

On the controller press:

```text
D
```

The controller pulses each physical side and assigns the turtle receiving that pulse. A successful detection records:

- Worker computer ID.
- Physical controller side.
- Turtle label.
- Confirmed dock position.

The turtle must touch the controller and face outward so the controller's redstone pulse reaches the turtle's back.

## Step 3: Calibrate a map

Press:

```text
C
```

Choose one docked worker, name the map, and confirm calibration. The selected worker descends to layer 1, enters the centre, traces the closed perimeter, flood-fills the interior, saves the map on the controller, and returns.

Calibration does not mine every block in the quarry. It records the horizontal footprint that every later layer will use.

## Step 4: Optionally run a one-layer test

Press:

```text
T
```

The test run uses one worker and one layer. It verifies the map orientation, shaft, output chest, fuel route, return path, and basic inventory flow with limited risk.

The test is optional. Passing it records that the map has been checked at the current hive location, but an untested map may still start a full quarry after its normal preflight passes.

Relocation or backup restoration advances the controller's site generation and marks earlier test approval as no longer current. This is informational and does not block operation.

## Step 5: Start the full job

Press:

```text
J
```

Choose the map and number of layers. The controller performs preflight, displays the estimate, and refuses to start until all blocking problems are fixed.

---

# 6. Controller interface

The v0.3.4 home screen is intentionally small and groups related actions:

```text
1  Operations
2  Workers
3  Jobs & Maps
4  Maintenance
5  Remote & Security
6  Logs & History
0  Exit
```

## Operations

- Pause the active hive.
- Resume a paused hive.
- Safely abort active work.
- Safely update workers and the controller.

## Workers

Select a worker to inspect its status, fuel, storage, version, position confidence, and recovery choices.

## Jobs & Maps

- Start a quarry job.
- Run the optional one-layer safety test.
- Calibrate a new map.
- View saved maps.
- Import a legacy map.

## Maintenance

- Detect physical docks.
- Prepare and complete relocation.
- Create or restore controller backups.

## Remote & Security

Pair, rename, re-role, or revoke pocket computers and enable or disable remote access.

## Logs & History

View recent controller events and completed/aborted job history.

The old letter shortcuts are still accepted for experienced users, but they are no longer crowded onto the dashboard.

# 7. Preflight system

Every full job and test run starts with preflight. The controller checks each selected worker for:

- Matching program version.
- Matching protocol version.
- Recent network response.
- Physical dock occupancy.
- Confirmed position.
- Output inventory above the turtle.
- Valid fuel in slot 1.
- Minimum movement fuel.
- At least one empty mining-storage slot.
- No mined items left in the turtle.
- No pending update.
- Mining tool response when it can be checked without breaking a block.

Warnings do not always block a job. For example, a five-item fuel reserve produces a warning because the shared station must be stocked.

Preflight cannot prove that every future underground block or every modded machine will behave correctly. A one-layer test is strongly recommended, especially after calibration or relocation, but it is not required to start a full job.

---

# 8. Job distribution and layer meaning

Layer 1 is Y=-1 relative to the controller. Layer 2 is Y=-2, and so on.

Each layer is assigned whole to one turtle. A layer is never split horizontally between multiple workers.

Examples:

```text
2 layers + 4 workers = first 2 workers receive 1 layer each; 2 remain idle
4 layers + 4 workers = 1 layer per worker
8 layers + 4 workers = 2 contiguous layers per worker
10 layers + 3 workers = contiguous ranges distributed as evenly as possible
```

Contiguous ranges reduce unnecessary shaft travel and make recovery easier to understand.

---

# 9. Fuel estimates

The estimate includes:

- Approximate horizontal route movement.
- Descents and ascents for each layer.
- Dock transitions.
- Operational and recovery margin.
- An additional configurable safety multiplier, defaulting to 1.25.

The controller displays:

```text
Minimum movement units
Recommended movement units
Minimum coal-equivalent items
Recommended coal-equivalent items
```

Roomba Hive uses:

```text
1 coal item = 80 turtle fuel units
```

The estimate is deliberately conservative but is not a guarantee. Extra trips caused by inventory unloading, obstructions, recovery, or fuel-station access may increase actual use. Modded fuels can have different values; the item count shown is specifically a coal equivalent.

---

# 10. Fuel and inventory rules

## Slot layout

```text
Slot 1     fuel only
Slots 2-16 mined items and temporary station buffer
```

## Five-item reserve

During ordinary work, the turtle does not consume the final five fuel items in slot 1. Reaching five items causes a return-to-dock and fuel-station trip.

The reserve is an item count, while movement safety also uses the turtle's numeric fuel level. Both protections are required: five coal items alone do not prove the turtle already has enough loaded fuel to return from a deep layer.

## Emergency station return

Before leaving the dock for the shared station, the worker reserves enough movement fuel for the trip there and back. In an emergency it may consume more of the protected stack to avoid becoming stranded at the station.

## Empty fuel station

When the shared chest cannot provide fuel, the worker:

1. Stops waiting at the chest.
2. Reverses the fuel route.
3. Releases the shared fuel lock.
4. Returns to its own dock.
5. Displays `RESTOCK FUEL STATION`.
6. Leaves its unfinished layers incomplete.

After restocking, use the worker menu's restart option or the corresponding pocket command.

## Fuel types

The station may switch between valid CC:Tweaked fuels. A fresh stack is taken into a temporary empty storage slot, validated, and then moved into protected slot 1.

The shared fuel chest should contain fuel only. A non-fuel item is rejected and reported.

## Mining-item stacking

The worker keeps a normal storage slot selected and lets CC:Tweaked perform native compatible-item stacking. It does not scan and move stacks after every mined block.

Inventory capacity is checked periodically. The worker returns to unload before it runs out of safe collection space.

---

# 11. Worker management

Open `W`, choose a worker, then select an action:

```text
1   Refresh / ping
2   Recover and retry remaining work
3   Return to dock and stop
4   Pause this worker
5   Resume this worker
6   Restart remaining work from dock or after fuel restock
7   Clear displayed error
8   Forget an unused worker record
9   Recover from a saved centre checkpoint
10  Run preflight on this worker
0   Back
```

## Recover and retry

Use this when the worker program is still running and its current path is known. The worker attempts to return through carved cells, dock, unload, and restart from its first unfinished layer.

A partially mined layer may be traversed from its beginning. Already empty cells are passed through instead of mined again.

## Return to dock and stop

This parks only the selected worker. Other workers continue. Its unfinished layers remain available for a later restart.

## Recover checkpoint

This option is only enabled when the worker rebooted at an explicitly saved layer-centre anchor. It returns from that known centre to the assigned shaft and dock.

A worker with unknown position is never moved automatically.

---

# 12. Position confidence and crash recovery

Roomba Hive records one of three confidence levels:

| Confidence | Meaning | Automatic movement |
|---|---|---|
| `confirmed` | Worker is physically at its assigned dock. | Allowed |
| `recoverable` | Worker is at a deliberately saved layer-centre anchor. | Only checkpoint recovery is allowed |
| `unknown` | The program stopped during movement, the turtle was moved by a player, or state cannot be proven. | Refused |

Before leaving a known anchor, the worker saves an unsafe/unknown state. This is intentional. A crash between two blocks must not allow the turtle to assume a location that may be wrong.

When position is unknown:

1. Do not send automatic recovery commands.
2. Manually recover the turtle to a dock.
3. Place it against the correct controller side, facing outward.
4. Run Detect docks again.

This conservative behavior prevents a misplaced turtle from digging through the controller, chests, another shaft, or the quarry wall.

---

# 13. Recoverable and blocking states

| State | Meaning | Expected action |
|---|---|---|
| `blocked_waiting` | A ComputerCraft turtle/computer is occupying the next movement block. | Remove it; the worker retries automatically. |
| `output_full` | Items cannot be unloaded upward. | Clear or repair the output chest/pipe. |
| `fuel_station_empty` | Shared chest did not supply fuel. | Restock, then restart remaining work. |
| `waiting_fuel_lock` | Another turtle owns the shared station route. | Wait; lock is released when that worker leaves. |
| `recovery_required` | Worker rebooted with saved work but cannot continue blindly. | Inspect confidence and use checkpoint recovery or manual docking. |
| `position_unknown` | Saved coordinates are not trusted. | Manually dock and run detection. |
| `update_pending` | An update was received while the turtle was busy. | It installs automatically after safe docking. |
| `update_failed` | Download, validation, or installation failed. | Read the worker/controller error and retry later. |
| `incompatible` | Worker and controller network protocols differ. | Update the hive. |
| `tool_missing` | Mining tool could not be used. | Restore the normal mining upgrade. |
| `dock_conflict` | A side is already assigned to a different active worker. | Use relocation or remove the stale worker record. |
| `error` | A nonrecoverable condition stopped the operation. | Read the exact message before choosing recovery. |

Entities are handled separately: the turtle waits five seconds, attacks once, retries movement once, and then stops if the entity remains.

Water blocks are treated as passable and are not dug. Blocks whose registry name contains `lava` cause the worker to stop and report before entering the fluid. Modded fluids with unusual names should still be tested in the actual modpack before unattended operation.

---

# 14. Relocating the hive

Use relocation mode instead of factory reset.

## Moving the hive downward after a completed job

If the controller began at Y=100 and mined 20 layers:

```text
Layer 1  = Y=99
Layer 20 = Y=80
```

Move the controller level to Y=80. The next job's layer 1 is then Y=79, directly beneath the previous excavation.

## Relocation procedure

1. Finish or abort the active job.
2. Confirm every worker is docked and unloaded.
3. Press `L` on the controller, or use Pocket > Admin Tools > Prepare relocation.
4. Wait for every worker to acknowledge relocation readiness.
5. Break and move the controller, workers, chests, modem, and optional pipes.
6. Preserve the same relative layout and controller orientation when reusing the same map.
7. Start all devices.
8. Press `D` on the controller to detect the new physical docks.
9. Optionally run a new one-layer test; relocation marks the previous site approval as no longer current.

Relocation preserves:

- Maps.
- Configuration.
- Pocket pairings.
- Job history and logs.
- Backups.
- Worker records.

It clears physical occupancy and old dock claims so moved turtles do not produce stale dock conflicts.

---

# 15. Controller backups

Open `B` on the controller to:

```text
Create backup
Restore backup
List backups
```

Administrators may also create and restore backups from the pocket. A remote restore preserves the authenticated administrator pocket that performed it so the completion response and further recovery commands remain available.

A backup includes:

- Saved maps.
- Configuration.
- Security pairings.
- Job history.
- Event logs.
- Saved worker and dock assignments.

A backup deliberately does **not** restore:

- An active job.
- Physical dock occupancy.
- Shared fuel lock ownership.
- An old underground physical-position assumption.

After restoring a backup, the controller enters relocation-style safety and requires Detect docks before another job.

---

# 16. Job history and event logs

The controller retains up to:

```text
20 completed or aborted jobs
200 event-log entries
```

History records map, layer count, completed layers, result, start/end time, worker count, and whether it was a test run.

Logs record important events such as:

- Worker offline/online changes.
- Job start, completion, abort, and force close.
- Fuel-station warnings.
- Recovery actions.
- Pairing and revocation.
- Relocation.
- Backup creation/restore.
- Update preparation, success, or failure.

The pocket can view recent job history and controller logs remotely.

---

# 17. Roomba Pocket

## Hardware choice

A wireless pocket computer works while it remains within wireless range of the controller. For reliable distant or cross-dimensional operation, equip both the pocket and controller with Ender modems.

Worker turtles may continue using normal wireless modems because they remain close to the controller.

## Pairing

On the controller:

```text
S > Pair new pocket
```

Choose a permission role and name. The controller shows a 12-character code valid for 90 seconds.

On the pocket:

1. Start the installed pocket program.
2. Select Pair.
3. Choose or enter the controller computer ID.
4. Enter the displayed code.
5. Create a local pocket PIN.

The pairing code is used to derive a shared secret; the final secret is not broadcast as a plain Rednet message.

## Pocket home menu

The portrait display uses one vertical menu:

```text
1  Quick Actions
2  Workers
3  Jobs & Maps
4  Alerts & Logs
5  System
0  Lock Pocket
```

The home dashboard refreshes controller status automatically every five seconds. Quick Actions changes with the current job and permission role: it shows Pause while mining, Resume while paused, Safe Abort during active work, and Safe Update for Administrator pockets.

## Pocket worker controls

```text
Refresh
Pause
Resume
Return to dock
Recover and retry
Restart unfinished section
Recover saved checkpoint
Clear displayed error
```

Destructive or movement-sensitive commands require confirmation.

## Permission roles

| Role | Abilities |
|---|---|
| Viewer | Dashboard, workers, maps, history, logs, preflight/update status. |
| Operator | Viewer abilities plus jobs, pause/resume, abort, and worker controls. |
| Administrator | Operator abilities plus updates, relocation, backups, and security administration on the controller. |

Roles are enforced by the controller, not merely hidden in the pocket menu.

## Local PIN and idle lock

The pocket stores a salted hash of its PIN and locks after an idle timeout. The timeout can be changed from 30 to 3600 seconds in Pocket Security.

The local PIN discourages another player who picks up the pocket from immediately controlling the hive. A server administrator or player with direct filesystem access can still alter ComputerCraft files, so the PIN is not a substitute for server permissions.

## Alerts

The pocket records alerts for worker errors, fuel restocking, offline workers, job completion, relocation, backups, and updates.

Alert settings allow each severity to be enabled or disabled. A sound is attempted only when a speaker peripheral is available; the wireless modem upgrade may mean no speaker is present.

---

# 18. Remote security model

Remote commands use:

- A one-time pairing code.
- Per-pocket shared key.
- HMAC-SHA256 signatures.
- Strictly increasing request sequence numbers.
- Strictly increasing signed response sequence numbers.
- Controller-side role checks.
- Per-pocket revocation.

This protects against:

- Unpaired computers sending controller commands.
- Messages modified in transit.
- Captured commands being replayed later.
- One pocket pretending to be another paired pocket.
- View-only pockets issuing operator or administrator actions.

The messages are authenticated, not encrypted. Another player listening to Rednet traffic may be able to observe status or action names, but cannot create a valid signed command without the pairing key.

The controller may disable all remote control from its Security menu. Individual pockets may be renamed, re-roled, or revoked.

Workers accept ordinary job and update commands only from their saved controller. Controller reassignment is allowed during the physical dock-detection process.

---

# 19. Safe update system

## From the controller

Press:

```text
U
```

## From the pocket

Select:

```text
Safe Update
```

## Update sequence

1. The controller marks the update as preparing.
2. Active work is safely aborted.
3. Workers return through known paths.
4. Workers unload into their output inventories.
5. The controller waits until every assigned worker is online, physically docked, unloaded, and position-confirmed.
6. Blocking problems are shown instead of bypassed.
7. Final confirmation is requested.
8. Workers receive the update request.
9. The controller downloads and installs its own update.
10. The pocket updates last and reconnects after reboot.

## Transaction safety

For each device, the installer:

1. Downloads every required file to a temporary path.
2. Rejects empty downloads.
3. Syntax-validates every Lua file.
4. Preserves existing files as `.old` backups.
5. Commits all files as one update transaction.
6. Writes a boot manifest.
7. Reboots.
8. Waits for the new program to mark itself healthy.
9. Automatically retries and rolls back after two failed startup attempts.

A busy worker queues an ordinary update request and installs only after it is safely docked. The Safe Update workflow is stricter and waits for every assigned worker before committing.

---

# 20. Shell utility

The installer places `/roomba.lua`, allowing these commands:

```text
roomba update
roomba reset
roomba version
```

`roomba update` detects whether the device is a controller, worker, or pocket and runs the correct installer role.

---

# 21. Troubleshooting

## Dock conflict after moving the hive

Use relocation mode before moving. When the conflict already exists:

1. Confirm there is no active job.
2. Open Workers and forget only the stale worker record that no longer exists.
3. Reboot the involved devices if necessary.
4. Run Detect docks.

Do not factory-reset just to clear a dock conflict.

## Worker says `RESTOCK FUEL STATION`

Restock the shared chest with valid fuel, ensure its route is clear, then choose Restart remaining work from dock.

## Worker is blocked by another turtle

Remove the turtle/computer from the path. `blocked_waiting` retries automatically.

## Output chest is full

Clear the chest or repair the optional extraction pipe. The worker cannot finish unloading until upward transfers succeed.

## Worker is offline

Check power, modem, range, and whether the Lua program stopped. Reboot it. If its position becomes unknown, manually return it to a dock and detect again.

## Worker protocol is incompatible

Run Safe Update. A completely stopped/offline worker may require the manual worker installer.

## Pocket cannot find the controller

- Confirm the controller program is running.
- Confirm both modems are wireless/Ender types.
- Confirm range or use Ender modems.
- Enter the controller's numeric computer ID manually.
- Pair again from the controller Security menu.

## Update failed

Read the exact error. Common causes are disabled HTTP, GitHub connectivity, missing repository files, or an invalid Lua upload. The existing release should remain available through the transaction backup or rollback system.

## Position unknown

Do not force an underground movement command. Manually recover the turtle to its dock and run Detect docks.

---

# 22. Recommended acceptance test

Before using valuable terrain:

1. Build the controller with one worker and small output chest.
2. Install v0.3.4 on controller and worker.
3. Detect the dock.
4. Calibrate a small disposable closed outline.
5. Run preflight and confirm the 80-units-per-coal estimate appears.
6. Optionally run the one-layer test.
7. Confirm identical drops stack normally without a delay after every block.
8. Fill several storage slots and confirm the worker unloads.
9. Empty the fuel station and confirm the worker returns showing `RESTOCK FUEL STATION`.
10. Restock and restart unfinished work.
11. Temporarily block the shaft with another ComputerCraft turtle and confirm `blocked_waiting` resumes after removal.
12. Test Pause, Resume, Return, Recover/retry, and Safe Abort.
13. Pair one pocket as Viewer and verify control commands are denied.
14. Pair another as Administrator and test remote Pause/Resume.
15. Create and list a backup.
16. Test relocation on the disposable build.
17. Run Safe Update and verify worker, controller, and pocket reconnect.
18. Inspect job history, alerts, and logs.

Minecraft and CC:Tweaked were not available in the build environment. The included source has automated syntax, crypto, mock-load, fuel-reserve, distribution, estimate, and rollback checks, but physical turtle movement and modpack-specific behavior still require this supervised in-game acceptance test.

---

# 23. Design limits

- Roomba Hive does not protect against server administrators editing ComputerCraft files.
- Authentication does not encrypt Rednet traffic.
- A physically moved underground turtle cannot always determine its new position.
- Fuel estimates cannot predict every obstruction or unload trip.
- Optional pipes and modded inventories may have their own rate limits or side rules.
- Modded blocks may reject turtle mining or have unusual drops.
- Normal built-in mining-turtle behavior is preserved, including its standard non-durability-consuming mining upgrade. No enchanted-tool datapack is included with this release.

Roomba Hive prioritises stopping safely over continuing when its assumptions cannot be proven.


## Emergency vertical recovery

Use this only when ordinary Abort or checkpoint recovery cannot return an underground turtle.

From the controller:

```text
Operations
Emergency surface recovery
```

From an Administrator pocket:

```text
Quick Actions
Emergency surface recovery
```

The worker:

1. Remains in its current horizontal column.
2. Calculates the distance to logical `Y=-1`.
3. Consumes emergency fuel when needed.
4. Mines ordinary blocks directly above it.
5. Saves its position after every upward movement.
6. Stops at logical `Y=-1`, one block below the controller's level.
7. Waits to be physically retrieved or repositioned.

It stops instead of breaking:

- lava;
- turtles and computers;
- chests, barrels, shulker boxes, and detected inventories;
- unbreakable blocks;
- any route for which its storage or fuel is insufficient.

This mode abandons unfinished work and does not move the turtle horizontally back to its dock. After retrieving the turtles, place them at the controller, run Detect docks, and start a new job or restart unfinished layers as appropriate.
