# Backup and Restore (Docker Compose)

This guide covers backing up and restoring a Docker Compose deployment. For
Kubernetes, the Helm chart ships scheduled backups under
`helm/huly/templates/backup/` instead.

> [!IMPORTANT]
> Always take a backup **before upgrading** to a new version. See `MIGRATION.md`.

## What gets backed up

| Data | Source | Included by default |
|---|---|---|
| Database | CockroachDB volume (`cr_data`) | Yes |
| Files / attachments | MinIO volume (`files`) | Yes |
| Config and secrets | `.env`, `huly*.conf`, `nginx.conf`, `.huly.secret`, `.cr.secret`, `.rp.secret`, `traefik/` | Yes |
| Legacy database | MongoDB volume (`mongodb`), if present | Yes, when detected |
| Search index | Elasticsearch volume (`elastic`) | No - rebuilt automatically |
| Event log | Redpanda volume (`redpanda`) | No - transient |

The search index and event log are intentionally skipped: they are regenerated from
the database and file store, so excluding them keeps backups small and restores fast.
Use `--full` if you want them included anyway.

## Backup

`backup.sh` takes a **cold** snapshot: it stops the stack so the copy is
crash-consistent, archives the data volumes, copies your config, and restarts the
stack. Expect a short period of downtime for the duration of the snapshot.

```bash
./backup.sh                 # back up to ./backups/huly-backup-<timestamp>/
./backup.sh --output=/mnt/backups
./backup.sh --keep=7        # keep only the 7 most recent backups
./backup.sh --full          # also include the search index and event log
```

Each backup is a self-contained directory:

```
backups/huly-backup-20260630-141500/
  cockroach.tar.gz
  files.tar.gz
  config/
    .env
    huly_v7.conf
    nginx.conf
    ...
  manifest.txt
```

Copy that directory off the server (to object storage or another host) for real
disaster recovery - a backup that lives only on the same disk as the deployment is
not a backup.

## Restore

> [!WARNING]
> Restoring **replaces** the current data volumes and overwrites local config files.
> Test a restore on a clean or non-production environment before you need it for
> real.

```bash
./restore.sh backups/huly-backup-20260630-141500
./restore.sh backups/huly-backup-20260630-141500 --yes   # skip the confirmation prompt
```

`restore.sh` creates the stack's volumes if they do not exist, writes the archived
data back into them, restores the config files, and starts the stack. The search
index rebuilds automatically over the first few minutes after start.

## Verifying a backup

A backup you have never restored is a guess, not a backup. Periodically:

1. Spin up a throwaway host (or a separate project directory).
2. Run `restore.sh` against a recent backup there.
3. Confirm you can log in and see your workspaces.

## Notes

- Run these scripts from the repository root, next to `compose.yml`.
- They use only `docker`, `docker compose`, and a temporary `alpine` container, so
  there is nothing extra to install.
- For zero-downtime logical backups, a future enhancement could mirror the hot
  CockroachDB dump and `rclone` file sync already used by the Helm CronJobs.
