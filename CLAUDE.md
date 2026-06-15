# CLAUDE.md — PlacementPilot control document

> This file is the operating agreement for the project. It carries the standing rules, the honest
> current state, and the TODO. It is **not** a summary of [PRD.md](PRD.md) — the PRD holds rationale,
> this file holds rules and state. Read it fully at the start of every session.
>
> **Maintenance contract:** rewrite **Current state** in place (never append — it must never lie);
> tick **TODO** boxes as work lands and never delete unfinished items; add newly discovered work to
> TODO; append to **Session log**. Every meaningful decision goes to [DECISIONS.md](DECISIONS.md),
> every change to a node graph or call path goes to [FLOW.md](FLOW.md).

---

## What this is

A job-hunting automation that watches company ATS boards, free aggregator APIs, startup-accelerator
portfolios and company career pages; deduplicates what it finds; discards what clearly doesn't match
stated preferences; scores the rest with Claude; and **pings Discord the moment something genuinely
good appears**, with a button to mark it applied. Gmail classification folds recruiter mail into the
same tracker.

**This is a tool the owner needs to work, not a portfolio artifact.** The PRD frames it as the latter;
that framing is superseded. Priority order for every design choice: *usefulness first, then keeping it
alive, then provability.*

The user controls it by editing two config files. They never touch the workflows.

---

## Hard constraints — do not violate

**Non-goals. Do not build these.** If a request drifts here, flag the conflict before acting.

- Auto-apply / form autofill
- Resume optimizer, interview prep, career coaching
- Web dashboard (SQL in `db/queries/` answers every stats question)
- Multi-agent reasoning, planning loops, tool-calling agents
- **Bot-detection evasion of any kind** — no fingerprint spoofing, no proxy rotation to dodge bans, no
  CAPTCHA solving, for LinkedIn/Naukri/Instahyre or anything else. See
  [DECISIONS.md](DECISIONS.md) `2026-08-13 — Licensed aggregators over scraping`.

**Portability is binding (N1).** The stack must run unchanged on n8n Cloud, a laptop, or a Raspberry Pi:

- **No npm imports in Code nodes.** n8n Cloud forbids them. Use native nodes — SHA-256 comes from the
  **Crypto node**, not `require('crypto')`.
- **No host filesystem reads or writes.** Config arrives over HTTPS.
- **No community nodes on the critical path.**
- **Postgres is a connection string in a credential.** `docker-compose.yml` is one supported runtime,
  never a dependency.
- **No personal data anywhere except `config/` and the credential store.**

---

## Architecture at a glance

Full detail in the approved plan; workflow-by-workflow execution order in [FLOW.md](FLOW.md).

| WF | Trigger | Does |
|---|---|---|
| **WF-L0** lib-config | Execute Workflow | Fetch + validate + cache config files over HTTPS |
| **WF-L1** lib-normalize | Execute Workflow | Normalization + exact dedup key. Single source of truth |
| **WF-0** selftest | Schedule (daily) | Frozen fixtures through WF-L1, diff vs expected, alarm on mismatch |
| **WF-1** collect-ats | Schedule (hourly) | ATS boards → normalize → dedup → upsert → score immediately |
| **WF-1b** collect-aggregators | Schedule (daily) | Aggregator APIs, quota-gated |
| **WF-1c** collect-pages | Schedule (daily) | Career pages / RSS — robots-aware fetch → LLM extraction |
| **WF-1d** discover | Schedule (weekly) | Accelerator portfolios → probe ATS endpoints → register |
| **WF-2** score | Execute Workflow | Prefilter → cache → Haiku → validate → persist → notify |
| **WF-3** notify | Execute Workflow | One Discord embed per qualifying posting, immediately |
| **WF-3b** inbound | Webhook | Discord Interactions, Ed25519-verified → status update |
| **WF-4** gmail | Gmail Trigger (15m) | Classify → extract → notify |
| **WF-5** error | Error Workflow on all | Log to `runs`, alarm, enforce spend cap |
| **WF-6** eval | Manual / pre-promotion | Score the labeled set, compute metrics, gate prompt promotion |

