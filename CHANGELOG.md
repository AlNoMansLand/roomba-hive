# Changelog

## v0.2.0

- Replaced all runtime patching with complete controller and worker files.
- Added working concurrent Pause and Resume.
- Added Abort recovery and controller force-close.
- Added `roomba reset` factory-reset command.
- Added five-item fuel reserve and automatic refuel trigger.
- Reserved slot 1 for fuel and selected slots 2-16 before digging.
- Preserved dock identity and labels after reboot.
- Kept logical assignments separate from physical dock occupancy.
- Added legacy map import.
- Reduced filesystem writes by checkpointing position periodically.
- Added installer syntax validation and atomic file replacement.
