# Running PlacementPilot on a Raspberry Pi

The stack was designed to run unchanged on Cloud, a laptop, or a Pi (N1 in `CLAUDE.md`) — no npm imports
in Code nodes, no host filesystem reads, Postgres as a plain connection string, config fetched over
HTTPS. Nothing in the design is x86-specific, and both `postgres:16` and `n8nio/n8n` publish official
`arm64` images. This walks through what that actually takes on a **Raspberry Pi 3 Model B+** specifically
(BCM2837B0, 4× Cortex-A53 @ 1.4GHz, 1GB LPDDR2 RAM) — the same steps apply to any Pi, but the RAM budget
below is written for this board's real constraint.

A more visual version of this same guide, with the same content, is available as a published Claude
artifact from the session that wrote it — this file is the canonical, version-controlled copy.

---

## 0. The one real constraint: 1GB of RAM

Architecture and CPU aren't the risk here. Postgres and n8n together comfortably use 1–1.5GB combined on
a normal machine — on a 3B+ this is tight enough that swap isn't optional (§6), and a memory spike (a
large WF-1 run, say) is the most likely real failure mode, more likely than anything CPU-bound. If this is
a hard blocker, a Pi 4 (2GB+) or Pi 5 removes the question entirely; everything else here still applies.
At this project's real traffic volume (a few hundred postings/day, not thousands) the 3B+ is workable —
just budget the swap.

## 1. Flash Raspberry Pi OS — 64-bit, Lite

Two non-negotiable choices:

- **64-bit, not 32-bit** — the CPU supports both, but a 32-bit userland can't run some `arm64`-only image
  variants.
- **Lite, not Desktop** — no monitor is attached; a desktop environment is pure RAM overhead.

In Raspberry Pi Imager: OS menu → *Raspberry Pi OS (other)* → *Raspberry Pi OS Lite (64-bit)*. Before
writing, use the gear icon to set a hostname, enable SSH, and set Wi-Fi/locale — this gets a headless box
on first boot.

```powershell
ssh pi@placementpilot.local   # or whatever hostname you set
```

## 2. Storage: SD card or boot from USB

Postgres writes to disk constantly. A cheap microSD card under sustained write load is a real, common
failure point for always-on Pi projects.

- **SD card only** — simplest. Use a high-endurance, application-class (A2) card, not a budget one meant
  for photos. Fine for a first attempt.
- **Boot from USB SSD (recommended)** — the 3B+ can boot entirely from USB once its bootloader EEPROM is
  updated (`raspi-config` → *Advanced Options* → *Bootloader Version*). More durable, faster, and pairs
  well with §6's swap requirement, which wears an SD card out faster.

## 3. Install Docker and the Compose plugin

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
# log out and back in for the group change to apply
docker compose version   # confirm the plugin, not standalone docker-compose
```

Docker's convenience script handles ARM correctly on its own. This project's `docker-compose.yml` already
uses `docker compose` plugin syntax throughout.

## 4. Get the project onto the Pi

```bash
git clone https://github.com/ParthBiyani/PlacementPilot.git
cd PlacementPilot
```

The repo is public and holds no secrets. `.env` is gitignored on purpose — it never went to GitHub, so it
won't arrive with the clone. Copy it over directly, machine to machine, never through chat or a paste
site:

```powershell
# from your dev machine, not the Pi
scp .env pi@placementpilot.local:~/PlacementPilot/.env
```

## 5. Fresh start, or bring your data

`docker-compose.yml` pins `N8N_ENCRYPTION_KEY` to a fixed value in `.env` rather than letting n8n generate
a random one per install. That key encrypts every credential n8n stores in Postgres. Carrying the same
`.env` over means a full database migration brings every credential across already working — nothing to
re-enter.

- **Migrate everything (recommended)** — dump the database on the current machine, restore on the Pi. All
  tables, every credential, full history comes across.
- **Fresh start** — apply `db/schema.sql` on an empty database. Matches the project's own portability test
  (N1) most directly, but means re-entering all ~8 credentials, Gmail's OAuth flow included.

To migrate, run on the **current** machine:

```bash
docker compose exec postgres pg_dump -U placementpilot -d placementpilot -F c -f /tmp/pp_dump.sql
docker compose cp postgres:/tmp/pp_dump.sql ./pp_dump.sql
```

Copy `pp_dump.sql` to the Pi the same way as `.env`, then, once the Pi's Postgres container is up (§6):

```bash
docker compose cp pp_dump.sql postgres:/tmp/pp_dump.sql
docker compose exec postgres pg_restore -U placementpilot -d placementpilot --clean --if-exists /tmp/pp_dump.sql
```

## 6. Bring the stack up

```bash
docker compose up -d
docker compose ps   # both containers should read "healthy" within 30-60s
```

Fresh start only (skip if you restored a dump above):

```bash
docker compose exec -T postgres psql -U placementpilot -d placementpilot < db/schema.sql
```

Reach the editor from your dev machine at `http://placementpilot.local:5678`. If you migrated, every
workflow and credential should already be exactly as it was.

## 7. Re-point what's tied to the old machine's identity

- **Careerjet's IP whitelist** — their API rejects requests from an unrecognized IP. The Pi's public IP
  will differ from wherever it ran before. Update it in Careerjet's partner dashboard. (Worth checking
  whether your ISP's IP is stable at all before relying on a single whitelisted value — see the note in
  `CLAUDE.md` about dynamic/rotating IPs being a real, observed issue on this project's own network.)
- **Gmail OAuth, if you did a fresh start** — re-authorize through n8n's credential screen, same flow as
  the first time.
- **Workflow activation state** — if you migrated the database, it comes across exactly as it was. Verify
  rather than assume: `docker compose exec postgres psql -U placementpilot -d placementpilot -c "SELECT name, active FROM n8n.workflow_entity;"`

## 8. Fitting Postgres and n8n into 1GB

**Add swap** — the default 100MB is too small for this workload:

```bash
sudo dphys-swapfile swapoff
sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
sudo dphys-swapfile setup
sudo dphys-swapfile swapon
```

Swap on an SD card wears it out faster under heavy use — one more reason §2's USB-SSD option pays off.

**Cap Postgres's own memory use** — its defaults assume more headroom than this board has. A rough
starting point for 1GB total RAM:

```
shared_buffers = 128MB
work_mem = 4MB
maintenance_work_mem = 32MB
max_connections = 20
```

**Strip the OS down** — disable anything unused, e.g.:

```bash
sudo systemctl disable bluetooth hciuart
```

## 9. Power and staying alive unattended

- Use the official 5V/2.5A+ supply or better. An undersized supply causes silent under-voltage throttling
  — it reads as mysterious slowness or corruption, with no obvious power fault to point to.
- Both containers already have `restart: unless-stopped` in `docker-compose.yml` — a Pi reboot brings the
  stack back with no manual step.
- Confirm Docker's own boot service is enabled so a power-cycle (not just a reboot) recovers cleanly:
  `systemctl is-enabled docker` (the install script in §3 usually enables this already).

## 10. Verify it's actually real, not just running

- Both containers show `healthy` in `docker compose ps`, sustained.
- The n8n editor loads and every credential resolves — a migrated credential showing a red "not found"
  icon means the encryption key didn't travel correctly.
- Manually trigger WF-1 and confirm real postings land in `postings`, not just a green checkmark.
- Let one real scheduled cycle pass unattended (an hour, for WF-1) and check `runs` for a row that wasn't
  manually triggered.
- `free -h` after a day of real traffic, to see where memory actually settles against §8's estimate.
