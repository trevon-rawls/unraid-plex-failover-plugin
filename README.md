# Plex Failover Supervisor

> Reliable automatic failover for Plex Media Server on Unraid.

---

## Overview
This project provides a lightweight failover system for Plex Media Server when running two Plex containers on Unraid.  
It assumes you are using the official Plex containers from `plexinc/pms-docker` or `plexinc/pms-docker:plexpass`.  
Other Plex containers may differ in internal service paths and could require adjustments.

Core features:
- **Automatic Failover**: Secondary Plex starts if the primary is down or in error.
- **Mode Control**: Force primary, force secondary, or auto via the `plex-mode` command.
- **Database Sync**: Keeps the secondary Plex database mirrored with the primary.
- **Heartbeat Logging**: Periodic status messages for clarity.
- **Error Detection**: Monitors Plex logs for configurable failure patterns.
- **Notifications**: Unraid UI notifications for failover and mode changes.

---

## Components
- `plex_failover_supervisor.sh`  
  Main supervisor loop. Runs continuously to monitor and control failover.

- `plex-mode.sh` / `plex-mode`  
  CLI utility to change or query failover mode (`auto`, `primary`, `secondary`, `status`).  
  Notifies Unraid when mode changes.

- `plex_db_sync.sh`  
  Safely synchronizes the Plex database between primary and secondary when the secondary is stopped.  
  Uses `rsync` with lock protection to prevent conflicts.

- `plex_env_setup.sh`  
  Prepares environment directories, log paths, and mode file defaults.

- `plex-failover.plg`  
  Unraid plugin descriptor for installation via the Community Applications system.

---

## Usage
1. **Install** via Unraid plugin manager (point to the `.plg` file).  
2. **Configure** container names inside the scripts (`PRIMARY_CONTAINER`, `SECONDARY_CONTAINER`).  
3. **Run supervisor** in background:  
   ```bash
   /boot/config/plugins/plex-failover/plex_failover_supervisor.sh &
