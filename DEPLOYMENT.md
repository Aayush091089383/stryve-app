# Deploying the CampusSync backend

This guide takes the FastAPI backend from the laptop to [Render](https://render.com)
so the Flutter app keeps working when the laptop is off. Railway works the same
way and is covered at the end.

The backend is one small FastAPI process with a **SQLite** database and PDF
uploads on disk. That has two consequences for hosting:

1. **The database is a file.** It must live on a persistent disk, otherwise every
   restart/redeploy wipes it.
2. **One process, one instance.** SQLite plus a single attached disk cannot be
   shared between replicas, so do not scale the service beyond one instance.

The image itself is [backend/Dockerfile](backend/Dockerfile); the persistent
database path is chosen by [backend/config.py](backend/config.py).

---

## 0. Before you start — Render's Free plan cannot host this

Read this first; it saves a wasted afternoon:

| Render Free web service | Consequence for CampusSync |
|---|---|
| **No persistent disks** (disks are paid only) | The SQLite database is wiped on every spin-down, restart and redeploy |
| **Spins down after 15 min idle** (~1 min cold start) | Not 24/7: the first request after a quiet period takes about a minute |
| **No shell access** | You cannot run `seed_official_data.py` or `bootstrap_admin.py` |
| Ephemeral filesystem | Uploaded assignment PDFs disappear too |

So:

- To actually run CampusSync 24/7 with data intact, use a **paid instance**
  (Render "Starter") **plus a 1 GB disk**. That is roughly USD 7/month for the
  instance plus a small disk charge. Check current prices on
  [render.com/pricing](https://render.com/pricing).
- The Free plan is still useful to prove the container builds and `/health`
  answers, but treat its database as disposable.

Sources: [Render free-tier limits](https://render.com/docs/free),
[persistent disks](https://render.com/docs/disks).

---

## 1. Create the Render account and connect GitHub

1. Sign up at <https://dashboard.render.com/register> (GitHub sign-in is
   simplest).
2. Push this repository to GitHub if it is not there yet. The build only needs
   `backend/` and the root `.dockerignore`; the Flutter app is excluded from the
   image.
3. In Render: **New → Web Service**, then connect the GitHub account and pick the
   repository.

> Never commit `backend/.env`, `backend/campussync.db` or backups of it. They are
> already in `.gitignore`; the root `.dockerignore` also keeps them out of the
> image.

## 2. Create the web service

On the creation form:

| Field | Value |
|---|---|
| Name | `campussync-backend` (becomes part of the URL) |
| Language / Runtime | **Docker** |
| Branch | `main` (or whichever branch you deploy) |
| Region | closest to the college |
| Dockerfile Path | `backend/Dockerfile` |
| Docker Context Directory | `.` (repository root — required) |
| Docker Command | leave **empty** (the Dockerfile `CMD` sets the port) |
| Health Check Path | `/health` |
| Instance Type | **Starter** (for the disk and shell) |

Why the context matters: the Dockerfile copies `backend/requirements.txt` and
`backend/`, so it must be built from the repository root. If you set the context
to `backend`, the build fails at the first `COPY`.

Click **Create Web Service**. The first build installs the pinned dependencies
from [backend/requirements.txt](backend/requirements.txt) and starts uvicorn on
the port Render injects (`$PORT`).

The first deploy will **fail to stay up** until the environment variables and
database are in place — that is expected, continue below.

## 3. Environment variables

Render dashboard → your service → **Environment** → add:

| Key | Value | Notes |
|---|---|---|
| `SECRET_KEY` | long random string | Generate on your laptop: `python -c "import secrets; print(secrets.token_urlsafe(48))"`. Never reuse the dev default. |
| `DEBUG` | `False` | Do not run a public service in debug mode. |
| `DATABASE_URL` | `sqlite:////data/campussync.db` | Four slashes: an absolute path. Can be omitted — config.py auto-detects `/data` — but setting it makes the location explicit. |
| `ALLOW_DB_CREATE` | `1` for the **first boot only**, then `0` | The backend refuses to start against a missing database unless this is set; that guard is deliberate. |
| `UPLOAD_DIR` | `/data/uploads` | Keeps assignment PDFs on the disk instead of the ephemeral container. The Dockerfile already defaults to this. |
| `TOKEN_EXPIRATION_DAYS` | `7` | Optional. |
| `LOOKUP_RATE_LIMIT_PER_MINUTE` | `120` | Optional; `0` disables the public roll-number lookup limit. |
| `ALLOWED_ORIGINS` | `*` | The Flutter app is not a browser, so CORS rarely matters here. Tighten it if a web client is added. |

Do **not** set `PORT` — Render provides it, and the container command reads it.

## 4. Add the persistent disk

Service → **Disk** (or Advanced during creation):

- **Mount path:** `/data`
- **Size:** `1 GB` (you can grow it later, never shrink it)

Save; Render restarts the service with the disk mounted. From then on
`/data/campussync.db` and `/data/uploads/` survive deploys. Without the disk the
database is written to the container's ephemeral filesystem and lost on the next
restart.

Two side effects, both expected:

- Adding a disk disables zero-downtime deploys: Render stops the old instance
  before starting the new one, so a deploy means a few seconds of downtime.
- A disk cannot be attached to more than one instance — keep the service at one
  instance.

## 5. Create the first database and admin

On the **first** boot with `ALLOW_DB_CREATE=1`, the backend creates
`/data/campussync.db` with the full schema automatically
(`database.init_database()` in [backend/main.py](backend/main.py)).

Open **Shell** (paid instances) and run, from `/app`:

```bash
# 1. Official timetable / faculty / lab data (idempotent, fail-closed).
python seed_official_data.py --apply

# 2. The first administrator. Pick a strong password (12+ characters).
ADMIN_PASSWORD='<strong password here>' python bootstrap_admin.py
```

Then:

1. Set `ALLOW_DB_CREATE=0` in the Environment tab and save. This is important:
   with it off, a missing or wrong database path becomes a loud startup error
   instead of a silently empty database.
2. Check the logs show a clean start and that the service is live.

If you prefer to keep the accounts from the laptop, see §8 instead of seeding a
fresh database.

## 6. Get the public URL

The service page shows something like:

```
https://campussync-backend.onrender.com
```

Verify it before touching the app:

```bash
curl https://campussync-backend.onrender.com/health
# {"status":"ok","service":"Stryve backend"}
```

`/health` deliberately does not touch the database, so it proves the process is
up, not that the data is. `GET /` returns the original banner. A `404` on
`/health` means the deploy is old or the health path is wrong.

## 7. Point the Flutter app at the new host

`BACKEND_URL` is a compile-time define (`lib/config/environment.dart`). The
default is still the ngrok tunnel, so pass the new URL explicitly:

```bash
# Debug run against the cloud backend
flutter run --dart-define=BACKEND_URL=https://campussync-backend.onrender.com

# Release APK
flutter build apk --release \
  --dart-define=BACKEND_URL=https://campussync-backend.onrender.com
```

Notes:

- No trailing slash, `https://` only.
- The value is baked into the binary: rebuild and reinstall after changing it.
  An APK built without the define still points at the old ngrok host.
- Do not edit `lib/` for this; the define is the supported switch.
- Free instances sleep, so the app's first request after a quiet period can take
  ~1 minute and may look like a timeout. Paid instances stay warm.

## 8. Optional: keep the existing laptop data

A paid service has shell/SSH access, so the current database can be copied up
instead of seeding a fresh one:

1. In the Render dashboard enable **SSH** for the service and copy the `ssh`
   command it shows (it contains the user and host, and a port only in some
   regions).
2. From the repository root on the laptop, with the backend stopped so the file
   is not changing, use the same user/host (add `-P <port>` only if the shown
   command has one):

   ```bash
   scp -s backend/campussync.db \
     <user>@<host-from-the-ssh-command>:/data/campussync.db
   ```

3. Leave `ALLOW_DB_CREATE=0` (the file now exists) and redeploy.
4. Check `/health`, then log in as a teacher/admin to confirm the rows arrived.

`backend/campussync.db` contains password hashes and student records: transfer
it over SSH/SCP or Magic Wormhole only, never through git, chat or a public file
host.

## 9. Backups and updates

- **Backups:** copy `/data/campussync.db` down periodically with the same `scp`
  command. Render also snapshots disks daily, but its docs warn against
  snapshot-restoring a disk that backs a custom database; prefer a file copy.
- **Updates:** `git push` triggers a rebuild and restart. The disk is preserved.
  If a release changes the schema, apply the documented schema step (for
  example `python seed_official_data.py --schema-only --apply`) **before**
  starting the new code, otherwise the ORM queries columns the file lacks.
- **Rollbacks:** Render keeps the last two deploys; rolling back runs the older
  image against the same disk, so only roll back to a version whose schema
  matches.

## 10. Railway (alternative)

Railway runs the same Dockerfile:

1. Create a project from the GitHub repo; Railway detects
   `backend/Dockerfile`. If it does not, set the Dockerfile path to
   `backend/Dockerfile` with the repository root as context.
2. Add a **Volume** to the service and mount it at `/data`.
3. Add the same environment variables as §3 (`PORT` is injected by Railway).
4. Generate a public domain (Settings → Networking) and use it as
   `BACKEND_URL`.
5. Run the seeding commands from the Railway shell/`railway run`, exactly as in
   §5.

Railway's trial/Hobby plan is required for volumes; check its current pricing
before starting.

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Logs: `Database file not found: /data/campussync.db` | First boot without `ALLOW_DB_CREATE=1`, or the disk is missing/not mounted at `/data`. |
| Logs: `Not a SQLite database: /data/...` | A non-SQLite file at that path (for example a failed partial upload). Inspect before deleting anything. |
| Deploy exits immediately, no logs | `Dockerfile Path` or `Docker Context Directory` is wrong; the context must be the repo root. |
| `/health` 404 | Wrong health-check path, or the running deploy predates it. |
| 502 / "service unavailable" | The process crashed at import (check logs) or is still starting. |
| Assignments 404 after a redeploy | `UPLOAD_DIR` was not on `/data`; the files were in the container's ephemeral layer. |
| Data disappears after every deploy | No disk attached, or `DATABASE_URL` points outside `/data`. |
| Login fails with a valid password | The database was recreated (fresh seed) and the account no longer exists; restore the backup or re-create the admin. |
