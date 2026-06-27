# SETUP.md

Everything needed to get PlacementPilot running, corrected against what this project actually needed —
not what was originally guessed. Every gotcha below was hit for real during this build; skipping one
reproduces the exact error that's already been debugged once.

Steps marked **[you]** need a human — account signups, payment details, OAuth consent screens. The rest
can be automated or scripted.

Work through it in order. §6 verifies Phase 0. §8 onward covers going live for real, not just standing
the stack up.

---

## 1. Install Docker Desktop **[you]**

1. Download Docker Desktop: <https://www.docker.com/products/docker-desktop/>
2. During install, keep **"Use WSL 2 instead of Hyper-V"** checked (Windows).
3. Reboot if prompted, launch Docker Desktop, wait for the whale icon to stop animating.
4. Verify:
   ```powershell
   docker --version
   docker compose version
   ```

> n8n runs inside a container and never touches the host's own Node.js install — whatever version is on
> the host is irrelevant, don't "fix" it.

Optional — GitHub CLI, for creating the remote from the terminal: <https://cli.github.com/>, then
`gh auth login`.

---

## 2. Create accounts **[you]**

| Service | Needed for | Real notes from this build |
|---|---|---|
| [Anthropic Console](https://console.anthropic.com/) | Scoring (WF-2), Gmail classification (WF-4) | Create an API key, load credits. Haiku is the volume model — real measured cost was ~$0.00285/evaluation. |
| [Discord](https://discord.com/developers/applications) | Alerts (WF-3) | See §4. |
| [RapidAPI — JSearch](https://rapidapi.com/letscrape-6bRBa3QguO5/api/jsearch) | LinkedIn/Indeed/Glassdoor/ZipRecruiter/Bayt listings | Free tier ~200 req/month. **The documented `/search` endpoint 404s at RapidAPI's own gateway on real accounts — the working endpoint is `/search-v2`.** Check your own account's code snippet in the RapidAPI sidebar before assuming the docs are current. |
| [SerpApi](https://serpapi.com/) | Naukri/LinkedIn/Instahyre via Google for Jobs, plus a weekly X/Twitter search | Free tier ~250 searches/month, shared across both uses. |
| [Careerjet](https://www.careerjet.com/partners/api/) | India coverage | See the credential table in §5 — this one has four separate real gotchas beyond just the key. |
| [Google Cloud](https://console.cloud.google.com/) | Gmail (WF-4) | Enable the Gmail API, create an OAuth client. Add your own account under **OAuth consent screen → Test users**, or you'll hit a `403: Access Denied` even with a correct client. |
| [Adzuna](https://developer.adzuna.com/) *(optional)* | Broad aggregate | Not used in this build — the owner declined it. `sources.json` has an entry, `enabled: false`. |
| [Jooble](https://jooble.org/api/about) *(optional)* | India coverage | Not built here — its auth is structurally different (key embedded in the URL path, POST-only), so it needs real workflow code, not just a credential. |

Record each provider's **actual** free-tier limit in `config/sources.json` → `aggregators[].monthly_limit`.
Published figures move; the enforced quota should match what you were really given.

---

## 3. Start the stack

```powershell
cp .env.example .env
```

Fill in `.env`:

- `POSTGRES_PASSWORD` — anything long.
- `N8N_ENCRYPTION_KEY` — generate with `openssl rand -hex 32`. **Back this up.** Every stored credential
  is encrypted with this key, in the database, not just in the n8n Docker volume — lose the key or lose
  the database without it, and you're re-entering every credential from scratch.
- `PP_CONFIG_BASE_URL` — the raw URL of *your* `config/` directory, e.g.
  `https://raw.githubusercontent.com/<you>/PlacementPilot/main/config`

Then:

```powershell
docker compose up -d
docker compose exec -T postgres psql -U placementpilot -d placementpilot < db/schema.sql
```

n8n is now at <http://localhost:5678>. Create the owner account when prompted — it is local to your
instance.

> Not using Docker? Nothing here requires it. Point n8n at any Postgres (Neon and Supabase both work,
> both support `pg_trgm`) via a connection string in the n8n credential. n8n Cloud works too — the
> workflows are import-free and Cloud-compatible by design.

**Config URL: use a real environment variable (`$env`), not n8n Variables (`$vars`).** An earlier version
of this guide said the opposite — that turned out to be wrong. n8n's Variables feature is **license-gated
on the free/self-hosted edition**, and reading a gated Variable from an expression doesn't error, it
silently resolves to `undefined` — every config fetch failed silently for weeks before this was caught.
The actual working setup, already reflected in `docker-compose.yml`:

```yaml
environment:
  N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"   # unblocks $env from expressions, a real n8n setting
  PP_CONFIG_BASE_URL: ${PP_CONFIG_BASE_URL}   # pulled straight from .env
```

Nothing to configure in the n8n UI for this one — it's already wired through `.env` → `docker-compose.yml`
→ every workflow's `{{ $env.PP_CONFIG_BASE_URL }}` expression.

---

## 4. Discord **[you]**

1. <https://discord.com/developers/applications> → **New Application**.
2. **Bot** → Add Bot → copy the token.
3. **OAuth2 → URL Generator** → scope `bot`; bot permissions `Send Messages`, `Embed Links`,
   `Read Message History`. Open the generated URL and add the bot to your own server.
4. Create a private channel for alerts. Enable **Developer Mode** (User Settings → Advanced), then
   right-click the channel → **Copy Channel ID**.

Discord buttons (`Applied` / `Not interested`) and the inbound interactions webhook were never built in
this project — they're the one piece of the original plan that's still just a design, not code (see
`CLAUDE.md` Phase 5). If you build it later, it needs a public HTTPS endpoint; a Cloudflare Tunnel is the
free way to get one, but a **Quick Tunnel's URL changes on every restart**, which doesn't work for a
webhook you register once with Discord — you need either a Named Tunnel (needs a domain you control) or
a different stable-hostname approach. Not a blocker for anything else in this repo.

---

## 5. Credentials in n8n

In n8n → **Credentials** → New. **Nothing below goes in `.env`, in `config/`, or in git — ever.**

| Credential | n8n type | Value | Real gotcha from this build |
|---|---|---|---|
| Anthropic | Anthropic API | your API key | — |
| Postgres | Postgres | host `postgres` (not `localhost`), port `5432`, db/user/password from `.env` | n8n reaches Postgres over the compose network by service name — `localhost` from inside the container means the container itself, not the host. |
| Discord Bot | Discord Bot API | bot token | — |
| SerpApi | **Query Auth** | Name field = `api_key`, Value = your key | The Name field *is* the literal query parameter n8n sends — an early attempt used a descriptive label there instead and silently sent the wrong parameter name. Also: the credential type literally named "SerpAPI" in some n8n instances is a deprecated LangChain agent-tool credential, unusable by a plain HTTP node — create Query Auth explicitly. |
| JSearch | **Header Auth** | Name = `X-RapidAPI-Key`, Value = your key | **Needs a second, non-secret header the credential can't hold** — add `{"X-RapidAPI-Host": "jsearch.p.rapidapi.com"}` in the HTTP node's own static headers field. n8n's V1 HTTP node (what this whole project uses) **does not support "Custom Auth" at all** — if that's the only option that looks like it fits, it's the wrong one. |
| Careerjet | **Basic Auth** | Username = your key, Password = blank | Four separate real checks beyond the key, discovered one at a time: (1) key validity, (2) your calling IP must be whitelisted in Careerjet's partner dashboard, (3) a `user_ip` query parameter matching that same real IP, (4) a `Referer` header matching whatever site you registered at signup. All four are wired into `wf1b_collect_aggregators.json` already — this row only matters if you're rebuilding from scratch. |
| Gmail | Google OAuth2 | from your Google Cloud OAuth client | Needs `simple: false` on the Gmail Trigger node to get full body text — the default lightweight mode only returns a short snippet, too little to classify. |
| n8n API Key | **Header Auth** | Name = `X-N8N-API-KEY`, Value = a key from n8n's own **Settings → n8n API → Create an API key** | Powers WF-5's spend-cap kill switch (§9) — lets one workflow deactivate the others via n8n's own REST API if daily spend runs away. Not needed for anything else in this repo. |

---

## 6. Verify Phase 0

- [ ] `docker compose ps` shows both services healthy
- [ ] <http://localhost:5678> loads and you can log in
- [ ] `docker compose exec postgres psql -U placementpilot -d placementpilot -c "\dt"` lists the tables from `db/schema.sql` (14 core tables, plus `gmail_messages` if you're past Phase 8)
- [ ] `curl $PP_CONFIG_BASE_URL/preferences.json` returns your JSON over HTTPS
- [ ] `config/preferences.json` has your real `profile.summary`, `skills`, `graduation_year`, and the
      `must_have` compensation/employment-type floors (see `prompts/v1.md` for how these are enforced)
- [ ] `git status` shows no `.env` and no credentials staged

---

## 7. Importing workflows and getting them to actually resolve each other

This is the step most likely to silently fail if you're setting this up from scratch, so it gets its own
section rather than a single bullet.

```powershell
docker compose exec -T n8n n8n import:workflow --input=/home/node/workflows/wf_l0_config.json
# repeat for every file in workflows/ -- order doesn't matter for import itself
```

**Importing is not enough.** Every workflow that gets called by another one via an `Execute Workflow` node
— `WF-L0`, `WF-L1`, `WF-2`, `WF-3`, `WF-5` — must also be **published** and the container **restarted**,
or every cross-workflow call fails with `"No information about the workflow to execute found"` or, once
that's fixed, `"Workflow is not active and cannot be executed"`:

```powershell
docker compose exec -T n8n n8n publish:workflow --id=<workflow-id>
# after all the publishes you need, restart once:
docker compose restart n8n
```

Real workflow IDs are in each file's own `"id"` field. `WF-1`, `WF-1b`, `WF-1c`, `WF-1d`, and `WF-4` are
different — they have their own real trigger (schedule or Gmail poll) and are meant to be activated
deliberately (§8), not automatically as a side effect of import.

Re-link every credential from §5 after import — n8n workflow JSON stores a credential's *name and ID*, not
the credential itself, so a fresh instance's IDs won't match until you manually re-select each one in the
UI.

---

## 8. Going live: activating the real collectors

Nothing in §1–§7 starts any external traffic. Everything is built, tested, and inert until you flip these
five workflows to active — each one has its own real, ongoing consequence once it is:

| Workflow | Trigger | What activating it starts |
|---|---|---|
| WF-1 collect-ats | hourly | Real hourly requests to every board in `config/sources.json` |
| WF-1b collect-aggregators | daily (+ weekly X-search) | Real calls against SerpApi/JSearch/Careerjet's metered free tiers |
| WF-1c collect-pages | daily | Real fetches of Cutshort/Hirist's public sitemaps |
| WF-1d discover | weekly | Real fetches of every YC company's career page |
| WF-4 gmail | every 1 minute | Real, continuous read access to your inbox |

```powershell
docker compose exec -T n8n n8n publish:workflow --id=75a4a1a8497c48f0    # WF-1
docker compose exec -T n8n n8n publish:workflow --id=b1b5e0f3a2b4d6789   # WF-1b
docker compose exec -T n8n n8n publish:workflow --id=c1c5e0f3a2b4d6789   # WF-1c
docker compose exec -T n8n n8n publish:workflow --id=d15c0f3a2b4e6789   # WF-1d
docker compose exec -T n8n n8n publish:workflow --id=f4a1b2c3d4e5f678   # WF-4
docker compose restart n8n
```

Every real Anthropic call this project makes flows through WF-2, which only ever runs when one of these
five calls it — so this is also the moment real, ongoing LLM spend begins. That's what §9 is for.

---

## 9. The kill switch

**Manual, works right now, no setup:**

1. `docker compose down` — stops everything immediately, data persists.
2. Toggle any workflow inactive in the n8n UI, or re-run its file with `"active": false` through
   `import:workflow`.
3. Deactivating just the five collectors from §8 (not WF-2/WF-3/WF-L0/WF-L1/WF-5) stops every path that
   spends tokens or makes external calls, while leaving the stack itself running.

**Automatic — WF-5's hourly spend-cap check**, built into `wf5_error.json`: every hour, it sums the real
`cost_usd` already logged in `runs` for the current day, and if it crosses a configured cap (`5.0` by
default — edit the `CAP_USD` constant in WF-5's `Is Cap Tripped?` node to change it), it calls n8n's own
REST API to deactivate all five collectors from §8, and sends one Discord alarm explaining why — not a
repeated one every hour once tripped. **This needs the `n8n API Key` credential from §5 to actually fire**
— without it, the check still runs and still alarms, but the deactivation calls themselves fail silently
(they're set to continue-on-fail so a missing credential doesn't crash the check itself).

This is a backstop against a runaway bug, checked hourly — not a hard real-time limiter. A genuine
worst-case spike within a single hour isn't mathematically bounded by it.

---

## 10. Running this unattended, long-term

- Docker's `restart: unless-stopped` is already set on both containers in `docker-compose.yml` — a Docker
  Desktop or host restart brings the stack back with no manual step.
- The host machine itself needs to stay powered and awake — a laptop that sleeps on lid-close will
  silently stop every scheduled poll until it's woken again.
- `scripts/sync_workflows.py` / `.ps1` exports the live n8n state and corrects real drift back into
  `workflows/*.json` if something changes through the UI rather than through git. Not scheduled
  automatically — run it by hand occasionally, or register `sync_workflows.ps1` in Windows Task Scheduler
  for a weekly check.
- Running this on a Raspberry Pi instead of a laptop or desktop is fully supported by the same design (no
  npm imports, no host filesystem reads, config over HTTPS) — see the deployment guide in
  [`docs/raspberry-pi.md`](docs/raspberry-pi.md) for the board-specific parts (RAM budgeting, SD-card
  wear, credential migration).

---

## 11. Forking this for yourself

The project is built to be handed over. If you found this repo and want it for your own hunt:

1. Fork it, then edit `config/preferences.json` — your profile, locations, exclusions, compensation
   floors, and the score threshold you want to be alerted at.
2. Edit `config/sources.json` — the companies and aggregators you care about.
3. Set `PP_CONFIG_BASE_URL` to *your* fork's raw config URL.
4. Work through §1–§7 with your own accounts and credentials.
5. Decide when you're ready for §8 — nothing forces you to activate anything before you trust it.

No code changes required anywhere. No personal data belonging to the original owner is anywhere in this
repo — everything identifying is either in `.env` (gitignored) or the n8n credential store (never
committed).