**Ingestion tiers:** A = company ATS boards (hourly) · B = accelerator portfolios → auto-discovery
(weekly) · C = free aggregator APIs, quota-gated (daily) · D = career pages + RSS (daily).

---

## Current state

*Rewritten in place each session. Last updated: 2026-08-13.*

**Phase: 0 (Foundations), in progress. Runtime resolved.**

| Item | State |
|---|---|
| Repo | Live at <https://github.com/ParthBiyani/PlacementPilot>, branch `main`. Config is fetchable at `https://raw.githubusercontent.com/ParthBiyani/PlacementPilot/main/config`. |
| Docker | **Resolved** — Docker Desktop working, `docker --version` 29.7.2, `docker compose` v5.3.1. |
| Node (host) | v6.10.1 — irrelevant, n8n runs in a container. Do not "fix" it. |
| Python / uv | 3.11.9 / 0.11.25 present — unused by design, all-n8n. |
| Postgres | **Running.** `placementpilot-postgres-1`, healthy, schema applied — 14 tables confirmed. Host port **5433**, not 5432 (a native Postgres Windows service already held 5432 — see `docker-compose.yml` comment). |
| n8n | **Running.** `placementpilot-n8n-1`, v2.34.6, healthy at <http://localhost:5678>. Owner account created. `workflows/` bind-mounted into the container at `/home/node/workflows` so the CLI (`import:workflow`/`execute`/`publish:workflow`) can build and test directly against it — no API key needed. |
| Accounts | **In progress** — Discord, RapidAPI/JSearch, SerpApi, Careerjet, Google Cloud created. Still needed: Anthropic, Adzuna, Jooble. Real free-tier limits not yet recorded in `config/sources.json` (still vendor-doc placeholders). n8n credential store has Discord, SerpApi, Gmail, plus `pp-local-postgres` (our own Docker DB, not a third-party secret). |
| Scaffolding | `db/schema.sql` (14 tables), `docker-compose.yml`, `.env.example`, `config/*`, `SETUP.md` all written. |
| Config files | Sources seeded with **15 board tokens probed live on 2026-08-13**. `preferences.json` has the **real profile** — derived from `Resumes/` (3 role-targeted resumes: SDE, AI/ML, Data), gitignored, never committed. `PP_CONFIG_BASE_URL` seeded as an **n8n Variable** (`$vars`, not `$env` — see `DECISIONS.md` 2026-08-14). |
| Workflows | **WF-L0, WF-L1 and WF-0 built, imported, published, and CLI-tested against the live instance** — not just valid JSON, actually executed, both happy and failure paths. Full details in `FLOW.md` "Changed this session" 2026-08-14. WF-1 next. |

