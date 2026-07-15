# Changelog

## v0.3.0

### Secure Roomba Pocket

- Added `roomba_pocket.lua` and `startup_pocket.lua` for Advanced Wireless/Ender Pocket Computers.
- Added secure controller pairing with a 12-character code and 90-second expiry.
- Added per-pocket HMAC-SHA256 keys, signed requests/responses, and sequence-based replay protection.
- Added Viewer, Operator, and Administrator roles enforced by the controller.
- Added local pocket PIN, salted PIN storage, idle locking, and configurable lock timeout.
- Added remote overview, workers, jobs/maps, test run, preflight, pause/resume, safe abort, logs, history, alerts, backups, relocation, security administration, and safe update.
- Added configurable alert severities and optional speaker notification when a speaker is present.

### Safety and recovery

- Added mandatory job preflight with version, protocol, dock, output, fuel, storage, tool, update, and position checks.
- Added one-layer test mode and required a passed test before full jobs at each physical hive site.
- Added explicit `confirmed`, `recoverable`, and `unknown` position confidence.
- Added conservative crash recovery from persisted layer-centre checkpoints.
- Added refusal to move automatically when position confidence is unknown.
- Added relocation mode which preserves maps/settings while clearing physical dock claims.
- Added explicit worker states for fuel, output, blockage, recovery, update, tool, modem, and compatibility problems.
- Safe update and relocation now require workers to be physically docked, position-confirmed, and unloaded.

### Operations and visibility

- Added fuel estimates in movement units and coal equivalents using 80 units per coal item.
- Fixed low-layer distribution so two layers with four turtles uses the first two docked workers rather than skipping dock order.
- Added job history and bounded event logs.
- Added controller backup creation, listing, and safe restore.
- Added remote backup create/restore for Administrator pockets.
- Added live stored-item counts to worker status and preflight.
- Rewrote the GitHub README with complete build, installation, pocket, recovery, relocation, fuel, update, and troubleshooting documentation.

### Updates

- Added separate program and protocol versions.
- Added v2 worker protocol while retaining legacy update reception for v0.2.3 migration.
- Added transactional installers for controller, worker, and pocket.
- Added temporary download files, syntax validation, `.old` backups, boot health manifests, repeated-start retry, and automatic rollback after two failed starts.
- Safe Pocket Update aborts work, waits for all assigned workers to dock and unload, updates the hive, then updates the pocket last.

## v0.2.3

- Added controller-triggered over-the-air worker updates.
- Updating the controller now sends update requests to known connected turtles before the controller reboots.
- Docked workers update immediately; busy or underground workers queue the update until they safely return to their dock.
- Added `[U] Update Hive` to the controller UI.
- Added `roomba update` as a one-command updater.
- Added worker update status, target version, failure reporting, rollback backups, syntax validation, and automatic reboot.
- Controller worker details now show each turtle's reported software version.
- v0.2.2 workers require one final manual worker installation to receive the over-the-air updater; later releases can be deployed from the controller alone.

## v0.2.2

- Removed per-block inventory snapshots and stack transfers.
- Restored fast native CC:Tweaked item stacking by keeping a storage slot selected.
- Added safe empty-fuel-station handling: workers return to dock and show RESTOCK FUEL STATION.
- Allowed remaining work to be restarted from the Workers menu after the fuel station is restocked.

## v0.2.1

- Replaced the static worker startup text with a live task, progress, fuel, storage, position, and error panel.

- Fixed one-item inventory fragmentation by following the slot that receives each mined drop.

- Added periodic merging of matching stacks in storage slots 2–16.

- Added interactive per-worker management menu.
- Added targeted status refresh, pause, resume, return-to-dock, retry, remaining-section restart, error clearing, and record removal.
- Added safe recover-and-retry flow that returns, unloads, and restarts from the selected worker's first incomplete layer.
- Added per-worker parking without aborting the whole job.
- Made ComputerCraft turtle/computer shaft obstructions recoverable and automatically resumable.
- Changed labels from assumed compass directions to physical controller side names.
- Fixed right-turn direction tracking being incremented twice.

## v0.2.0

- Complete replacement release without runtime patching.
- Added working pause, resume, abort, factory reset, fuel reserve, inventory protection, legacy import, safe dock state, and periodic checkpoints.
