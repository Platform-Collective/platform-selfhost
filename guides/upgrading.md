# Upgrading (Docker Compose)

A safe, repeatable procedure for upgrading a Docker Compose deployment to a new
version, including a backup and a rollback path. This expands on the summary in the
[README](../README.md#updating-to-a-new-huly-version).

> [!CAUTION]
> Do **not** upgrade directly from a 0.6.x version to 0.7.x. Follow the dedicated
> migration steps in [`MIGRATION.md`](../MIGRATION.md) (especially the `v0.7.204`
> section) instead.

## 1. Review the migration notes

Open [`MIGRATION.md`](../MIGRATION.md) and read every section between your current
version and your target version. Some releases need config or service changes beyond
just bumping the image tag.

## 2. Take a backup

Always back up before upgrading. See [backup-restore.md](backup-restore.md).

```bash
./backup.sh
```

Note the backup directory it prints (for example `backups/huly-backup-20260630-141500`);
you will need it if you have to roll back.

## 3. Stop the stack (recommended for major upgrades)

```bash
docker compose down
```

## 4. Update the repository

```bash
git pull
```

## 5. Set the new version

Edit `.env` (or your config file) and update:

- `HULY_VERSION` to the target tag, for example `v0.7.423`.
- `DESKTOP_CHANNEL` to the same value without the leading `v` (for example `0.7.423`),
  if you use the desktop app.

Apply any additional changes called for in `MIGRATION.md`.

## 6. Pull and start

```bash
docker compose pull
docker compose up -d
```

## 7. Verify

```bash
docker compose ps          # all expected services running
docker compose logs -f account
```

Then open the app, sign in, and confirm your workspaces and recent data are present.
The search index may take a few minutes to rebuild after a restart.

## 8. Roll back (if the upgrade fails)

1. Set `HULY_VERSION` (and `DESKTOP_CHANNEL`) in your config back to the previous
   version.
2. Restore the backup taken in step 2:

   ```bash
   ./restore.sh backups/huly-backup-<timestamp>
   ```

3. Bring the stack back up:

   ```bash
   docker compose up -d
   ```
