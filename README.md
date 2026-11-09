# localidraw

A hardened, self-hosted [ExcaliDash](https://github.com/ZimengXiong/ExcaliDash) (Excalidraw with a drawing list, user accounts, sharing and live collaboration), running in Docker.

Compared with the upstream `docker-compose.prod.yml`:

- **No telemetry.** Prisma's startup ping and the GitHub update check are off.
- **No internet access for the app.** The backend's only way out is the `egress` proxy, which allows Google sign-in domains only (`egress/filter`) and logs every connection. The frontend has no outbound access.
- **Pinned images.** ExcaliDash 0.6.7, pinned by digest.
- **Locked-down containers.** No Linux capabilities, no privilege escalation, memory and process limits, read-only frontend.
- **Local only.** Published on `127.0.0.1` only.

## Requirements

- Docker with Compose v2 (on macOS, for example `colima start`)
- `openssl` (used by `gen-secrets.sh`)

## Initialize `.env`

```sh
cp .env.example .env
./gen-secrets.sh >> .env      # JWT_SECRET, CSRF_SECRET, API_KEY_HASH_PEPPER
chmod 600 .env
```

The defaults in `.env.example` run locally at http://localhost:6767 with email/password accounts (`AUTH_MODE=local`).

Keep `.env` out of git (it's in `.gitignore`) and back it up. **Never change `API_KEY_HASH_PEPPER`** once API keys exist: changing it invalidates all of them.

| Variable | Local try | Production |
|---|---|---|
| `FRONTEND_URL` | `http://localhost:6767` | `https://draw.yourcompany.com` |
| `TRUST_PROXY` | `1` (frontend nginx only) | `2` (your TLS proxy + nginx) |
| `AUTH_MODE` | `local` | `local` or `oidc_enforced` |

## Start

```sh
docker compose up -d
docker compose ps                  # backend and frontend should be "healthy"
```

### First run: create the admin

Do this right away. Until it's done, anyone who can reach the page can turn authentication off.

1. Open http://localhost:6767 and choose **enable authentication**.
2. Get the one-time setup code (valid for 15 minutes):
   ```sh
   docker compose logs backend | grep "BOOTSTRAP SETUP" | tail -1
   ```
   If it has expired: `docker compose restart backend` and check the logs again.
3. Register the admin account with that code.

## Users and sharing

- **Add users:** **Admin** → create the account with a temporary password and tick **must reset password**. Leave self-registration off.
- **Share a drawing:** open the drawing → **Share** → add an account with **Can edit** or **Can view**.
- **Share a collection:** right-click it in the sidebar → **Share Collection**. This covers every drawing in it.
- **Avoid "Anyone with the link".** The link is just the drawing's ID, and it keeps working until you set link access back to **Restricted**.

## Making it reachable for teammates

The app listens on `127.0.0.1` only. Don't publish it as plain HTTP: put HTTPS in front of it.

- **Tailscale** (recommended for a small team): `tailscale serve --bg 6767`. Then set `FRONTEND_URL=https://<host>.<tailnet>.ts.net` and `TRUST_PROXY=2`.
- **A server with Caddy, nginx or Traefik** as the TLS reverse proxy. It must forward WebSocket upgrades for `/socket.io/`.
- **ngrok** works, but ngrok decrypts all traffic on its servers. If you use it, put ngrok's OAuth (Google, restricted to your domain) in front of the app.

After changing `.env`, run `docker compose up -d`.

## Switching to Google sign-in

1. In Google Cloud Console, create an OAuth client ID (type: Web application):
   - Set the consent screen's user type to **Internal**. Otherwise any Google account can sign in.
   - Add `<FRONTEND_URL>/api/auth/oidc/callback` as an authorized redirect URI.
2. In `.env`:
   - set `AUTH_MODE=oidc_enforced`;
   - fill in `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` and `OIDC_REDIRECT_URI`.
3. Run `docker compose up -d`.

The first user to sign in becomes admin (Google sends no groups). Existing local users are linked by their verified email.

For another identity provider, change `OIDC_ISSUER_URL` and replace the domains in `egress/filter`.

## Moving to PostgreSQL

SQLite (the default) is fine for a trial or a small team. For hundreds of users, use PostgreSQL: SQLite handles one write at a time, and concurrent autosaves can fail with "database is locked".

ExcaliDash has **no built-in SQLite → PostgreSQL migration**. Switching `DATABASE_PROVIDER` starts an **empty** database; the existing data stays in the SQLite volume and isn't copied. Plan for it:

- **Best option: start on PostgreSQL** before the pilot or rollout, while there's little data to move.
- **Moving existing drawings:** each user exports their own drawings on the old instance (`.excalidash` archive: their drawings, collections and images), signs in to the new one, and imports it.
  - **Not carried over:** user accounts, sharing (drawing and collection permissions, links), API keys, version history, admin settings.
  - With Google sign-in, accounts are re-created automatically on first sign-in. Sharing must be set up again.
- **Database-level copy** (for example `pgloader` from `dev.db` into a database whose schema ExcaliDash already created): possible in principle, but not supported upstream and not tested here. Try it on a copy, and check logins, sharing and images before relying on it.

### Configuration

1. Add a database password to `.env`:
   ```sh
   echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)" >> .env
   ```
2. Add a `postgres` service to `docker-compose.yml`. Put it on the internal `app` network only, with no published port and no internet access. Pin the image by digest, as with the other images (`docker inspect postgres:16-alpine --format '{{index .RepoDigests 0}}'`).
   ```yaml
   services:
     postgres:
       <<: *hardening
       image: postgres:16-alpine            # pin: postgres:16-alpine@sha256:...
       cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]   # needed by the postgres entrypoint
       environment:
         POSTGRES_USER: excalidash
         POSTGRES_DB: excalidash
         POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}
       volumes:
         - pgdata:/var/lib/postgresql/data
       networks: [app]
       mem_limit: 1g
       healthcheck:
         test: ["CMD-SHELL", "pg_isready -U excalidash"]
         interval: 10s
         retries: 5

   volumes:
     pgdata:
   ```
3. In the `backend` service:
   - replace the two database lines:
     ```yaml
     DATABASE_PROVIDER: postgresql
     DATABASE_URL: postgresql://excalidash:${POSTGRES_PASSWORD}@postgres:5432/excalidash
     ```
   - add `postgres: { condition: service_healthy }` to `depends_on`.
   - Keep the `backend-data` volume: it still holds the generated secrets and the old SQLite file.
4. Start it: `docker compose up -d`. On startup the backend applies the PostgreSQL migrations. Then do the [first run](#first-run-create-the-admin) again: the new database is empty.

### Backups with PostgreSQL

The built-in `BACKUP_SCHEDULE` only backs up SQLite. Use `pg_dump` instead, run regularly and copied off the server:

```sh
docker compose exec -T postgres pg_dump -U excalidash -Fc excalidash > excalidash-$(date +%F).dump
# restore into an empty database:
docker compose exec -T postgres pg_restore -U excalidash -d excalidash --clean --if-exists < excalidash-YYYY-MM-DD.dump
```

Test a restore before relying on it. Keep `.env` with the backups: the secrets and `API_KEY_HASH_PEPPER` are needed alongside the data.

## Operations

```sh
docker compose logs -f egress      # every outbound connection (empty in local mode)
docker compose logs -f backend
docker compose down                # stop; data stays in the backend-data volume
```

- **Data:** stored in the `backend-data` Docker volume (SQLite database, plus the JWT and CSRF secrets). Back up the volume together with `.env`.
- **Upgrading:** change both the tag and the `@sha256` digest in `docker-compose.yml`. Re-check the new release (scan the images, review the changes) before deploying.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Hardened stack: backend, frontend, egress proxy |
| `.env.example` | Settings template |
| `gen-secrets.sh` | Prints fresh secrets in `.env` format |
| `egress/` | Allowlisting forward proxy (tinyproxy): `filter` lists the allowed domains |
| `docs/KICKOFF.md` | Plan for building our own whiteboard |
