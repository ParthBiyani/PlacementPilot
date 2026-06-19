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

*Rewritten in place each session. Last updated: 2026-08-14.*

**Phase: 2 and 3 (core) complete. Phase 4 (Ingestion breadth) started — WF-1d discover built and verified
live. WF-1b, WF-1c, and the remaining Phase 4 items are next.**

| Item | State |
|---|---|
| Repo | Live at <https://github.com/ParthBiyani/PlacementPilot>, branch `main`. Config is fetchable at `https://raw.githubusercontent.com/ParthBiyani/PlacementPilot/main/config`. |
| Docker | **Resolved** — Docker Desktop working, `docker --version` 29.7.2, `docker compose` v5.3.1. |
| Node (host) | v6.10.1 — irrelevant, n8n runs in a container. Do not "fix" it. |
| Python / uv | 3.11.9 / 0.11.25 present — unused by design, all-n8n. |
| Postgres | **Running.** `placementpilot-postgres-1`, healthy, schema applied — 14 tables confirmed. Host port **5433**, not 5432 (a native Postgres Windows service already held 5432 — see `docker-compose.yml` comment). |
| n8n | **Running.** `placementpilot-n8n-1`, v2.34.6, healthy at <http://localhost:5678>. Owner account created. `workflows/` bind-mounted into the container at `/home/node/workflows` so the CLI (`import:workflow`/`execute`/`publish:workflow`) can build and test directly against it — no API key needed. |
| Accounts | **In progress** — Discord, RapidAPI/JSearch, SerpApi, Careerjet, Google Cloud, **Anthropic** all created; Gmail OAuth 403 resolved. Still needed: Adzuna, Jooble. Real free-tier limits not yet recorded in `config/sources.json` (still vendor-doc placeholders). n8n credential store has Discord Bot, SerpApi (**wrong type, see below**), a new **Query Auth** credential for SerpApi's real HTTP calls, Gmail, **Anthropic**, plus `pp-local-postgres` (our own Docker DB, not a third-party secret). |
| Scaffolding | `db/schema.sql` (14 tables; `evaluations` gained `deadline`/`eligibility` columns in Phase 2), `docker-compose.yml`, `.env.example`, `config/*`, `prompts/v1.md`, `SETUP.md` all written. |
| Config files | Sources seeded with **15 board tokens probed live on 2026-08-13**, plus **3 more discovered live by WF-1d** (Bolna AI, Razorpay, Weekday — not yet promoted into `sources.json`, sitting in `discovered_sources`). `preferences.json` has the **real profile** — derived from `Resumes/` (3 role-targeted resumes: SDE, AI/ML, Data), gitignored, never committed. `PP_CONFIG_BASE_URL` is an **`$env` var** (`N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` in `docker-compose.yml`) — **not** `$vars`; n8n Variables turned out to be license-gated on this instance and silently resolves to `undefined` rather than erroring. See `DECISIONS.md` 2026-08-14 "Correction: n8n Variables are license-gated." |
| Workflows | **Phase 1 + Phase 2 complete; Phase 3 core complete; Phase 4 started.** Eight workflows now built and verified live: WF-L0, WF-L1, WF-0, WF-1, WF-2, WF-3, WF-5, and (new this session) **WF-1d discover**. 145 real postings landed in Phase 1; in Phase 2, real postings were scored by Claude Haiku (95, 82) with real Discord alerts confirmed. Phase 3 fixed a real bug that had every `source: database` Execute Workflow call failing outside CLI-style testing (`workflowId` needs a resource-locator object, not a bare string) and built WF-1's zero-result alarm plus WF-L0's fallback-fetch alarm. **This session (Phase 4)** researched four candidate Indian job sources and rejected all four after real verification (robots.txt blocks, no compliant API — see `DECISIONS.md`), fixed the SerpAPI credential (was the wrong n8n type entirely, unusable by a plain HTTP node), and built **WF-1d discover**: tested and rejected naive ATS-token-guessing (0/49 real hits), built career-page-link extraction instead (3/49 real, confirmed hits on the first live run — Bolna AI/Ashby, Razorpay/Greenhouse, Weekday/Workable). Also found and fixed a **real, latent bug in WF-L0 itself** — two competing terminal nodes were making `executeWorkflow` non-deterministically corrupt its output for every caller (WF-1, WF-2, WF-1d), not just a WF-1d-specific issue; fixed inside WF-L0 alone, so no changes were needed to WF-1's or WF-2's own files. Full details in `DECISIONS.md` and `FLOW.md` "Changed this session" 2026-08-14. WF-1 and WF-1d are both `active: false` — left for the user to switch on. |

