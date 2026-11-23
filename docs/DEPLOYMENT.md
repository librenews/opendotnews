# Open.News Production Deployment Guide

Open.News ships as a standard Docker image built from [Dockerfile](../Dockerfile) and configured **exclusively via environment variables**.

- **Reference deployment:** **Kamal 2** on a single Ubuntu 24.04 VPS running 4 separate containers (`web`, `worker`, `postgres`, `redis`) behind **Kamal Proxy** (automatic Let's Encrypt HTTPS).
- **Portable PaaS deployments:** The exact same Docker image runs unmodified on **Railway**, **Render**, **Fly.io**, or any container host.

---

## 1. Architecture on a Single Ubuntu VPS (Kamal 2)

```text
Internet (HTTPS :443 / HTTP :80)
          |
     Kamal Proxy (automatic Let's Encrypt TLS)
          |
     web container (Puma + Thruster, port 80, runs db:prepare on boot)
          |
   +------+------+-------------------------+
   |             |                         |
worker container |                  postgres container (postgres:17-alpine)
(Sidekiq + cron) |                  host volume: /var/lib/opendotnews/postgres
   |             |                         |
   +------+------+                  off-host pg_dump backups (S3/R2/B2/Spaces)
          |
   redis container (redis:7-alpine, AOF + noeviction)
   host volume: /var/lib/opendotnews/redis
```

**Authoritative storage rule:** PostgreSQL is the sole authoritative store. Redis holds only Sidekiq queues (with AOF persistence enabled to minimize restart disruption); if Redis is ever wiped, the transactional `outbox_events` and `feeds.next_fetch_at` tables recover all pending work automatically.

---

## 2. Ubuntu 24.04 VPS Preparation

1. Create an Ubuntu 24.04 VPS (minimum recommended: 2 vCPU, 2–4 GB RAM, 40+ GB SSD) and point your DNS `A` / `AAAA` record for `open.news` (or your domain) at the VPS IP.
2. Create a non-root `deploy` user with SSH key access and Docker permissions, and configure UFW firewall to expose **only ports 22, 80, and 443**:
   ```bash
   sudo ufw allow OpenSSH
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw enable
   ```
3. Create persistent host data directories for PostgreSQL, Redis, and local backup staging:
   ```bash
   sudo mkdir -p /var/lib/opendotnews/{postgres,redis,backups}
   sudo chown 70:70 /var/lib/opendotnews/postgres   # postgres:17-alpine uid/gid
   sudo chown 999:999 /var/lib/opendotnews/redis    # redis:7-alpine uid/gid
   sudo chmod 700 /var/lib/opendotnews/backups
   ```
   *(Kamal 2 installs Docker automatically during `kamal setup` if not already installed.)*

---

## 3. Configure Secrets & Deploy with Kamal 2

Install Kamal 2 locally (`gem install kamal`), then prepare secrets:

```bash
cp .kamal/secrets.example .kamal/secrets
```

Generate fresh production secrets (never commit `.kamal/secrets` or `config/master.key`, and back them up in your password manager — **losing `ACTIVE_RECORD_ENCRYPTION_*` or `RAILS_MASTER_KEY` makes encrypted secrets unrecoverable**):

```bash
bundle exec rails secret                         # -> SECRET_KEY_BASE
bundle exec rails db:encryption:init             # -> ACTIVE_RECORD_ENCRYPTION_*
openssl rand -hex 24                             # -> POSTGRES_PASSWORD
```

Create a GitHub Personal Access Token (`write:packages`, `read:packages`) for `ghcr.io/librenews/opendotnews` as `KAMAL_REGISTRY_PASSWORD`.

### First deploy (`kamal setup`)

```bash
export KAMAL_HOST="203.0.113.10"
export APP_HOST="open.news"
# Export secret env vars referenced by .kamal/secrets, then:
kamal setup
```

`kamal setup` will:
1. Build and push the Docker image to `ghcr.io/librenews/opendotnews`.
2. Start the `postgres` and `redis` accessory containers with persistent volumes.
3. Start **Kamal Proxy** with automatic Let's Encrypt HTTPS for `$APP_HOST`.
4. Boot `web` (running `./bin/rails db:prepare` and verifying `/health/live`) and `worker` (Sidekiq + `sidekiq-cron`).

### Subsequent zero-downtime deploys

```bash
KAMAL_HOST="203.0.113.10" APP_HOST="open.news" kamal deploy
```

### Day-2 Ops Commands

```bash
kamal console                              # Rails console on web container
kamal logs                                 # Follow Puma logs
kamal app logs --roles worker -f           # Follow Sidekiq logs
kamal accessory logs postgres -f           # PostgreSQL logs
curl -fsS https://open.news/health/ready   # Verify PostgreSQL + Redis connectivity
```

---

## 4. External PostgreSQL Backups & Restore Drills

### Automated Off-Host Backups

Copy [script/backup_postgres.sh](../script/backup_postgres.sh) and [script/restore_postgres.sh](../script/restore_postgres.sh) onto the VPS (e.g., `/opt/opendotnews/`) and install either `rclone` (recommended for Cloudflare R2 / Backblaze B2 / DigitalOcean Spaces) or `awscli` (S3).

Add a daily cron job (or systemd timer) for root:

```cron
30 3 * * * BACKUP_REMOTE="r2:open-news-backups/postgres" BACKUP_RETENTION_DAYS=14 /opt/opendotnews/backup_postgres.sh >> /var/log/opendotnews-backup.log 2>&1
```

Each backup produces:
- `opendotnews_production_<UTC_TIMESTAMP>.dump` (PostgreSQL custom compressed format `-Fc`)
- `opendotnews_production_<UTC_TIMESTAMP>.dump.sha256` (integrity checksum)

**Also store a copy of your production secrets** (`RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, `ACTIVE_RECORD_ENCRYPTION_*`) in an external password manager / KMS — never inside the same unencrypted bucket as DB dumps.

### Safe Restore Drill (Run Quarterly / After Initial Setup)

Test restoration into a scratch database **without touching production traffic**:

```bash
TARGET_DB=opendotnews_restore_drill \
  /opt/opendotnews/restore_postgres.sh \
  /var/lib/opendotnews/backups/opendotnews_production_<TIMESTAMP>.dump

# Clean up scratch DB after verifying row counts:
docker exec opendotnews-postgres dropdb -U opendotnews opendotnews_restore_drill
```

### Full Production Restoration Procedure

1. Download the desired `.dump` and `.dump.sha256` from off-host storage (`rclone copyto` or `aws s3 cp`).
2. Stop the `web` and `worker` containers so no writes race the restore:
   ```bash
   kamal app stop
   ```
3. Run the verified restore script:
   ```bash
   CONFIRM_PRODUCTION_RESTORE=yes \
     /opt/opendotnews/restore_postgres.sh /path/to/opendotnews_production_<TIMESTAMP>.dump
   ```
4. Bring `web` and `worker` back online and verify readiness:
   ```bash
   kamal app boot
   curl -fsS https://open.news/health/ready
   ```
5. Sidekiq's recurring `Events::DispatchOutboxJob` and `Feeds::ScheduleDueJob` automatically catch up any outbox events or due feed polls.

---

## 5. Deploying on Railway, Render, or Fly.io (Zero Code Changes)

Because [Dockerfile](../Dockerfile) and [bin/docker-entrypoint](../bin/docker-entrypoint) honor `PORT` and read all config from environment variables, deploying to any managed container platform requires **no code changes**:

1. Provision managed **PostgreSQL 17** and **Redis** services.
2. Create **Service 1 (`web`)** from the repo's `Dockerfile` (default CMD: `./bin/thrust ./bin/rails server`), healthcheck path `/health/live`.
3. Create **Service 2 (`worker`)** from the same `Dockerfile` with start command override:
   ```bash
   bundle exec sidekiq -C config/sidekiq.yml
   ```
4. Set the required environment variables on both services:
   - `RAILS_ENV=production`
   - `APP_BASE_URL=https://open.news`
   - `DATABASE_URL` (from managed Postgres)
   - `REDIS_URL` (from managed Redis)
   - `SECRET_KEY_BASE` & `RAILS_MASTER_KEY`
   - `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`
