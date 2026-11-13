# Backup

Scripted, consistent backups where a file copy would not be enough (Nextcloud with Borg, the
Postgres instances, Vault in `secrets-vault/`), and Duplicati to take everything off-site.

## Nextcloud with Borg (`nextcloud-borg/`)

`backup_nextcloud_borg.sh` produces a consistent snapshot of files, config and database:

```mermaid
flowchart LR
    A["lock<br/>(flock)"] --> B["maintenance<br/>mode on"]
    B --> C["MariaDB dump<br/>(single transaction)"]
    C --> D["borg create<br/>data + config + dump"]
    D --> E["maintenance<br/>mode off"]
    E --> F["borg prune<br/>+ compact"]
    F --> G["notify<br/>(Telegram)"]
```

- **Maintenance mode for the whole run, on purpose:** files and database dump always match.
  Only the first full run is long (about 760 GB, mostly photos and videos). Later runs only
  read new and changed files thanks to Borg's files cache, so the downtime shrinks to minutes.
  Compression is `auto,zstd,3`: on that first run `lzma,6` saved only about 7 % and made the
  run CPU-bound. `auto` stores incompressible media uncompressed.
- **One fixed archive name, no timestamp:** in Borg 2, archives with the same name form a
  series, and both the files cache and `prune` work per series. My first version named every
  archive `nextcloud-<timestamp>`, so every run was a new series: the files cache never hit
  (every run re-chunked all 760 GB, about 4 hours) and `prune` never deleted anything. Borg
  stores the timestamp itself, and the archive ID is unique anyway.
- **Always leaves maintenance mode:** an EXIT trap turns maintenance mode off and cleans up the
  dump, even if a step in between fails.
- **No password on the command line:** the database root password stays inside the MariaDB
  container. The container's shell reads it from the Vault-provided file and passes it to
  `mariadb-dump` via `MYSQL_PWD`, so it never shows up in `ps`.
- **Failures are not swallowed:** the dump is piped to `gzip` on the host under
  `set -o pipefail`, then checked for size and gzip integrity before Borg runs.
- **Encrypted repository** (`repokey-aes-ocb`), initialized automatically on the first run.
- **Repository passphrase from Vault**, fetched before maintenance mode is switched on, so a
  sealed Vault fails the run without downtime. The script runs on the host, where Vault has no
  published port, so it uses the Vault CLI inside the Vault container. Its own AppRole
  (read-only on exactly one path) logs in with `role_id`/`secret_id` passed as JSON on stdin,
  never as arguments. An empty token aborts the run: otherwise the CLI would quietly fall back
  to a token file left over from an interactive admin login.
- **Telegram notification** on success and failure, sent from the EXIT trap so a crash is
  reported too. The bot token never appears on a command line, and a failed notification never
  fails the backup.
- Every log line also goes to the systemd journal (`logger -t backup-nextcloud`), which Alloy
  ships to Loki (see `observability/`), so backup results show up in Grafana. Tailing the log
  file directly would not work reliably: it is reset at the start of each run and trimmed by
  replacing it.

## Postgres (`postgres/`)

`backup_postgres.sh` dumps both Postgres instances every night: the Supabase database (update
pipeline, CrowdSec history) and the shared instance for Authentik, Gitea and Kestra. A daily
Kestra flow runs it on the host through the deploy wrapper and reports the result in Telegram.

- **`pg_dumpall`, not a copy of the data directory:** copying the files of a running Postgres
  does not give a consistent state, a dump does. It also contains the roles and every database
  of the instance.
- **Checked before it counts:** the exit status of the whole pipe, `gzip -t`, and the closing
  line that `pg_dumpall` only writes after a complete run. Only then is the temporary file
  renamed. A broken dump leaves nothing behind that looks like a backup.
- **One instance failing does not stop the other.** The report lists both, and the run fails if
  either did.
- Passwords stay inside the containers, files and directory are readable by root only.
  Retention is 14 days plus the Sunday dumps of 8 weeks, as for the Vault snapshots.

## Docker data: stop and start in order

The nightly Borg backup of `/opt/docker` stops the containers for a consistent copy (the script
itself is not part of this export). The first version restarted them all at once. One night
Kestra came up before its Postgres, failed with an unknown host, and the JVM hung instead of
exiting, so `restart: unless-stopped` never kicked in. Kestra was down for hours.

- **Apps stop first, databases last; databases start first.** The script waits until each
  database container reports healthy (at most 3 minutes) before it starts the apps. The error
  trap uses the same ordered start, so a failed backup does not reintroduce the race.
- **Telegram on every run**, like the Nextcloud backup: success, success with warnings, or
  failure with exit code and counts, sent from the EXIT trap so a crash is reported too.
- **Defense in depth in the app:** Kestra's entrypoint waits up to 5 minutes for Postgres
  before starting the JVM and otherwise exits with an error, so Docker restarts it
  (`update-pipeline/kestra/docker-compose.yaml`).

## Duplicati (`duplicati/`)

Web-UI-based, encrypted, deduplicated backups of the remaining data.

- The web UI password and the key that encrypts Duplicati's own database (backup passphrases,
  destination credentials) come from Vault (AppRole entrypoint, see `secrets-vault/`). The
  container refuses to start without the key rather than storing these secrets in plain text.
- It only sees `/data/backup`, mounted read-only: it copies backups off-site and cannot change them.
- Its own data folder is a bind mount, not the image's anonymous volume, so the job definitions
  are part of the Docker backup.
- Reachable from trusted networks only (`only-trusted`). There is deliberately **no Authentik** in front of it:
  Duplicati's new web UI handles its own login tokens, and the forward-auth layer raced with
  them, which caused intermittent authentication failures. The VPN plus Duplicati's own password
  turned out to be the stable combination.
- **Results are reported, not just stored.** Duplicati keeps its results in its own database;
  nothing shows up in `docker logs`. During a OneDrive outage the upload verification failed
  with HTTP 401 for hours, and only an e-mail said so. Now every job posts its result
  (`send-http-url`, format `Json`, level `all`, set per job) to a Kestra webhook
  ([`duplicati-report.yml`](duplicati/duplicati-report.yml)). Anything but `Success` goes to
  Telegram at once; every report updates a small state file per job, which the
  [weekly system check](../system-checks/) turns into an issue when a job has not succeeded for
  26 hours, failed during the week, or stopped reporting altogether. The receiver
  ([`duplicati-report.py`](duplicati/duplicati-report.py)) accepts JSON and form-encoded bodies
  and strips URLs, because the error texts contain signed download links of the backup target.

Hostnames and IP ranges are placeholders (`example.com`, RFC 5737 ranges).
