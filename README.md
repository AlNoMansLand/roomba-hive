# Roomba Hive v0.1.0

A multi-turtle CC:Tweaked excavator based on the proven single-turtle `roomba.lua` calibration and sweep design.

## Status

This is the first implementation build. Test it in a small disposable quarry before trusting it with a large excavation. The package has not yet been executed inside Minecraft in this environment.

## Required base layout

Logical center is the Advanced Computer at `0,0,0`.

- `0,1,0`: wireless or ender modem attached to the controller.
- `0,3,0`: shared fuel inventory containing fuel only.
- Layer 1 is `Y=-1`.

Workers at Y=0:

- North: `0,0,-1`, facing north.
- East: `1,0,0`, facing east.
- South: `0,0,1`, facing south.
- West: `-1,0,0`, facing west.

Each worker has:

- An output inventory directly above it at Y=1.
- Its extraction pipe above that at Y=2.
- A clear shaft directly below it.
- A clear block one step outward, and a clear vertical route from there to Y=3.
- A mining tool upgrade and wireless/ender modem upgrade.
- Slot 1 reserved for fuel.

## Installation

Upload these files to a raw-file host such as GitHub:

- `install.lua`
- `roomba_controller.lua`
- `roomba_worker.lua`
- `startup_controller.lua`
- `startup_worker.lua`

Edit `BASE_URL` inside `install.lua` to the directory containing those raw files.

Controller:

```text
wget run <raw install.lua URL> controller
```

Every worker:

```text
wget run <raw install.lua URL> worker
```

The installer creates `/startup.lua`, so the program launches after every reboot.

## First test

1. Build the base and place one worker, not all four.
2. Install controller and worker.
3. Start both devices.
4. On the controller press `D` to detect docks.
5. Build a small closed outline on Y=-1, with a clear interior.
6. Press `C` to calibrate and save it.
7. Press `J`, choose one or two layers, and supervise the entire run.
8. Add the remaining workers only after the single-worker test succeeds.

## Hazard behavior

- Water: the worker continues; the excavation may flood.
- Lava: current v0.1 does not yet have reliable fluid-source detection. Supervise lava-prone jobs.
- Entity: wait 5 seconds, attack exactly once, retry once, then stop and report.
- Inventories, computers and turtles: protected and never deliberately mined.
- Falling blocks: repeatedly mined up to a safety limit.
- Undiggable blocks: stop and report.

## Important v0.1 limitations

- Fixed contiguous layer sections are assigned to up to four docked workers.
- Do not add extra workers to an occupied shaft.
- Worker recovery data is written locally, but automatic mid-route resume after a reboot is not enabled yet. A reboot underground should be treated as manual recovery.
- Normal wireless modems may lose range underground. Ender modems are strongly recommended for deep jobs.
- The shared fuel chest must contain valid turtle fuel only.
- The pipe system is external to CC:Tweaked and is not controlled by this program.
- The controller-side orientation assumes its `front/right/back/left` correspond to north/east/south/west. Place and orient the controller accordingly.

## Files

- `roomba_controller.lua`: controller UI, dock detection, map storage, sections, locks and worker status.
- `roomba_worker.lua`: docking, calibration, route generation, mining, unloading and refuelling.
- `install.lua`: one-command installer.
- `original_roomba.lua`: original working single-turtle program retained as a reference/fallback.
