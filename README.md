# Roomba Hive v0.1.2 upgrade

Upload these three files to the root of your GitHub repository:

- `install.lua` (replace the existing installer)
- `patch_v012.lua` (new file)
- `roomba_reset.lua` (new file)

Keep the existing `roomba_controller.lua`, `roomba_worker.lua`,
`startup_controller.lua`, and `startup_worker.lua`. The v0.1.2 installer
downloads the existing v0.1.1 source and applies the patch automatically.

## Reinstall/update

Controller:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=012 controller
```

Each worker:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=012 worker
```

The installer preserves the old installed program as `.old` and the patcher
also keeps a `.v011` backup.

## Factory reset

After v0.1.2 is installed, run this single command on any controller or worker:

```text
roomba-reset
```

Alternatively, without installing first:

```text
wget run https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua?v=012 reset
```

A factory reset deletes `/roomba`, `/startup.lua`, the label, maps, and state.

## v0.1.2 behavior

### Pause

Pause is now read while a worker is actively mining, rather than only while the
worker is idle. The turtle stops at the next safe movement boundary, sends
paused heartbeats, and resumes from the same route position.

### Abort

Press `A` on the controller and type `ABORT`.

A live worker:

1. Stops at the next safe movement boundary.
2. Uses already carved cells to return to the center.
3. Returns to its assigned shaft.
4. Ascends and unloads slots 2-16.
5. Releases the shared fuel lock if needed.
6. Reports that it aborted and remains docked.

Abort cannot control a turtle whose Lua program has already crashed or exited.

### Fuel slot protection

- Slot 1 remains fuel-only.
- Five fuel items are always preserved in slot 1.
- Once slot 1 reaches five items, the turtle returns to refuel.
- Digging selects slots 2-16 first.
- The turtle refuses to dig when storage slots 2-16 cannot accept items.
- Unloading still leaves slot 1 untouched.

Use solid stackable fuel such as coal or charcoal.
