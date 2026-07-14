# Changelog

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
