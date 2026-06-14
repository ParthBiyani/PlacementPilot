# SETUP.md

Everything needed to get PlacementPilot running. Steps marked **[you]** need a human — account signups,
payment details, OAuth consent screens. The rest can be automated.

Work through it in order. Phase 0 is complete when §6 verifies.

---

## 1. Install Docker Desktop **[you]**

Currently **not installed** — this blocks everything else.

1. Download Docker Desktop for Windows: <https://www.docker.com/products/docker-desktop/>
2. During install, keep **"Use WSL 2 instead of Hyper-V"** checked.
3. Reboot if prompted, launch Docker Desktop, wait for the whale icon to stop animating.
4. Verify:
   ```powershell
   docker --version
   docker compose version
   ```

> Your host has Node v6.10.1 from 2017. **Do not upgrade it** — n8n runs inside a container and never
> touches host Node. Nothing in this project depends on it.

Optional but useful — GitHub CLI (also not installed), for creating the remote from the terminal:
<https://cli.github.com/> then `gh auth login`.

---

## 2. Create accounts **[you]**

| Service | Needed for | Notes |
|---|---|---|
| [Anthropic Console](https://console.anthropic.com/) | Scoring (Phase 2) | Create an API key, load credits. Haiku is the volume model. |
| [Discord](https://discord.com/developers/applications) | Alerts (Phase 2), buttons (Phase 5) | See §4. |
| [RapidAPI — JSearch](https://rapidapi.com/letscrape-6bRBa3QguO5/api/jsearch) | LinkedIn/Indeed/Glassdoor listings | Free tier ~200 req/month. |
| [SerpApi](https://serpapi.com/) | Naukri/LinkedIn/Instahyre via Google for Jobs | Free tier ~250 searches/month. |
| [Adzuna](https://developer.adzuna.com/) | Broad aggregate | Free ~1,000 calls/month. `app_id` + `app_key`. |
| [Jooble](https://jooble.org/api/about) | India coverage | Confirm the limit at signup and record it in `sources.json`. |
| [Careerjet](https://www.careerjet.com/partners/api/) | India coverage | Same. |
| [Google Cloud](https://console.cloud.google.com/) | Gmail (Phase 8) | Enable the Gmail API, create an OAuth client. Not needed until Phase 8. |

Record each provider's **actual** free-tier limit in `config/sources.json` → `aggregators[].monthly_limit`.
The published figures move; the enforced quota should match what you were really given.

---

## 3. Start the stack

```powershell
cp .env.example .env
```

Fill in `.env`:

- `POSTGRES_PASSWORD` — anything long.
- `N8N_ENCRYPTION_KEY` — generate with `openssl rand -hex 32`. **Back this up.** Lose it and every stored
  credential becomes unreadable.
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
> both support `pg_trgm`) by setting the connection string in the n8n credential instead. n8n Cloud works
> too — the workflows are import-free and Cloud-compatible by design.

**Set the config URL as an n8n Variable — not an environment variable.** This n8n version denies `$env`
access from expressions by default, so `WF-L0` reads `PP_CONFIG_BASE_URL` via `$vars` instead. In the n8n
UI: **Settings → Variables → Add Variable**, key `PP_CONFIG_BASE_URL`, value the same URL you put in
`.env`. (Or seed it directly: `INSERT INTO n8n.variables (id, key, type, value) VALUES (gen_random_uuid(),
'PP_CONFIG_BASE_URL', 'string', 'https://raw.githubusercontent.com/<you>/PlacementPilot/main/config');`
via `docker compose exec -T postgres psql -U placementpilot -d placementpilot`.)

---

## 4. Discord **[you]**

1. <https://discord.com/developers/applications> → **New Application**.
2. **Bot** → Add Bot → copy the token.
3. **OAuth2 → URL Generator** → scopes `bot`, `applications.commands`; bot permissions `Send Messages`,
   `Embed Links`, `Read Message History`. Open the generated URL and add the bot to your own server.
4. Create a private channel for alerts. Enable **Developer Mode** (User Settings → Advanced), then
   right-click the channel → **Copy Channel ID**.
5. From **General Information**, copy the **Public Key** — needed in Phase 5 to verify interaction
   signatures.

Phase 5 also needs a public URL for the interactions endpoint. Cloudflare Tunnel is free:

```powershell
winget install --id Cloudflare.cloudflared
cloudflared tunnel --url http://localhost:5678
```

Put the resulting `https://….trycloudflare.com/` into `WEBHOOK_URL` in `.env` and restart n8n. For an
address that survives restarts, create a named tunnel instead.

---

## 5. Credentials in n8n

In n8n → **Credentials** → New. **Nothing below goes in `.env`, in `config/`, or in git.**

| Credential | Type | Value |
|---|---|---|
| Anthropic | Anthropic API | your API key |
| Postgres | Postgres | host `postgres`, port `5432`, db/user/password from `.env` |
| Discord Bot | Discord Bot API | bot token |
| JSearch | Header Auth | `X-RapidAPI-Key: <key>` |
| SerpApi | Query Auth | `api_key` |
| Adzuna | Query Auth | `app_id` + `app_key` |
| Gmail | Google OAuth2 | from your Google Cloud OAuth client (Phase 8) |

> Host is `postgres`, not `localhost` — n8n reaches it over the compose network by service name.

---

## 6. Verify Phase 0

- [ ] `docker compose ps` shows both services healthy
- [ ] <http://localhost:5678> loads and you can log in
- [ ] `docker compose exec postgres psql -U placementpilot -d placementpilot -c "\dt"` lists 14 tables
- [ ] `curl $PP_CONFIG_BASE_URL/preferences.json` returns your JSON over HTTPS
- [ ] `config/preferences.json` has your real `profile.summary`, `skills` and `graduation_year`
- [ ] `git status` shows no `.env` and no credentials staged

When all six pass, Phase 0 is done and Phase 1 can start.

---

## 7. Forking this for yourself

The project is built to be handed over (P5). If you found this repo and want it for your own hunt:

1. Fork it, then edit `config/preferences.json` — your profile, locations, exclusions, threshold.
2. Edit `config/sources.json` — the companies you care about.
3. Set `PP_CONFIG_BASE_URL` to *your* fork's raw config URL.
4. Work through §1–§5 with your own accounts.
5. Import the workflows from `workflows/`.

No code changes. No personal data of the original owner is anywhere in the repo.