**Blocked on the user:** Anthropic + Adzuna + Jooble signups · real free-tier limits for the aggregators
already created · entering remaining credentials into the n8n store · starter company list approval ·
the Gmail OAuth 403 (add own account to the OAuth consent screen's Test users list) · deleting the stray
`client_secret_*.json` from the repo root once the Google credential is safely in n8n.

---

## Conventions and standing rules

- **Secrets live in the n8n credential store only.** Never in workflow JSON, never in `config/`, never
  in git. `config/` is public-safe by design.
- **Config is fetched over HTTPS** from a URL held in an n8n variable, cached in `config_cache` with its
  `ETag`. On fetch failure: use last good cache **and alarm**. Never fail silently.
- **`prompt_version = sha256(prompt_template + profile block)`**, computed by the Crypto node. Editing
  the profile therefore busts the score cache automatically — no manual version bump.
- **Score cache key is always `(content_hash, prompt_version, model)`.**
- **Send-once is a database guarantee**, not workflow logic: `UNIQUE(posting_id, channel)` on
  `notifications`. Do not add workflow-level dedup as a substitute.
- **Every run writes a row to `runs`.** No exceptions — it is the only source of honest numbers.
- **The prefilter is conservative.** Reject only on unambiguous mismatch; anything ambiguous goes to the
  LLM. There is **no kill-rate target** — it is a reported number, never an objective.
- **Recall is weighted above precision** in scorer tuning. A missed good job is a real loss; a bad alert
  costs five seconds.
- **Never tune against the held-out label split.** Touch it once, at the end.
- **Invalid LLM output is never silently dropped** — one retry with the error appended, then flag the
  row and alarm via WF-5.
- **WF-5 is set as the Error Workflow on every other workflow.**
- **Shared logic lives in WF-L0/WF-L1** and is called via Execute Workflow, so WF-0 tests the same code
  the collectors run. Never inline a second copy of normalization.
- **Polite fetching** for career pages: honour cached `robots.txt`, ≤1 req/s, identifying User-Agent,
  conditional requests via `ETag`/`Last-Modified`, once daily per domain.
- Dev box is Windows; PowerShell is primary. Project root: `d:\Projects\PlacementPilot`.
- **Commits carry no AI-attribution trailer** — no `Co-Authored-By: Claude…` or similar. Conventional
  one-liner messages, backdated into 2026-06 (both `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE`), at most
  2–3 per day, pushed after each. History was rewritten once already (2026-08-14) to strip trailers that
  had been added before this rule existed — do not reintroduce them.

---

## Success criteria

Values stay blank until measured. Estimates are not permitted here.

| # | Goal | Measured |
|---|---|---|
| **P1** | Good matches arrive within ~1h of posting, unprompted | |
| **P2** | Alerts are trusted — low false positives, low misses | |
| **P3** | Keeps running without babysitting; failures alarm | |
| **P4** | $0/month beyond LLM tokens | |
| **P5** | A stranger can fork it, edit two files, add keys, run | |

| # | Non-functional | Measured |
|---|---|---|
| N1 | Runs unchanged on Cloud / laptop / Pi | |
| N2 | ATS alert latency ≤ ~1h (p50, p95) | |
| N3 | ≥8 weeks unattended, <2 interventions | |
| N4 | Zero duplicate notifications | |
| N5 | Scorer ≥0.85 held-out agreement, recall-weighted | |
| N6 | Every workflow's error branch has fired and recovered | |
| N7 | Every provider stays inside its free tier | |

---

## TODO

Unfinished items are never deleted. New work is added here.

### Phase 0 — Foundations
- [x] `git init` + `.gitignore`
- [x] `CLAUDE.md`, `DECISIONS.md`, `FLOW.md`
- [x] `db/schema.sql` — full data model, `pg_trgm`, `notifications` unique constraint
- [x] `docker-compose.yml` + `.env.example`
- [x] `config/preferences.json`, `config/sources.json`, `config/accelerators.json` + `config/README.md`
- [x] `SETUP.md` — account and credential walkthrough
- [x] **User:** resolve the Docker Desktop issue
- [ ] **User:** create remaining accounts — Anthropic, Adzuna, Jooble (Discord, RapidAPI/JSearch, SerpApi, Careerjet, Google Cloud done)
- [ ] Record each provider's real free-tier limit in `config/sources.json` (currently vendor-doc placeholders)
- [ ] **User:** supply real profile/preference values
- [x] Create GitHub remote, first commit, push
- [ ] Cloudflare Tunnel for the public webhook URL (needed from Phase 5)
- [x] Apply schema to a running Postgres; verify config files fetchable over HTTPS
- [x] **User:** open <http://localhost:5678> and create the n8n owner account (first login)
- [ ] Enter credentials into the n8n credential store as accounts finish — Discord + SerpApi done; still need Anthropic, RapidAPI, Careerjet, Google
- [x] Real profile in `config/preferences.json` — derived from `Resumes/` (SDE, AI/ML, Data resumes), skills/projects merged, queries broadened to cover all three tracks

### Phase 1 — Config layer + ATS collection
- [x] WF-L0 lib-config — fetch, validate, cache with ETag, fallback + alarm. Built and CLI-tested against
      the real Postgres and the real GitHub-hosted config; all four outcomes (fresh/304/fallback/hard-fail)
      verified. See `DECISIONS.md` 2026-08-14 for two real HTTP Request pitfalls found and fixed.
- [x] WF-L1 lib-normalize — normalization rules + exact key via Crypto node. Built and verified: two
      differently-sourced variants of the same posting collapse to the same dedup `id`; noisy role text
      strips correctly.
- [x] WF-0 selftest — fixtures through WF-L1, diff, alarm. Built and CLI-tested both directions: happy
      path (5/5 fixtures pass) and failure path (a deliberately wrong fixture was correctly caught,
      reported with exact field/expected/actual, and thrown).
- [x] `db/seed_fixtures.sql` — 5 real fixtures, expected hashes computed offline against the actual normalize logic
- [ ] WF-1 collect-ats — hourly, Switch(provider), upsert, write `runs`
- [ ] Verify: editing `sources.json` changes the next run's collection

### Phase 2 — Scoring and immediate alerts *(tool becomes useful)*
- [ ] Conservative prefilter driven by `preferences.json`
- [ ] `prompts/v1.md` + profile block; `prompt_version` hashing
- [ ] WF-2 score — cache, Haiku, contract validation, one retry, token counts
- [ ] WF-3 notify — immediate Discord embed, insert into `notifications`
- [ ] Verify: a real matching posting reaches Discord within an hour

### Phase 3 — Reliability
- [ ] WF-5 error handler; set as Error Workflow on every workflow
- [ ] Retry on Fail (3, exponential) on all HTTP nodes; Continue On Fail per source
- [ ] Zero-result alarm (source returns 0 twice consecutively)
- [ ] Config-fetch failure alarm
- [ ] Weekly workflow export to git via n8n REST API
- [ ] Chaos test: dead token mid-run recovers unattended

### Phase 4 — Ingestion breadth
- [ ] WF-1d discover — accelerator portfolios → ATS endpoint probing → `discovered_sources`
- [ ] WF-1b collect-aggregators — quota-gated, query set from preferences
- [ ] WF-1c collect-pages — robots-aware fetch, conditional requests, LLM extraction
- [ ] Probe Keka / Darwinbox / Zoho Recruit for public endpoints
- [ ] Verify projected monthly usage inside every free tier

### Phase 5 — Discord interactions
- [ ] WF-3b inbound — Ed25519 verification (import-free), PING response, status update
- [ ] `[Applied] [Not interested] [Details]` buttons; edit message in place

### Phase 6 — Near-duplicate detection *(gated: needs corpus)*
- [ ] `pg_trgm` similarity scoped per normalized company
- [ ] Hand-label 50 pairs, sweep threshold, pick max-F1, commit the curve
- [ ] `canonical_id` + prefer direct-ATS `apply_url`

### Phase 7 — Evaluation and tuning *(gated: ~200 postings)*
- [ ] Label 200 postings, 120 train / 80 held-out
- [ ] WF-6 eval — precision, recall, F1, Cohen's κ → `eval_runs`
- [ ] Prompt iteration v1 → v2 → v3
- [ ] Promotion gate: no activation below frozen-baseline F1

### Phase 8 — Gmail
- [ ] WF-4 — classify, extract, fuzzy-match, notify; cache on message ID

### Phase 9 — Spend cap, soak, forkability
- [ ] Enforced daily spend cap via n8n REST API
- [ ] Feature freeze and soak
- [ ] `README.md` finished for P5

### Backlog — do not start
WhatsApp as a second channel · more aggregators · public write-up

---

## Session log

*Append-only, newest last.*

### 2026-08-13 — Project understanding and planning
- Explored the repo: only `PRD.md` existed. Probed the environment — Docker absent, Node v6.10.1,
  Python 3.11.9, uv 0.11.25, git present, not a repo.
- Researched ingestion options: confirmed LinkedIn scraping is non-viable for unattended operation
  (Proxycurl litigated out of existence July 2026; Voyager API bans in 3–7 days), and that free-tier
  licensed aggregators cover LinkedIn/Naukri/Indeed at daily volume for $0.
- Verified two n8n facts that shaped the architecture: the **Crypto node** does SHA-256 natively and
  works on Cloud; there is **no native Discord Trigger**, so inbound needs a plain Webhook plus
  import-free Ed25519 verification.
- Agreed seven overrides to the PRD with the user (all-n8n, more sources, Discord, immediate alerts,
  no kill-rate target, file-based config, full portability). Recorded in `DECISIONS.md`.
- Plan approved. Completed the whole automatable half of Phase 0: `.gitignore`, these three documents,
  `db/schema.sql` (14 tables), `docker-compose.yml`, `.env.example`, `config/*` and `SETUP.md`.
- Probed ATS endpoints live rather than assuming them. Confirmed the Greenhouse, Lever and Ashby URL
  patterns, plus 15 working board tokens — including Indian companies PhonePe, Groww, Slice, Turing and
  Postman — and the YC open-source API (~10MB, refreshed daily). `config/sources.json` is seeded only
  with boards that actually returned 200.
- Repo pushed to <https://github.com/ParthBiyani/PlacementPilot>. Commit history is **backdated to
  June 2026** at the owner's explicit instruction, after the concern was raised and overruled; author and
  committer dates match, though GitHub's server-side repo-creation and push timestamps still read August.
- **Next:** Phase 0 remaining items are all user actions — install Docker Desktop, create accounts, fill
  in the real `profile` block in `config/preferences.json`. Then Phase 1 (WF-L0, WF-L1, WF-0, WF-1).

### 2026-08-14 — Docker paused; git history scrubbed of AI attribution
- User hit an unresolved issue running Docker Desktop; **paused, not being debugged now.** Nothing else
  in the design depends on it (portability, N1) — two alternatives are recorded above for when it comes
  back up (n8n Cloud + hosted Postgres, or native n8n via `npx` on an upgraded Node), neither chosen.
- User asked that Claude not appear as a GitHub contributor. All 15 existing commits carried a
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` trailer; rewrote every commit message with
  `git filter-branch --msg-filter` to strip it (author/committer dates and content untouched), deleted
  the filter-branch backup refs, expired the reflog, ran `git gc --prune=now`, verified no occurrence of
  "claude" / "anthropic" / "co-authored" anywhere in `git log --all`, then **force-pushed** the rewritten
  history to `origin/main` — the old commit SHAs are no longer reachable on GitHub.
- New standing rule going forward: no AI-attribution trailer in any commit. Recorded in "Conventions and
  standing rules" above.
- **Docker resolved** — user fixed the local issue. `docker --version` 29.7.2, `docker compose` v5.3.1
  confirmed reachable. No architecture change; Docker was already the documented default path, it just
  started working, so no new `DECISIONS.md` entry.
- Accounts in progress: Discord, RapidAPI/JSearch, SerpApi, Careerjet and Google Cloud created. Still
  needed: Anthropic, Adzuna, Jooble. Agreed the handoff protocol for credentials: **secrets go straight
  into the n8n credential store once the stack is up, never into chat, never into a file** — matches the
  existing "Conventions" rule. Non-secret facts (which accounts are done, each provider's actual
  free-tier limit, Discord channel ID) are fine to share directly.
- **Stack stood up:** `docker compose up` — Postgres healthy on host port **5433** (5432 was taken by a
  native Postgres Windows service, remapped in `docker-compose.yml`; internal n8n↔Postgres traffic is
  unaffected since it goes over the Docker network). Schema applied, all 14 tables confirmed. n8n 2.34.6
  healthy at localhost:5678. User created the n8n owner account and entered Discord + SerpApi credentials.
- Found an untracked Google OAuth `client_secret_*.json` sitting in the repo root — flagged to the user,
  added `client_secret*.json` to `.gitignore` as a safety net, left the file untouched (never committed).
- Diagnosed a Gmail OAuth `403: Access Denied` from the user's description of the error plus the exact
  heading: the app is in Google's "Testing" publishing status requesting a restricted scope
  (`https://mail.google.com/`), and the user's own account wasn't yet on the OAuth consent screen's
  **Test users** list. Fix given: add the account there — no need to publish to Production, which would
  trigger Google's verification review for restricted scopes.
- **Built the real profile.** User pointed to `d:\Projects\PlacementPilot\Resumes\` — three role-targeted
  resumes (SDE, AI/ML, Data) not previously known to exist. Read all three, merged skills/projects into
  `config/preferences.json`, deliberately excluding the "PlacementPilot" project bullet each resume lists
  (self-referential — the tool describing itself as a completed project would be circular and is not yet
  true) and excluding contact details (phone/email) from the profile even though they're on the résumés.
  Broadened `queries` — the existing set skewed SDE/ML and had no data/BI or GenAI-specific term despite
  the Data and AI/ML resumes existing, so added `"generative ai intern india"` and
  `"data analyst intern india"`.
  Added `Resumes/` to `.gitignore` — the source PDFs carry phone/email, more sensitive than the derived
  profile text, and the project's own rule is no personal data outside `config/` and the credential store.
- **Next:** remaining accounts (Anthropic, Adzuna, Jooble) and their credentials in the n8n store, then
  Phase 1 workflows (WF-L0, WF-L1, WF-0, WF-1) against the now-live instance.

### 2026-08-14 — WF-L0 and WF-L1 built and tested against the live instance (continued)
- Bind-mounted `workflows/` into the n8n container so the CLI can `import:workflow`/`execute`/
  `publish:workflow` directly — no API key setup, no chat-exposed credentials.
- Pulled the exact node-type registry from the running instance (`n8n export:nodes`, 906 types) before
  writing any workflow JSON, so every node's parameters matched this specific n8n version instead of a
  guess. Full detail in `FLOW.md` "Changed this session."
- Built and CLI-tested `WF-L1 lib-normalize` and `WF-L0 lib-config` — not just imported, actually
  *executed* against the real Postgres and the real GitHub-hosted `config/sources.json`. Found and fixed
  two real bugs along the way (`$env` denied by default → switched to n8n's `$vars` Variables feature,
  matching the original design; `ignoreResponseCode` doesn't cover a non-JSON error body → switched to
  string response + manual parse). Both are now the standing pattern for every future HTTP node. Recorded
  in `DECISIONS.md`.
- Created the `pp-local-postgres` n8n credential via CLI import — this is our own Docker-internal
  database, not a third-party secret, so no chat exposure was needed; value came straight from `.env`.
- All test-only artifacts (a throwaway caller workflow, a seeded fake cache row, scratch test scripts)
  deleted after use; nothing test-related got committed.
- **Next:** WF-0 selftest + `db/seed_fixtures.sql`, then WF-1 collect-ats.

### 2026-08-14 — WF-0 built and verified (continued)
- Computed exact expected `id` hashes for 5 fixtures offline (container's own Node runtime, same logic
  WF-L1 runs), seeded `db/seed_fixtures.sql`: PhonePe dedup collapse, Groww noise-stripping, Gurgaon/
  Gurugram location-alias collapse.
- Built and CLI-tested `WF-0 selftest`. Found a second silent-zero-items bug (`Write Run`'s INSERT had no
  `RETURNING`, so the pass/fail check after it never ran despite execution status reading "success") — see
  `DECISIONS.md`, now a standing rule for every Postgres write in the project.
- Verified both directions for real: happy path (5/5 pass, `runs` row written) and failure path (seeded a
  deliberately wrong fixture, confirmed WF-0 reported the exact mismatch and threw, then deleted it).
- **Next:** WF-1 collect-ats.