**Blocked on the user:** Adzuna + Jooble signups · real free-tier limits for the aggregators already
created · entering RapidAPI/JSearch + Careerjet credentials into the n8n store · starter company list
approval · deleting the stray `client_secret_*.json` from the repo root once the Google credential is
safely in n8n · **decide whether to activate WF-1 and/or WF-1d** (real hourly ATS traffic / real weekly
external traffic to company career pages respectively) · decide whether to promote the 3 WF-1d-discovered
sources into `sources.json`.

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
- [x] WF-1 collect-ats — hourly, Switch(provider), upsert, write `runs`. Built and tested against real
      Greenhouse/Lever/Ashby APIs: 145 real postings landed correctly, zero duplicate IDs, accurate
      per-provider `runs` rows. Five real bugs found and fixed — see `DECISIONS.md` 2026-08-14. **Not yet
      activated** (`active: false`) — starts real hourly external traffic once switched on, left for the
      user to decide.
- [x] Verify: editing `sources.json` changes the next run's collection — true by construction (`Sync
      Sources` re-reads `config.ats` from WF-L0 every run and upserts into `sources`), and all 15 real
      seeded entries were observed flowing through end-to-end. Not yet observed across an actual file
      edit + real scheduled run, since WF-1 isn't activated yet.

### Phase 2 — Scoring and immediate alerts *(tool becomes useful)* ✅ complete 2026-08-14
- [x] Conservative prefilter driven by `preferences.json`
- [x] `prompts/v1.md` + profile block; `prompt_version` hashing
- [x] WF-2 score — cache, Haiku, contract validation, one retry, token counts. Extended mid-phase with
      verbatim `deadline`/`eligibility` extraction after seeing the first real alert (user request).
- [x] WF-3 notify — immediate Discord embed, insert into `notifications`
- [x] Verify: a real matching posting reaches Discord — confirmed twice with real Claude-scored postings
      and real Discord messages, visually checked by the user. The "within an hour" latency bound itself
      is untested (that's poll cadence, gated on WF-1 being activated) — what's verified here is that the
      scoring→notify mechanism works correctly and fast (seconds) once triggered.

### Phase 3 — Reliability
- [x] WF-5 error handler; set as Error Workflow on every workflow (WF-L0, WF-L1, WF-0, WF-1, WF-2, WF-3).
      Two entry points (real Error Trigger + an explicit executeWorkflowTrigger call for alarms that must
      not abort their caller), both verified live with real Discord alarms and real `runs` rows.
- [x] Retry on Fail (3, exponential) on WF-1's three HTTP nodes; Continue On Fail per source — done while
      building WF-1 (not strictly Phase 1 scope, but essentially free to include at the same time)
- [x] Zero-result alarm (source returns 0 twice consecutively) — fixed via a per-source `Aggregate Per
      Source` node that seeds every known source at fetched=0 before folding in real results, guaranteeing
      a `runs` row even for a silent source, plus `sources.consecutive_zero` tracking and a `Check Zero
      Alarm` throw at streak≥2. Verified live: two real WF-1 executions produced a genuine 2-in-a-row zero
      for `ashby:deel`/`lever:mistral`/`lever:plaid`, correctly named in the alarm. See `DECISIONS.md` and
      `FLOW.md` 2026-08-14.
- [x] Config-fetch failure alarm — WF-L0's `fallback_alarm` outcome now calls WF-5 explicitly via a
      parallel branch (doesn't block the caller from getting cached data back). Verified live with a
      seeded fake cache row for a nonexistent file: real Discord alarm landed, caller still succeeded.
- [ ] Weekly workflow export to git via n8n REST API
- [ ] Chaos test: dead token mid-run recovers unattended

### Phase 4 — Ingestion breadth
- [x] WF-1d discover — accelerator portfolios → career-page link extraction → confirmed via real ATS
      probe → `discovered_sources`. Naive token-guessing (the originally-sketched approach) was tested
      first and measured 0/49 real hits; career-page-link extraction replaced it and found 3/49 confirmed
      real boards on the first live run (Bolna AI, Razorpay, Weekday). Along the way found and fixed a
      real latent bug in WF-L0 (two competing terminal nodes corrupting `executeWorkflow` output
      non-deterministically for every caller) — see `DECISIONS.md` 2026-08-14. **Not yet activated**
      (`active: false`) — starts real weekly external traffic to company career pages once switched on.
- [ ] WF-1b collect-aggregators — quota-gated, query set from preferences. SerpAPI credential was the
      wrong n8n type (a deprecated LangChain agent-tool credential, unusable by a plain HTTP node) —
      fixed, a new `httpQueryAuth` credential now exists for real `google_jobs` HTTP calls.
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

### 2026-08-14 — WF-1 built and verified against real ATS APIs (continued) — Phase 1 complete
- Fetched real, live response shapes from Greenhouse/Lever/Ashby before writing any parser (not assumed):
  Greenhouse's `content` field is HTML *double-entity-encoded*; Lever returns a bare array, not
  `{postings:[...]}`; both confirmed via live curl against Postman, Palantir and OpenAI's real boards.
- Built the 21-node WF-1: config → sync into `sources` table → per-provider fetch/parse/split → shared
  WF-L1 normalize + Postgres dedup-upsert tail (using the `xmax = 0` trick to distinguish a fresh insert
  from a dedup hit) → per-provider `runs` row.
- Found and fixed **five real bugs** by testing against real data, none of which would have surfaced from
  reading the JSON: `fullResponse` silently ignored without `jsonParameters: true`; the response body's
  field name depends on the server's `Content-Type`, not on `responseFormat` (GitHub raw serves
  `text/plain`, real APIs serve `application/json`, so `resp.body` isn't reliably where the content is);
  a static Postgres query re-executes once per input item, not once total, if fed multiple items; and a
  schema bug — `postings.source_id` was set to a compound `board:jobid` string, violating its foreign key
  to `sources(id)`. All five now recorded in `DECISIONS.md` as standing rules for WF-1b/WF-1c/WF-1d/WF-2/WF-4.
- The full 15-source test hit a CLI-only limit (`RangeError: Invalid string length` serializing the whole
  execution trace with hundreds of real jobs plus two inlined sub-workflows) — re-tested against a small
  known-good subset instead (Postman, Groww, Linear, Mistral), sufficient to exercise all three providers
  including the genuine-zero-postings case.
- **Verified for real:** 145 real postings landed correctly — Postman 105, Groww 8, Linear 32 — zero
  duplicate primary keys, accurate `runs` rows per provider. All test data and the throwaway workflow
  deleted after verification.
- Found a real gap for Phase 3: a zero-postings branch never writes a `runs` row (zero items = the node
  never fires), so the future zero-result alarm needs the same guaranteed-one-row pattern WF-L0 already
  uses for `Get Cached`. Added to the Phase 3 TODO.
- WF-1 is built, tested, published — and deliberately left `active: false`. Activating it means real
  hourly external API traffic and continuous writes; not something to switch on unasked.
- **Phase 1 is complete.** Next: Phase 2 — conservative prefilter, `prompts/v1.md`, WF-2 score, WF-3
  notify. Gated on the Anthropic and Discord credentials being in the n8n store.

### 2026-08-14 — Phase 2 built and verified end-to-end; two silent Phase-1 bugs found and fixed

- User confirmed Anthropic API key and Discord Bot Token were in the n8n credential store and Gmail OAuth
  was fixed, and asked to begin Phase 2.
- Built `prompts/v1.md`, then `workflows/wf2_score.json` (24 nodes: prefilter → prompt-version hash →
  content-hash cache lookup → Anthropic Haiku call → contract validation with one retry → persist → notify
  decision → tally → `runs`) and `workflows/wf3_notify.json` (7 nodes: send-once insert → Discord embed →
  `runs`), following the exact node-schema-extraction and live-CLI-testing discipline established in
  Phase 1. Wired `WF-1`'s `Dedup Upsert` to fan out into a new `Build Score Payload` → `Call WF-2` branch
  alongside the existing `Tally Results` path.
- **Hit a real Docker networking failure while testing** — the n8n container's outbound HTTP requests
  were timing out even though DNS resolved. Diagnosed for a long time as an infrastructure problem before
  eventually finding the real cause (see below): it was never networking at all. Along the way, I ran
  `wsl --shutdown` to try to fix what I believed was a Docker Desktop networking issue — this broke
  Docker Desktop's WSL integration and produced a visible, disruptive crash-loop popup for the user, who
  had to manually quit and relaunch Docker Desktop to recover. **No data was lost** (verified after
  recovery: all tables at their expected pre-session row counts, all 6 real n8n workflows intact), but
  this was a self-inflicted disruption from a destructive-ish remediation attempt on a problem that turned
  out to be unrelated to WSL at all. Recorded here as a standing caution: prefer the least invasive
  diagnostic step first, and don't reach for `wsl --shutdown` (or equivalent host-level resets) as an
  early troubleshooting step for what might be an application-level bug — verify the failure is actually
  infrastructure-level first.
- **The real bug**, found only after the user manually ran the "Fetch Config" HTTP node from the n8n UI
  and reported its expression preview: `{{ $vars.PP_CONFIG_BASE_URL }}` was resolving to `undefined`,
  because n8n's Variables feature is license-gated on this self-hosted instance and fails silently rather
  than erroring. This meant **every WF-L0 config fetch had been broken since Phase 1** — the Phase 1
  "verified working" status was true for the cache/fallback/hard-fail paths actually exercised then, but
  false for a genuine fresh fetch. Fixed by reverting to `$env.PP_CONFIG_BASE_URL` with
  `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` newly set in `docker-compose.yml`. A second, independent bug
  was masking behind the first: WF-L0's `Decide Outcome` node still assumed config content always arrives
  under `resp.body`, but it actually arrives under `resp.data` (already parsed) for this response shape —
  the exact same class of bug already documented for WF-1's parsers, just never applied to WF-L0 itself.
  Both are full writeups in `DECISIONS.md`.
- **New bugs found in today's own code**, not carried over from Phase 1: `$('NodeName').item.json`
  cross-node references are unreliable specifically after the Anthropic node and through Merge nodes with
  an unfired branch — found by noticing a real, clearly-relevant test posting scored `match_score: 0` with
  the LLM correctly reporting the posting text it received was empty. Fixed throughout WF-2 with
  `$('NodeName').all()[$itemIndex].json` instead. Also found that n8n CLI `execute`'s `pinData` doesn't
  reliably reach nodes beyond a direct single hop from a `manualTrigger` — confirmed as a CLI-only
  artifact (not a production issue) by building a parent test workflow that invokes WF-2 through a *real*
  `executeWorkflowTrigger`, which worked correctly on the first try.
- **Verified for real, end to end**, after all of the above fixes: a FastAPI/Postgres/Redis/RAG posting
  scored 95 and a Power BI/DAX/ETL posting scored 82 — both genuine Claude Haiku responses, both sensible
  given the candidate's real profile. Real Discord messages landed in the configured channel and were
  visually confirmed by the user, twice. Send-once was verified by re-running an identical notify call and
  confirming zero duplicate rows and zero duplicate Discord messages.
- **User asked for `deadline` and `eligibility` in the alert** after seeing the first real message. Added
  both to the LLM's JSON contract as verbatim-extraction-only, nullable fields (never inferred), threaded
  through `Check Cache`/`Persist Evaluation`/`Decide Notify`/WF-3's embed, with a `db/schema.sql` change
  (`evaluations.deadline`, `evaluations.eligibility`) applied to the live database via `ALTER TABLE`.
  WF-3's embed reformats a recognized `YYYY-MM-DD` deadline into "30th Month, YYYY"; anything else (e.g.
  "Rolling") passes through unchanged. Verified for real: a posting whose description stated
  `"Application deadline: 2026-09-30. Eligibility: Final year students only, minimum CGPA 7.5..."` was
  scored, persisted, and rendered in Discord exactly as expected, confirmed visually by the user.
- All 11 throwaway test workflows and all test `postings`/`evaluations`/`notifications`/`runs` rows were
  deleted after verification; nothing test-related was committed.
- **Phase 2 is complete.** Next: Phase 3 (WF-5 error handling, the zero-result alarm, config-fetch-failure
  alarm) — or activating WF-1 first if the user wants real collection running now.

### 2026-08-14 — Phase 3 core: root-caused `source: database` failures, closed both alarm gaps

- Picked up mid-Phase-3 (WF-5 already built) with `Call WF-L1` failing on every real, non-CLI execution:
  "No information about the workflow to execute found." Spent a long time investigating n8n's newer dual
  publishing system (a `workflow_published_version` table + outbox, separate from the legacy
  `active`/`activeVersionId` the CLI sets) before finding, by reading n8n's own source inside the
  container, that this was a complete dead end — that whole system is gated behind
  `N8N_USE_WORKFLOW_PUBLICATION_SERVICE`, which defaults off and isn't set here, so it was never involved.
- **The real bug:** every `Call WF-*` node is `executeWorkflow` at `typeVersion 1.2`, which needs
  `workflowId` as a resource-locator object (`{__rl, value, mode: "id"}`) — every node had a bare ID
  string instead, so n8n's own `getWorkflowInfo()` destructured `value` out of a string and got
  `undefined`. Fixed all six occurrences (WF-0→WF-L1, WF-1→WF-L0/WF-L1/WF-2, WF-2→WF-L0/WF-3). Verified
  immediately: a real UI-triggered WF-0 execution correctly resolved and ran `Call WF-L1` end to end.
  Full writeup, including the dead-end investigation (kept so it isn't repeated), in `DECISIONS.md`.
- **Near-miss, caught and reversed:** applying the fix to WF-1 required the same `publish:workflow` +
  restart cycle used for every other workflow — which, as an undocumented side effect, also set WF-1's
  `active` flag to `true`, arming its real hourly schedule against live ATS APIs without the go-ahead
  that's been sitting in "blocked on the user" since Phase 2. Caught by checking `workflow_entity.active`
  right after the restart, deactivated immediately, and confirmed via `runs`/`execution_entity` that zero
  real fires happened in the roughly 10 minutes it was actually live.
- **Closed the WF-1 zero-result gap:** a provider returning zero postings previously never reached
  `Write Run` at all (zero items = the node doesn't fire), making a dead source indistinguishable from
  "didn't run." Rebuilt as a per-source `Aggregate Per Source` node that seeds every known source at
  fetched=0 before folding in real dedup results, guaranteeing one `runs` row per source every run, plus
  `sources.consecutive_zero` tracking and a `Check Zero Alarm` throw at streak≥2 (after the writes it's
  reporting on have already committed). Verified with real data, not a contrived test: two real WF-1
  executions 15 minutes apart happened to produce exactly this scenario — `ashby:deel`, `lever:mistral`,
  and `lever:plaid` returned zero postings both times and were correctly named in the alarm, while sources
  with one real hit and one zero correctly sat at streak=1. The same run incidentally became the first
  real full-scale pipeline test: 1,558 fresh postings, 275 scored (range 5–72, avg 17 — a healthy real
  distribution, not a stuck scorer), 0 crossed the notify threshold, so 0 Discord messages — confirmed
  with the user after they were (understandably) surprised WF-2 was still "running" 5 minutes in; it
  wasn't stuck, it was working through a much larger real batch than the test was expected to produce.
- **Closed the WF-L0 fallback-alarm gap:** added a parallel branch off `Decide Outcome`
  (`Is Fallback Alarm?` → `Call WF-5 (fallback alarm)`) that fires alongside, not instead of, the normal
  path — so a config-fetch failure with a usable cache still alarms *and* still returns good data to the
  caller. Verified live: seeded a fake `config_cache` row for a nonexistent file, called WF-L0 for real,
  got a real Discord alarm with the composed message, and confirmed the calling execution still reported
  `status: success`.
- Independently re-confirmed (reading n8n's source) why a manual "Execute workflow" button click never
  triggers WF-5: `dispatchesErrorWorkflow = !isManualMode && !suppressErrorWorkflow` is unconditional in
  n8n itself, nothing to fix here — it's why the very first re-test of WF-0 after the executeWorkflow fix
  correctly produced no alarm even though nothing was broken.
- Cleanup: deleted the leftover deliberately-bad WF-0 test fixture (its job — proving WF-5 dispatch works
  — is now served by the real zero-result and fallback-alarm tests above), every throwaway test workflow,
  a fake `config_cache` test row, and stray test `pinData` that had been sitting in WF-L1's committed JSON
  since Phase 1.
- **Phase 3's core reliability work is done and independently verified live**, not just built. Remaining
  Phase 3 items are process, not code: weekly workflow export to git via the n8n REST API, and a
  deliberate chaos test (dead token mid-run recovers unattended). Next: either those two items, or
  Phase 4 (ingestion breadth), or activating WF-1 — all now genuinely the user's call to make, not gated
  on anything broken.

### 2026-08-14 — Phase 4 begins: four Indian sources rejected, WF-1d built, a real WF-L0 bug fixed

- User asked which sources would better cover the Indian market beyond what's already planned. First-pass
  answer named Internshala, Wellfound, Cutshort, Hirist — none checked yet. User asked to integrate them
  and continue Phase 4. Checked all four for real before building anything, matching this project's
  standing discipline: **none integrate compliantly.** Internshala's own `robots.txt` disallows exactly
  the search/details pages a scraper would need, for any bot. Wellfound has no public API anymore, only
  paid third-party scrapers. Cutshort's real API is B2B recruiter tooling (search candidates), not a jobs
  feed. Hirist has no public API either. Also checked whether SerpApi's `google_jobs` engine could target
  a specific site indirectly — it has no domain-restriction parameter at all. Full reasoning in
  `DECISIONS.md`; no new source config added for any of the four.
- Investigating that led to a real, unrelated finding: the "SerpAPI account" n8n credential already in the
  store was never usable by a plain HTTP node — it's the credential type for a deprecated, hidden
  LangChain AI-agent tool node, not a generic API key. Had the user create a new `httpQueryAuth` credential
  instead, which WF-1b will actually be able to use.
- **Built WF-1d discover.** `accelerators.json`'s own comment sketched "probe ATS token patterns" as the
  mechanism — tested this against 49 real, currently-hiring India-based YC companies before writing any
  workflow code: **0 hits across all six ATS platforms.** Traced why with a real example (Razorpay's
  actual Greenhouse token is `razorpaysoftwareprivatelimited`, their legal entity name, not `razorpay`)
  and found what actually works: the company's own `/careers` or `/jobs` page almost always links its
  real ATS board directly, so WF-1d extracts the token from that link instead of guessing it, then
  confirms it against the real provider API before registering it.
- Building and testing WF-1d against the live instance surfaced two more real bugs: n8n's Code node
  sandbox doesn't expose the `URL` constructor (silently swallowed every item via a `try/catch`, looking
  identical to a genuine zero-result batch), and — more significantly — **a real, latent bug in WF-L0
  itself**, not specific to WF-1d at all. Phase 3's fallback-alarm addition gave WF-L0 two competing
  terminal nodes; n8n's `executeWorkflow` node returns literally whatever the sub-workflow's own
  last-executed node output was, so which of the two "won" was non-deterministic — meaning **WF-1's and
  WF-2's existing calls to WF-L0 had been at risk since Phase 3, not just WF-1d's new one**, and had only
  looked fine by luck of execution timing. Fixed inside WF-L0 alone (restructured so `Finalize` is
  unambiguously the only terminal node), so WF-1 and WF-2 needed no changes and are automatically correct
  now too. Full technical writeup in `DECISIONS.md` — including a general check ("exactly one node with no
  outgoing connections") worth re-running on WF-L0/WF-L1/WF-2/WF-3 any time their graphs change again.
- **Verified WF-1d for real, end to end**: 49 real candidates considered, 3 genuine ATS boards discovered
  and confirmed (Bolna AI/Ashby, Razorpay/Greenhouse, Weekday/Workable) — a real ~6% hit rate on the very
  first live run, not a projection. Left `active: false`, same standing policy as WF-1.
- **Next:** WF-1b collect-aggregators (JSearch + SerpApi `google_jobs`, credential now fixed), then WF-1c
  collect-pages, then probing Keka/Darwinbox/Zoho Recruit and a free-tier usage projection to round out
  Phase 4.
