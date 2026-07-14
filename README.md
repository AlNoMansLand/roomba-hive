# Roomba Hive v0.2.3

A coordinated CC:Tweaked excavation system for one Advanced Computer and up to four mining turtles.

This is a complete-source release. The installer downloads finished controller and worker programs directly; it does not use a runtime patcher.

## v0.2.3 highlights

- Updating the controller automatically updates known connected turtles.
- Docked workers download, validate, install, and reboot without opening their terminals.
- Busy or underground workers safely queue the update and install it after returning to their assigned dock.
- The controller UI now includes **U — Update Hive**.
- The shell command `roomba update` runs the same updater.
- Worker files are fully downloaded before replacement, syntax-checked, and backed up as `.old`.
- Failed downloads or installs leave the current worker program available and report `update_failed`.
- Controller worker details show each turtle's reported version and any pending update.

### One-time bootstrap

Workers running v0.2.2 or older do not yet understand the over-the-air update request. Install v0.2.3 manually on each turtle **one final time**. After every worker is on v0.2.3 or later, future releases can be installed by updating only the controller.

## Included features

- Live turtle status panel showing controller, dock, task, layer, progress, fuel, storage, position, and errors.
- One controller at the quarry origin.
- Up to four workers on the controller's front, right, back, and left sides.
- Closed-outline calibration and reusable map files.
- Legacy `roomba_map.db` import.
- Contiguous vertical layer assignments.
- Persistent dock identity and labels after reboot.
- Safe dock detection that cannot erase an active job.
- Shared fuel-station locking at logical coordinate `0,3,0`.
- Global and per-worker Pause/Resume.
- Global Abort with best-effort return through carved cells.
- Per-worker recovery, retry, and return-to-dock controls.
- Slot 1 reserved for fuel, with five fuel items preserved.
- Mining storage is restricted to slots 2–16; compatible drops use normal native stacking without per-block compaction.
- Five-second entity wait, exactly one attack, then stop and report.
- One-command hive update: `[U] Update Hive` or `roomba update` on the controller.
- Automatic over-the-air updates for workers running v0.2.3 or later.
- One-command factory reset: `roomba reset`.

## Files to upload

Upload or replace these files at the root of the GitHub repository:

```text
install.lua
roomba_controller.lua
roomba_worker.lua
roomba.lua
startup_controller.lua
startup_worker.lua
README.md
CHANGELOG.md
```

Delete obsolete patch files such as `patch_v012.lua`.

## Installation

Controller:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=023 controller
```

Every worker:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=023 worker
```

The installer preserves existing controller maps/state and worker dock state. For a clean device, run:

```text
roomba reset
```

Remote reset when the local command is unavailable:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=023 reset
```

## Automatic updates

After the one-time v0.2.3 worker installation, future updates require only the controller.

From the running controller UI:

```text
U
```

Confirm by typing:

```text
UPDATE
```

Or stop the controller UI and run:

```text
roomba update
```

The latest installer reads the controller's saved worker records and sends an update request over Rednet before replacing the controller files.

Worker behavior:

- Physically docked and idle workers update immediately.
- Busy workers store the target version and continue their current assignment.
- A queued update installs only after the worker is back at its assigned dock at `Y=0`.
- Offline workers cannot receive the request and must be updated later.
- A worker whose Lua program has fully crashed cannot receive an update until it is rebooted.
- Each worker downloads all replacement files, validates their Lua syntax, keeps `.old` backups, reports the result, and reboots itself.

The controller can reboot before the workers finish downloading; each accepted worker update is self-contained.

## Physical layout

The software internally calls the controller's front direction logical north. That is only a map coordinate system, not Minecraft's real compass direction.

Physical workers:

```text
Front worker: directly against controller front, facing outward
Right worker: directly against controller right, facing outward
Back worker:  directly against controller back, facing outward
Left worker:  directly against controller left, facing outward
```

The Advanced Computer remains logical coordinate `0,0,0`:

```text
0,3,0  shared fuel chest
0,2,0  open/pipe routing level
0,1,0  wireless or ender modem
0,0,0  Advanced Computer
```

Each worker needs a mining tool, wireless/ender modem, output chest directly above, a clear shaft below, and the clear outward route to the fuel chest.

## Controller controls

```text
D  Detect physically docked workers
C  Calibrate a map
I  Import a legacy map
J  Start a job
P  Pause the entire job
R  Resume the entire job
A  Abort the entire job
W  Open worker management
M  View maps
U  Update the controller and all connected workers
Q  Close controller UI
```

## Worker management

Press `W`, choose a worker number, then choose an action:

```text
1  Refresh / ping
2  Recover and retry remaining work
3  Return to dock and stop
4  Pause this worker
5  Resume this worker
6  Restart remaining work from dock / after fuel restock
7  Clear displayed error
8  Forget this worker record
0  Back
```

### Recover and retry

This is intended for errors such as an obstruction, protected block, or failed movement while the worker program is still running.

The worker:

1. Uses its in-memory carved route to return to the center or shaft.
2. Ascends to the dock.
3. Unloads slots 2–16.
4. Restarts at the first incomplete layer in its assigned section.

A partially mined layer is traversed again from the beginning, but air blocks are not re-mined. A turtle that rebooted underground cannot reconstruct its in-memory carved route and may still need manual recovery.

### Return to dock and stop

This parks only the selected worker. Other workers continue. The parked worker's unfinished layers remain incomplete and can later be restarted from the worker menu.

### Blocked waiting

When a ComputerCraft turtle or computer occupies the worker's next shaft block, the worker reports:

```text
blocked_waiting
```

It does not attack or crash. It checks once per second and continues automatically after the obstruction is removed. Pause, Return, and Abort remain available while it waits.

## Fuel and inventory

- Slot 1 is fuel-only.
- Slots 2–16 are mining storage.
- Normal refuelling keeps five fuel items in slot 1.
- At five items, the worker returns to the shared fuel chest.
- A non-fuel item in slot 1 is moved to an empty storage slot or reported safely.
- The worker keeps a normal storage slot selected and relies on CC:Tweaked’s native compatible-item stacking.
- No full-inventory scan or stack transfer occurs after each mined block.
- Inventory capacity is checked periodically and conservatively unloaded before it can run out of safe slots.
- If the station cannot restore slot 1 above five items, the worker returns to dock and displays **RESTOCK FUEL STATION**.
- After restocking, use Workers → option 6 to continue that worker's remaining layers.

## First acceptance test

1. Upload all v0.2.3 files.
2. Reinstall one controller and one worker.
3. Detect and calibrate a disposable small map.
4. Start a two-layer job.
5. Place another turtle temporarily above the active worker's shaft.
6. Confirm the worker reports `blocked_waiting` rather than crashing.
7. Remove the obstruction and confirm it continues automatically.
8. Test Workers → Return to dock and stop.
9. Test Workers → Restart remaining work from dock.
10. Test Workers → Recover and retry after a safe, deliberately created error.
11. Watch the worker's local screen and confirm status, layer, progress, fuel, and storage update live.
12. Mine several identical blocks and confirm they stack without a pause after every block.
13. Empty the shared fuel chest, let the worker attempt a refill, and confirm it returns to dock showing **RESTOCK FUEL STATION**.
14. Restock the chest and use Workers → option 6 to continue the unfinished section.
15. With the worker docked, run `U` on the controller and verify the turtle displays Installing update and reboots automatically.
16. Confirm Workers shows the updated worker version after it reconnects.

Minecraft and CC:Tweaked were not available in the build environment, so supervise this acceptance test before using a valuable quarry.
