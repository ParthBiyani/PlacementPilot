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

**Phase: 0 (Foundations), in progress.**

| Item | State |
|---|---|
| Repo | Live at <https://github.com/ParthBiyani/PlacementPilot>, branch `main`. Config is fetchable at `https://raw.githubusercontent.com/ParthBiyani/PlacementPilot/main/config`. |
| Docker | **Not installed** — blocks Phase 0 exit. User action. |
| Node (host) | v6.10.1 — irrelevant, n8n runs in a container. Do not "fix" it. |
| Python / uv | 3.11.9 / 0.11.25 present — unused by design, all-n8n. |
| Postgres | Not running. Schema written but never applied. |
| n8n | Not running. |
| Accounts | **None created yet** — Anthropic, Discord, RapidAPI/JSearch, SerpApi, Adzuna, Jooble, Careerjet, Google Cloud. All user action. |
| Scaffolding | `db/schema.sql` (14 tables), `docker-compose.yml`, `.env.example`, `config/*`, `SETUP.md` all written. |
| Config files | Sources seeded with **15 board tokens probed live on 2026-08-13**. `preferences.json` still has **placeholder profile values** — blocks Phase 2. |
| Workflows | None built. |

**Blocked on the user:** Docker Desktop install · all account signups · real profile/preference values ·
starter company list approval · aggregator query set.

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
- [ ] **User:** install Docker Desktop + WSL2 backend
- [ ] **User:** create accounts — Anthropic, Discord, RapidAPI/JSearch, SerpApi, Adzuna, Jooble, Careerjet, Google Cloud
- [ ] **User:** supply real profile/preference values
- [x] Create GitHub remote, first commit, push
- [ ] Cloudflare Tunnel for the public webhook URL (needed from Phase 5)
- [ ] Apply schema to a running Postgres; verify config files fetchable over HTTPS

### Phase 1 — Config layer + ATS collection
- [ ] WF-L0 lib-config — fetch, validate, cache with ETag, fallback + alarm
- [ ] WF-L1 lib-normalize — normalization rules + exact key via Crypto node
- [ ] WF-0 selftest — fixtures through WF-L1, diff, alarm
- [ ] `db/seed_fixtures.sql`
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
