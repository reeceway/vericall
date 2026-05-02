# Vicall Control-Plane Backup And Failsafe Runbook

## Current Fly storage model

- Fly app: `vericall-twilio-voice`
- Fly volume: `vericall_data`
- Fly volume id: `vol_vjyk8mqw92m5g99v`
- Mounted path in the app: `/data`
- Live control-plane DB: `/data/vericall_control.db`
- Live device bindings file: `/data/vericall_device_bindings.json`
- Current deployment model: single Fly machine with one mounted volume

This means the live SQLite file is durable across deploys on the same volume, but it is still a single-machine storage topology. Local CSV exports and local iPhone call history are not backups.

## What changed in code

- SQLite connections now force:
  - `PRAGMA foreign_keys = ON`
  - `PRAGMA journal_mode = WAL`
  - `PRAGMA synchronous = FULL`
  - `PRAGMA busy_timeout = 30000`
  - `PRAGMA wal_autocheckpoint = 1000`
- A real backup script now creates a consistent backup using SQLite's backup API instead of copying the live DB file directly.
- A validation script now checks backup readability, required schema, and table counts.
- A small admin health endpoint now reports DB durability settings and the latest successful local backup manifest:
  - `GET /admin/storage/health`

## Local backup behavior

By default backups are written to:

- `VICALL_BACKUP_DIR=/data/backups`

Each successful run creates:

- `control-plane-backup-<timestamp>.sqlite3.gz`
- `control-plane-backup-<timestamp>.manifest.json`
- `control-plane-backup-latest.json`

The manifest includes:

- UTC timestamp
- source DB path
- local backup path
- SHA256 of the compressed artifact
- compressed and uncompressed size
- counts for the key control-plane tables
- latest `updated_at` / `completed_at` style timestamps where available

## Environment variables

Required for normal local backup:

- `VICALL_CONTROL_DB_PATH`
- `VICALL_BACKUP_DIR`
- `VICALL_BACKUP_RETENTION_DAYS`

Optional for offsite backup upload:

- `VICALL_BACKUP_BUCKET`
- `VICALL_BACKUP_PREFIX`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `AWS_ENDPOINT_URL`

Suggested defaults:

- `VICALL_CONTROL_DB_PATH=/data/vericall_control.db`
- `VICALL_BACKUP_DIR=/data/backups`
- `VICALL_BACKUP_RETENTION_DAYS=30`

## Manual pre-deploy snapshot steps

Before a risky deploy, create a Fly volume snapshot first:

```bash
fly volumes snapshots create vol_vjyk8mqw92m5g99v --app vericall-twilio-voice
fly volumes snapshots list vol_vjyk8mqw92m5g99v --app vericall-twilio-voice
```

To increase automatic snapshot retention from 5 days to 30 days:

```bash
fly volumes update vol_vjyk8mqw92m5g99v --app vericall-twilio-voice --snapshot-retention 30 --scheduled-snapshots
```

Recommendation: move retention to 30 days before trusting snapshots as a real rollback layer.

## Manual backup commands

### Run directly on a machine that has the volume mounted

If you are already inside the Fly machine or another host with `/data` mounted:

```bash
cd /app
python3 scripts/backup_control_plane_db.py --pretty
```

### Run remotely from an operator workstation with `flyctl`

```bash
fly ssh console -a vericall-twilio-voice -C "cd /app && python3 scripts/backup_control_plane_db.py --pretty"
```

### One-command operator helper

From the repo:

```bash
twilio_voice_service/scripts/run_fly_control_plane_backup.sh
```

That helper will:

1. create a Fly snapshot
2. run the backup script remotely inside the machine
3. validate the produced backup remotely

## Manual validation commands

Validate a specific backup artifact:

```bash
cd /app
python3 scripts/validate_control_plane_backup.py /data/backups/control-plane-backup-YYYYMMDDTHHMMSSZ.sqlite3.gz --pretty
```

Remote version from an operator workstation:

```bash
fly ssh console -a vericall-twilio-voice -C "cd /app && python3 scripts/validate_control_plane_backup.py /data/backups/control-plane-backup-YYYYMMDDTHHMMSSZ.sqlite3.gz --pretty"
```

## Restore onto a new Fly volume or machine

This is a stop-the-world operation. Do not restore over a DB that is still being written to.

1. Create a fresh Fly volume and attach it to the replacement machine.
2. Put the machine in a maintenance window so no writes are happening.
3. Copy the chosen validated backup artifact onto the replacement machine's `/data/backups` directory.
4. Validate it on the replacement machine:

```bash
cd /app
python3 scripts/validate_control_plane_backup.py /data/backups/control-plane-backup-YYYYMMDDTHHMMSSZ.sqlite3.gz --pretty
```

5. Restore the SQLite main DB file while the app is stopped:

```bash
cd /data
cp vericall_control.db vericall_control.db.pre_restore_$(date +%Y%m%dT%H%M%S) 2>/dev/null || true
gzip -dc /data/backups/control-plane-backup-YYYYMMDDTHHMMSSZ.sqlite3.gz > /data/vericall_control.db.restored
mv /data/vericall_control.db.restored /data/vericall_control.db
rm -f /data/vericall_control.db-wal /data/vericall_control.db-shm
```

6. Start the app again.
7. Immediately hit the storage health endpoint and confirm the DB reopened in WAL mode:

```bash
curl -H "x-admin-key: <ADMIN_KEY>" https://vericall-twilio-voice.fly.dev/admin/storage/health
```

## What is and is not a backup

Real backups:

- Fly volume snapshots
- `backup_control_plane_db.py` artifacts in `/data/backups`
- offsite uploads created from those artifacts

Not backups:

- CSV exports from the portal
- local iPhone call history
- browser screenshots
- Twilio logs without the control-plane DB

## Recommended operating practice

Minimum safe posture:

1. Turn on 30-day Fly snapshot retention.
2. Run the SQLite backup script on a schedule.
3. Upload the compressed backup + manifest offsite.
4. Validate at least one recent backup per week.
5. Take a manual Fly snapshot before deploys that touch billing, usage, or call-state code.
