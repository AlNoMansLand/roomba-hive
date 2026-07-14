# Roomba Hive v0.2.0

A coordinated CC:Tweaked excavation system for one Advanced Computer and up to four mining turtles.

This release is a **complete replacement build**. It does not use `patch_v012.lua` or modify old source code at runtime.

## Included features

- One controller at the quarry origin.
- Up to four workers assigned to north, east, south, and west shafts.
- Closed-outline calibration and reusable map files.
- Legacy `roomba_map.db` importing from the controller menu.
- Contiguous vertical layer assignments.
- Persistent dock identity and turtle labels after reboot.
- Separate logical dock assignments and physical dock occupancy.
- Safe dock detection that cannot erase an active job.
- Shared fuel-station lock at logical coordinate `0,3,0`.
- Working Pause and Resume while turtles are actively mining.
- Abort with best-effort return through already carved cells.
- Force-close option when a crashed worker cannot acknowledge Abort.
- Slot 1 reserved for fuel; mining uses only slots 2-16.
- Five fuel items are preserved in slot 1.
- Automatic refuel trip when slot 1 reaches five items.
- Five-second entity wait, one attack, one final movement attempt, then stop.
- One-command factory reset: `roomba reset`.
- Periodic position checkpointing instead of saving after every movement.

## Files to upload

Replace or upload these files directly at the root of the GitHub repository:

```text
install.lua
roomba_controller.lua
roomba_worker.lua
roomba.lua
startup_controller.lua
startup_worker.lua
README.md
```

The old `patch_v012.lua` and `roomba_reset.lua` are no longer required. They may be deleted from GitHub after the new files are uploaded.

## Installation

Controller:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=020 controller
```

Every worker:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=020 worker
```

The installer preserves existing controller maps/state and worker dock state. It backs up the previous program as `.old` before replacing it.

For a completely fresh installation, run this first:

```text
roomba reset
```

Or remotely factory-reset without a working local installation:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=020 reset
```

## Base layout

The Advanced Computer is logical coordinate `0,0,0`.

```text
0,3,0  shared fuel chest
0,2,0  open/pipe routing level
0,1,0  wireless or ender modem
0,0,0  Advanced Computer
```

Workers at Y=0:

```text
North:  0,0,-1 facing north
East:   1,0,0  facing east
South:  0,0,1  facing south
West:  -1,0,0  facing west
```

Each worker needs:

- Mining tool upgrade.
- Wireless or Ender Modem upgrade.
- Output chest directly above it at Y=1.
- Optional extraction pipe above the output chest at Y=2.
- Clear vertical shaft directly below.
- Clear block one step outward.
- Clear outward ascent column from Y=0 to Y=3.
- Clear approach block beside the central fuel chest.
- Valid stackable fuel in slot 1 for initial setup.

The shared fuel chest must contain valid turtle fuel only.

## Controller controls

```text
D  Detect physically docked workers
C  Calibrate and save a new map
I  Import a legacy map database
J  Start an excavation job
P  Pause active workers at their next safe movement boundary
R  Resume a paused job
A  Abort the job or force-close an unresponsive abort
W  View worker status and errors
M  View saved maps
Q  Close the controller UI
```

### Pause

Pause is processed concurrently while workers mine. A worker finishes its current atomic turtle action, then waits without advancing the route. Resume continues from the same route position.

### Abort

A live worker attempts to:

1. Stop at the next safe movement boundary.
2. Travel through already carved cells to the map center.
3. Return to its assigned shaft.
4. Ascend to the dock.
5. Unload slots 2-16.
6. Release the fuel-station lock.
7. Clear its job state and report that it is docked.

If a worker's Lua program has already crashed, Abort is still useful because this release leaves the command listener running after most task errors. Pressing Abort can recover from many error states without rebooting.

A worker that rebooted underground cannot reliably reconstruct its carved route. Such a worker still requires manual recovery. If the controller waits forever for it, press Abort again and type `FORCE` to close the controller job state.

## Fuel and inventory behavior

- Slot 1 is fuel-only.
- Slots 2-16 are mining storage.
- The worker selects an empty storage slot before every dig.
- When slots 2-16 have no empty slot, it unloads before digging again.
- Normal refuelling never consumes the final five fuel items in slot 1.
- Reaching five items triggers a refuel trip.
- Emergency fuel handling may consume below five only if required to escape the fuel station, but it keeps at least one item where possible.
- A non-fuel item found in slot 1 is moved into an empty storage slot; the worker stops if it cannot move it safely.

## Hazard behavior

- **Entities:** wait five seconds, attack exactly once, attempt movement once, then stop and report.
- **Computers/turtles/inventories:** protected and not deliberately mined.
- **Sand/gravel:** repeatedly dug up to a safety limit.
- **Undiggable blocks:** stop and report coordinates.
- **Water:** workers continue; the excavation may flood.
- **Lava:** standard turtle inspection cannot reliably detect every fluid source before entering it. Supervise lava-prone jobs.

## Testing order

Use a disposable quarry for the first test:

1. Upload all replacement files.
2. Factory-reset one controller and one turtle.
3. Install both with the v0.2.0 commands.
4. Detect the single dock.
5. Calibrate a small 5x5 or 7x7 interior.
6. Start a one-layer job.
7. Test Pause and Resume.
8. Start another small job and test Abort.
9. Confirm slot 1 never receives mined blocks and refuelling begins at five fuel items.
10. Add the other workers only after the single-worker test succeeds.

## Validation performed outside Minecraft

All included Lua files were parsed successfully with a Lua parser. The project cannot be fully executed against CC:Tweaked's turtle, modem, rednet, filesystem, and peripheral APIs in this environment, so the first in-game run should still be supervised.
