# FLOW.md — execution flow

How the system runs: entry points, execution order, what calls what, and the path a single posting takes
from a job board to a Discord message.

> **Status legend:** ✅ built · 🚧 in progress · ⬜ designed, not built.
> Update this file whenever a node graph or a call path changes, and fill in
> **Changed this session** before ending a session.

---

## Entry points

Every workflow is entered exactly one way. Nothing is invoked ad hoc.

| Workflow | Entry | Cadence | Status |
|---|---|---|---|
| `WF-L0` lib-config | Execute Workflow (called by others) | on demand | ✅ |
| `WF-L1` lib-normalize | Execute Workflow (called by others) | on demand | ✅ |
| `WF-0` selftest | Schedule Trigger | daily | ✅ |
| `WF-1` collect-ats | Schedule Trigger | hourly | ✅ (built, tested; **not yet activated**) |
| `WF-1b` collect-aggregators | Schedule Trigger | daily | ✅ (SerpApi built+verified; JSearch scaffolded only — **not yet activated**) |
| `WF-1c` collect-pages | Schedule Trigger | daily | ✅ (built, tested; **not yet activated**) |
| `WF-1d` discover | Schedule Trigger | weekly | ✅ (built, tested; **not yet activated**) |
| `WF-2` score | Execute Workflow (from collectors) | per batch | ✅ |
| `WF-3` notify | Execute Workflow (from WF-2) | per posting | ✅ |
| `WF-3b` inbound | **Webhook** — the only public surface | on interaction | ⬜ |
| `WF-4` gmail | Gmail Trigger | 15 min | ⬜ |
| `WF-5` error | Error Workflow on every workflow above | on failure | ✅ |
| `WF-6` eval | Manual Trigger / pre-promotion | on demand | ⬜ |

---

## The main path: a posting from board to Discord

This is the flow that matters. Everything else is support.

```
Schedule (hourly)
  │
  ├─► WF-L0 lib-config ──► HTTPS GET config/sources.json
  │        │                 ├─ 200 → validate shape → upsert config_cache (etag, body)
  │        │                 ├─ 304 → serve cached body
  │        │                 └─ fail → serve last good body ─► ALARM (never silent)
  │        ▼
  │   active sources (kind='ats', poll_tier='hourly')
  │
  ├─► Loop Over Items ──► Switch (provider)
  │        ├─ HTTP  boards-api.greenhouse.io/v1/boards/{token}/jobs
  │        ├─ HTTP  api.lever.co/v0/postings/{token}?mode=json
  │        ├─ HTTP  api.ashbyhq.com/posting-api/job-board/{token}
  │        └─ …workable / smartrecruiters / recruitee
  │        (each: Retry on Fail ×3 exponential · Continue On Fail · ≤1 req/s)
  │
  ├─► WF-L1 lib-normalize ──────────────────────────────┐
  │        lowercase · strip legal suffixes · strip      │  single source of truth;
  │        seniority + req-IDs · collapse location       │  WF-0 tests THIS, not a copy
  │        aliases · Crypto node → sha256 keys           │
  │        emits: id, content_hash, norm_company,        │
  │               norm_description                       │
  │                                                      ▼
  ├─► Postgres: exact-key dedup on postings.id
  │        ├─ hit  → bump last_seen → STOP
  │        └─ miss → INSERT posting (RETURNING now includes source_id)
  │
  ├─► Aggregate Per Source: seed one entry per source from "Get Active ATS
  │        Sources" BEFORE folding in dedup results — guarantees a runs row
  │        even when a source returns zero postings (LEFT-JOIN-style, same
  │        idea as WF-L0's Get Cached)
  │        ├─► write runs row per source (fetched / new / deduped)
  │        └─► UPDATE sources.consecutive_zero (+1 on zero, reset on >0)
  │                └─► Check Zero Alarm: throw if any source's streak ≥ 2
  │                        (after both writes above already committed)
  │                        → WF-5 via errorWorkflow
  │
  └─► WF-2 score  (only for genuinely new postings)
           │
           ├─ Code: conservative prefilter  ◄── preferences.json via WF-L0
           │     excluded role keyword → location not remote/allowed →
           │     experience > max → grad-year excluded
           │     reject reason → runs.prefilter_reasons
           │     AMBIGUOUS ALWAYS PASSES THROUGH
           │
           ├─ Crypto: hash prompt_version = sha256(system_message)
           │     system_message = template with profile interpolated,
           │     identical for every posting in this batch
           │
           ├─ IF prefilter_passed? ── false → dropped (counted in Tally, no further node)
           │
           ├─ Postgres "Check Cache": SELECT ... LEFT JOIN evaluations
           │     key = (content_hash, prompt_version, model)
           │     identity fields (posting_id/company/role/location/…) ride through
           │     as literal SELECT params, not read back from upstream nodes —
           │     see the pairedItem decision below for why
           │     ├─ hit  → Use Cached Evaluation, cache_hits++
           │     └─ miss → Anthropic "Score Posting" (Haiku, real API call)
           │                 ├─ Code: validate contract
           │                 │     { match_score 0-100, should_apply, reason ≤300,
           │                 │       missing_skills ≤5, deadline, eligibility }
           │                 │     deadline/eligibility: extracted verbatim, never inferred
           │                 │     ├─ valid   → Finalize From Attempt 1
           │                 │     └─ invalid → Score Posting Retry (error appended)
           │                 │                    → Validate Attempt 2 (final, either way)
           │                 │                       invalid twice → evaluations.invalid=true,
           │                 │                       never dropped
           │                 └─► Merge "LLM Result" (2 in: valid-first-try / after-retry)
           │
           ├─ Merge "For Persist" (2 in: Use Cached Evaluation / Merge LLM Result)
           ├─ Postgres "Persist Evaluation": INSERT ... ON CONFLICT DO UPDATE
           │     (never DO NOTHING here — must always return a row, cache hits included)
           │     RETURNING the authoritative persisted row
           │
           ├─ Code "Decide Notify": match_score ≥ preferences.notify.min_score
           │     AND should_apply AND NOT invalid
           │
           └─ IF should_notify
                    │
                    └─► WF-3 notify
                             ├─ Code "Prepare Notification": reshape for the insert
                             ├─ Postgres "Insert Notification": INSERT notifications
                             │     ON CONFLICT (posting_id, channel) DO NOTHING
                             │     UNIQUE(posting_id, channel) ← N4 lives here.
                             │     conflict → 0 rows → downstream never fires → already sent, STOP
                             │     (identity fields ride through as SELECT params here too)
                             ├─ Code "Build Embed": formats deadline (YYYY-MM-DD → "30th
                             │     Month, YYYY"; anything else, e.g. "Rolling", passes through)
                             └─ Discord: embed with company, role, location, type, deadline,
                                eligibility, score, reason, missing skills, apply link
                                (buttons are Phase 5 — WF-3b)
```

**Latency budget (N2):** poll cadence dominates. Hourly ATS polling puts p95 under ~1h; the pipeline
itself is seconds. Aggregators and career pages are daily because they are quota-bound, not because they
are slow.

---

## Independent paths

### Inbound interactions — `WF-3b`
```
Discord ──► Webhook (public, via tunnel)
   └─► Code: verify Ed25519 X-Signature-Ed25519 + X-Signature-Timestamp
            FIRST NODE. Import-free pure JS (no npm — N1).
            Discord will not register an endpoint that fails this,
            and sends unsigned probes that must be rejected.
       ├─ type 1 PING → respond { type: 1 }
       └─ type 3 MESSAGE_COMPONENT
              └─► parse custom_id → Postgres UPDATE applications.status
                  └─► Discord: edit original message in place
```

### Aggregators — `WF-1b`
```
Schedule (daily)
  └─► WF-L0 → sources.json (aggregators + monthly_limit) AND preferences.json
      (queries + x_search_queries) — two separate Call WF-L0 invocations
      └─► filter aggregators to enabled === true (currently: serpapi only;
          jsearch scaffolded but disabled — no credential, real response
          shape never observed, deliberately left unimplemented)
          └─► check api_quota (guaranteed-row LEFT JOIN, same pattern as
              WF-L0's Get Cached) → skip if used ≥ monthly_limit
              └─► By Provider (switch)
                  └─► SerpApi: build query list, capped by remaining quota
                      ├─ type=job (google_jobs engine, daily, ~7/day):
                      │  structured jobs_results[] parsed directly, no LLM
                      └─ type=x_search (google engine w/ site:x.com, WEEKLY
                         only — getUTCDay()===0 — shares the SAME quota
                         bucket as the job queries above):
                         organic_results[] filtered to individual /status/
                         tweet links → Anthropic extracts company/role/
                         location/employment_type from the snippet text
                         (zero requests ever sent to x.com/twitter.com —
                         see DECISIONS.md 2026-08-14)
                  └─► (both routes reconverge) → WF-L1 normalize → dedup
                      upsert (source_id always NULL — no per-company
                      sources row for an aggregator, same as WF-1c) →
                      update api_quota.used → WF-2 score
```

### Career pages — `WF-1c`
```
Schedule (daily)
  └─► WF-L0 → preferences.json (exclude.role_keywords)
      ├─► Fetch cutshort.io/sitemap_jobs.xml → keep entries with real
      │   per-job lastmod in the last 24h (~4-5k/day; their own lastmod
      │   values are genuine, unlike Hirist's)
      └─► Fetch hirist.tech's jobs sitemap → ALL entries (lastmod is
          bulk-touched on every site rebuild, same value for every URL,
          not usable for date filtering)
              └─► Merge → slug keyword prefilter (coarse, lossy — controls
                  volume/cost before the expensive step below, NOT the
                  same guarantee as WF-2's own conservative prefilter)
                  → cap at MAX_CANDIDATES_PER_RUN
                      └─► anti-join vs postings.apply_url (skip already-
                          collected) → politely fetch each page (1 req/s
                          Cutshort, mandatory 10s wait per Hirist request)
                          └─► Anthropic: extract {company, role, location,
                              employment_type, description, posted_date}
                              from stripped page text, or {not_a_posting}
                              └─► WF-L1 normalize → dedup upsert
                                  (source_id always NULL here — no
                                  per-company sources row exists for a
                                  Tier D collector, unlike WF-1's ATS
                                  boards; source text column carries
                                  'cutshort'/'hirist' instead)
                                  └─► WF-2 score (only genuinely new postings)
```
`robots_cache` (schema.sql) isn't used by this build — Cutshort's and Hirist's `robots.txt` were checked
by hand before building, not re-verified live per run, and there's no ETag/conditional-request layer on
the sitemap fetches yet. Worth adding if a third Tier D source needs the same treatment.

### Gmail — `WF-4`
```
Gmail Trigger (15m, read-only)
  └─► cache check on message ID
      └─► Anthropic classify {oa|interview|rejection|offer|referral|other}
          └─► Code: extract company / role / deadline
              └─► fuzzy-match to postings.company
                  └─► IF ≠ other → WF-3 notify + UPDATE applications
```

### Discovery — `WF-1d`
```
Schedule (weekly)
  └─► WF-L0 → accelerators.json (enabled + method:'json' entries only, e.g. yc)
      └─► fetch portfolio (e.g. YC's ~10MB companies dataset)
          └─► filter: India-located · isHiring · status=Active
              └─► per candidate company, try /careers · /jobs · homepage
                  └─► regex-extract a known ATS domain link (greenhouse/lever/
                      ashby/workable/smartrecruiters/recruitee) from whichever
                      page responded — NOT a guessed token. Guessing from the
                      company's slug was tried and measured 0/49 real hits;
                      extracting from the company's own career-page link is
                      what actually finds boards (see DECISIONS.md 2026-08-14).
                      Confirmed live: 3/49 real hits on the first run.
                      ├─► confirm the extracted token against the real
                      │   provider API pattern (same boards-api.greenhouse.io-
                      │   style probes WF-1 already uses)
                      └─► INSERT discovered_sources (probe_result, promoted=false)
   Promotion into `sources` is a deliberate manual step, not automatic.
   Never writes back to config/ — the owner's files stay theirs.
```

### Self-test — `WF-0`
```
Schedule (daily)
  └─► SELECT * FROM test_fixtures
      └─► run input through WF-L1 (the same sub-workflow production uses)
          └─► diff against expected
              └─► mismatch → ALARM
```

### Errors — `WF-5`
Set as `settings.errorWorkflow` on every workflow above (WF-L0, WF-L1, WF-0, WF-1, WF-2, WF-3, WF-5
itself). Two independent entry points feed the same shared tail:
```
Error Trigger (real thrown error, dispatched by n8n itself — NOT on manual/editor executions)
        │
        ├─ payload shape varies: {execution:{...}} when an executionId exists,
        │  {trigger:{...}} for internal errors (e.g. WorkflowActivationError) —
        │  both handled defensively
        │
"When Called Explicitly" (executeWorkflowTrigger — used for alarms that must
NOT abort the caller, e.g. WF-1's zero-result alarm and WF-L0's fallback alarm,
both of which need their own execution to keep succeeding)
        │
        ▼
Build Alarm Message ──► Send Alarm (Discord)
                    └──► Write Error Run (INSERT runs)
```
- **Source returned 0 postings twice consecutively** → WF-1's own `Check Zero Alarm` node throws (real
  thrown error → Error Trigger path). Verified live: two real, independently-triggered WF-1 executions
  produced exactly this for `ashby:deel`/`lever:mistral`/`lever:plaid`.
- **Config fetch failed but a cached fallback exists** → WF-L0 calls WF-5 explicitly (`Is Fallback
  Alarm?` → `Call WF-5 (fallback alarm)`), so WF-L0 still returns the good cached config to its own
  caller. Verified live: real Discord alarm landed while the calling execution still reported success.
- Daily spend cap enforcement (`SUM(cost_usd) > cap → deactivate WF-2`) is still Phase 9, not built.

---

## Call graph

```
WF-L0 lib-config   ◄── WF-1, WF-1b, WF-1c, WF-1d, WF-2      (config for everything)
WF-L1 lib-normalize◄── WF-1, WF-1b, WF-1c, WF-0             (normalization for everything)
WF-2 score         ◄── WF-1, WF-1b, WF-1c
WF-3 notify        ◄── WF-2, WF-4
WF-5 error         ◄── all (as Error Workflow)
```

Only `WF-L0` and `WF-L1` are shared. Nothing else is called by more than one parent, which keeps the
graph a tree with two utility leaves rather than a mesh.

---

## Data model touchpoints

| Table | Written by | Read by |
|---|---|---|
| `sources` | `WF-1d`, seed | all collectors |
| `discovered_sources` | `WF-1d` | `WF-1d` |
| `postings` | collectors | `WF-2`, `WF-6` |
| `evaluations` | `WF-2` | `WF-2` (cache), `WF-6` |
| `notifications` | `WF-3` | `WF-3` (uniqueness), `WF-3b` |
| `applications` | `WF-3b`, `WF-4` | queries |
| `runs` | everything | `WF-5`, queries |
| `api_quota` | `WF-1b` | `WF-1b` (checked *before* spending) |
| `config_cache` | `WF-L0` | `WF-L0` |
| `robots_cache` | — | — (not used — see note) |
| `prompts` | manual, `WF-6` promotion | `WF-2` |
| `eval_runs` | `WF-6` | promotion gate |
| `test_fixtures` | seed | `WF-0` |

---

## Changed this session

### 2026-08-13
Repository was empty apart from `PRD.md`. No workflows exist yet; every entry above is ⬜ designed.

Created:
- `.gitignore`, `CLAUDE.md`, `DECISIONS.md`, `FLOW.md`
- `db/schema.sql` — 14 tables. Load-bearing details: `UNIQUE(posting_id, channel)` on `notifications`
  (the whole of N4), the `pg_trgm` GIN index on `postings.norm_description`, and the partial unique index
  making only one prompt `active` at a time.
- `docker-compose.yml` — Postgres 16 + n8n. Deliberately omits `NODE_FUNCTION_ALLOW_EXTERNAL`/`_BUILTIN`
  so Code nodes stay import-free and Cloud-portable.

Verified externally (not assumed):
- Greenhouse `boards-api.greenhouse.io/v1/boards/{token}/jobs` → 200
- Ashby `api.ashbyhq.com/posting-api/job-board/{token}` → 200
- Lever `api.lever.co/v0/postings/{token}?mode=json` → 200 on a valid token
- Live board tokens confirmed: greenhouse `stripe`, `databricks`, `postman`, `groww`, `phonepe`,
  `slice`, `turing` · lever `plaid`, `mistral` · ashby `linear`, `vanta`, `openai`, `notion`, `ramp`, `deel`

### 2026-08-14 — WF-L1 and WF-L0 built and verified against a live instance

Docker resolved and the real profile landed (own entries above). With a running n8n, workflows are no
longer authored blind — every node type's exact parameter schema was pulled from the live instance via
`n8n export:nodes` (906 node types, ground truth for this exact n8n version) before writing any workflow
JSON, then each workflow was imported and executed via the n8n CLI (`import:workflow`, `execute`,
`publish:workflow`) against the real Postgres and the real GitHub-hosted config — not just checked for
valid JSON.

**`workflows/wf_l1_normalize.json` — built, tested, correct.** Trigger (Execute Workflow Trigger,
passthrough) → Code "Normalize" (strip legal suffixes/seniority/req-IDs, collapse location aliases) →
Crypto "Hash Exact Key" (SHA-256 of `norm_company|norm_role|norm_location` → `id`) → Crypto "Hash Content"
(SHA-256 of `norm_description` → `content_hash`) → Code "Shape Output". CLI `execute` ignores pinned
trigger data in this n8n version, so correctness was verified by running the identical normalize logic
directly in the container's own Node runtime against three cases: two differently-cased/differently-sourced
variants of the same PhonePe posting collapsed to the identical `id` (the core dedup guarantee), and a
noisy Groww role (`"Senior Backend Engineer (Remote) #4521"`) correctly stripped to `"backend engineer"`
with a distinct `id`. All three checks passed.

**`workflows/wf_l0_config.json` — built, tested, correct.** Trigger → Postgres "Get Cached" (LEFT JOIN
against a synthetic single row, so a first-ever fetch with no cache still yields exactly one item rather
than zero) → HTTP "Fetch Config" → Code "Decide Outcome" → IF "Is Fresh?" → Postgres "Upsert Cache" (both
branches) → Code "Finalize". Two real bugs were found and fixed by testing against the live instance
rather than assumed away — see `DECISIONS.md` 2026-08-14 "Two HTTP Request pitfalls": `$env` access is
denied by default (switched to n8n's Variables feature, `$vars`, matching the original design intent) and
`ignoreResponseCode` does not cover a non-JSON error body (switched to `responseFormat: "string"` with
manual `JSON.parse`). Tested end-to-end against `config/sources.json`'s real raw GitHub URL: `fresh` (200,
cache row written with the real ETag, 15 ATS sources counted), `cached_not_modified` (a second run
correctly got a 304 and served the cache untouched), `fallback_alarm` (a seeded stale cache plus a
guaranteed-404 file correctly fell back and still reported execution success), `hard_fail_alarm` (no cache
and a guaranteed-404 file correctly threw — this is what WF-5 will catch once Phase 3 wires it).

Both workflows are imported and published in the local instance. The `PP_CONFIG_BASE_URL` Variable is
seeded in `n8n.variables`; the `pp-local-postgres` credential is seeded in the n8n credential store (its
own Docker-internal database, not a third-party secret — created via `n8n import:credentials` from the
value already in `.env`, never pasted through chat). All test-only artifacts (a throwaway caller workflow,
a seeded fake cache row, scratch JS files) were deleted after use; nothing test-related was committed.

**Next:** WF-0 selftest and `db/seed_fixtures.sql`, then WF-1 collect-ats — the Switch/Schedule Trigger
parameter schemas are already extracted and ready to use.

### 2026-08-14 — WF-0 built and verified (continued)

**`workflows/wf0_selftest.json` — built, tested, correct.** Schedule Trigger (daily) → Postgres "Get
Fixtures" (`WHERE kind = 'normalize'`) → Code "Prepare WF-L1 Input" → Execute Workflow "Call WF-L1"
(`source: database`, the real production reference) → Code "Diff Against Expected" (compares each fixture's
`expected` keys against WF-L1's actual output, paired by array position via `$('Get Fixtures')`) → Code
"Summarize" → Postgres "Write Run" → IF "Is All Passed?" → Code "Finalize" or Code "Alarm" (throws).

`db/seed_fixtures.sql` seeds 5 frozen cases whose `expected.id` values were computed once, offline,
against the real normalize logic running in n8n's own Node runtime — not guessed: a PhonePe posting
arriving from two different sources with different casing collapses to the same `id` (the core dedup
guarantee); a Groww posting with seniority/parenthetical/req-id noise strips correctly; "Gurgaon" and
"Gurugram" collapse to the same `id` (location-alias guarantee).

Testing method: CLI `execute` requires either a Manual Trigger or an Execute Workflow Trigger as the entry
node — Schedule Trigger is not directly invocable that way. The **committed** file keeps its real Schedule
Trigger and its real `source: database` reference to WF-L1 (matching Phase 0 wiring). A throwaway copy
swapped only the trigger node and inlined WF-L1's JSON via `source: parameter`, exactly the same pattern
used for WF-L0, then was deleted after use.

Verified both directions: the happy path (5/5 fixtures pass, a `runs` row written, no throw) and the
failure path (a deliberately wrong fixture seeded, run, confirmed WF-0 correctly reported
`1/6 fixtures mismatched` with the exact field/expected/actual, threw, execution status `error`) — then
the deliberate fixture and its `runs` rows were deleted.

Found the second silent-zero-items bug of the session in `Write Run`'s missing `RETURNING` clause — see
`DECISIONS.md` 2026-08-14 "Postgres `executeQuery` writes need `RETURNING`."

**Next:** WF-1 collect-ats.

### 2026-08-14 — WF-1 built and verified against real ATS APIs (continued)

**`workflows/wf1_collect_ats.json` — built, tested, correct. 21 nodes.** Schedule Trigger (hourly) → Code
"Request Sources Config" → Execute Workflow "Call WF-L0" (`source: database`) → Code "Extract ATS Entries"
(reads `config.ats`) → Postgres "Sync Sources" (upserts each entry into `sources`, `kind='ats'`,
`origin='manual'`) → Code "Collapse To Single Trigger" (see Finding 5 below — required so the next query
runs once, not once per synced source) → Postgres "Get Active ATS Sources" (`WHERE kind='ats' AND
active=true` — reads back from `sources`, not from config directly, so `WF-1d`'s future discovered
sources join the same stream automatically) → Switch "By Provider" (string match on `provider`, 3 rules +
`fallbackOutput: -1` for not-yet-supported providers) → three parallel branches (HTTP fetch → Code parse →
Split Out `postings`), one per provider → **all three converge on the same tail**: Execute Workflow
"Call WF-L1" (`source: database`) → Postgres "Dedup Upsert" (`ON CONFLICT (id) DO UPDATE SET
last_seen = now() RETURNING id, (xmax = 0) AS was_inserted` — the `xmax` trick distinguishes a fresh
insert from a dedup hit) → Code "Tally Results" → Postgres "Write Run".

Each provider branch is a **separate wave** through the shared tail (n8n runs a shared downstream node
once per incoming connection that actually carries items, not once combined) — verified directly: the
Greenhouse wave (115 items) and the Ashby wave (32 items) each independently executed `Call WF-L1` through
`Write Run`, producing two separate `runs` rows, one per provider. This is the right granularity for the
Phase 3 zero-result alarm (per-source, not per-run).

Real per-provider response shapes were fetched and inspected live before writing any parser — not
assumed:
- **Greenhouse** `jobs[].{id, title, location.name, absolute_url, updated_at, content}` — `content` is
  HTML **double-entity-encoded** (`&lt;div&gt;`), decoded then tag-stripped before storing as `description`.
- **Lever** is a bare JSON array (not `{postings:[...]}`):
  `[].{id, text, categories.{location, commitment}, hostedUrl, applyUrl, createdAt (epoch ms), descriptionPlain}`.
- **Ashby** `jobs[].{id, title, employmentType, location, jobUrl, applyUrl, publishedAt, descriptionPlain}`.

Found and fixed five real issues by testing against live data, not by re-reading the JSON — three are new
standing HTTP/Postgres pitfalls (`DECISIONS.md` 2026-08-14 "Three more pitfalls..."), one is the schema
bug of setting `postings.source_id` to a compound `board:jobid` string instead of the plain board id (FK
violation), and the `Get Active ATS Sources` per-item-re-execution bug is now fixed with a
`Collapse To Single Trigger` node.

**Testing method:** same pattern as WF-L0/WF-0 — the committed file keeps its real `Schedule Trigger` and
real `source: database` references to WF-L0 *and* WF-L1 (both inlined only in a throwaway test copy). The
full 15-source set hit a CLI-only limitation (`RangeError: Invalid string length` — the CLI dumps the
*entire* execution trace as one JSON blob at the end; Ashby alone returns 734 jobs for OpenAI, and with
both sub-workflows also inlined the trace exceeded V8's string limit) — this does not affect production,
which runs inside the server process and never serializes a trace this way. Re-tested against a small
known-good subset (`greenhouse:postman`, `greenhouse:groww`, `ashby:linear`, `lever:mistral`) instead,
which was sufficient to exercise all three providers plus the zero-postings case (Lever/Mistral genuinely
has no live postings right now) without hitting the harness ceiling.

**Verified real result:** 145 real postings landed correctly — Postman 105, Groww 8, Linear 32 — zero
duplicate primary keys, accurate `runs` rows (`fetched`/`new_count`/`deduped`) per provider. All test data
(`sources`/`postings`/`runs` rows, the throwaway workflow) deleted after verification.

**Known gap, deliberately deferred to Phase 3:** a provider branch that fetches successfully but finds
*zero* postings (e.g. Lever/Mistral) never reaches `Write Run`, because zero items flowing into a node
means it doesn't fire — so no `runs` row gets written for a genuine zero-result fetch. The Phase 3
zero-result alarm needs this distinguished from "branch never ran"; likely fix is the same
`LEFT JOIN`-against-a-synthetic-row pattern used in WF-L0's `Get Cached`, applied so the tail always gets
at least one item even when `postings` was empty.

**WF-1 is built, tested, and published — but left `active: false`.** Activating it starts real hourly
external API traffic and continuous writes; that's the user's call, not something to flip on unasked.

**Next:** Phase 1 complete. Phase 2 (scoring + immediate Discord alerts) is next, gated on the Anthropic
and Discord credentials being in the n8n store and the profile threshold being tuned.

### 2026-08-14 — WF-2 and WF-3 built and verified end-to-end against real Postgres, real Anthropic, real Discord (continued) — Phase 2 complete

**`workflows/wf2_score.json` — built, tested, correct. 24 nodes.** Execute Workflow Trigger (passthrough)
→ Code "Request Preferences" → Execute Workflow "Call WF-L0" → Code "Prefilter" (reads the full posting
batch via `$('When Executed by Another Workflow').all()`, since Call WF-L0 replaces the trigger's items
with config; applies only the two deterministic checks — excluded role keyword, location outside the
allowed set/remote/India — everything ambiguous passes) → Crypto "Hash Prompt Version" → IF "Prefilter
Passed?" → Postgres "Check Cache" (LEFT JOIN, guaranteed one row, identity fields riding through as
literal SELECT params — see the pairedItem decision) → IF "Cache Hit?" → either Code "Use Cached
Evaluation" or Anthropic "Score Posting" → Code "Validate Attempt 1" → IF "Attempt 1 Valid?" → either Code
"Finalize From Attempt 1" or (Anthropic "Score Posting Retry" → Code "Validate Attempt 2") → Merge "LLM
Result" → Merge "For Persist" → Postgres "Persist Evaluation" (`ON CONFLICT ... DO UPDATE`, never `DO
NOTHING` — a cache-hit row must still return exactly one row) → Code "Decide Notify" → IF "Should
Notify?" → Execute Workflow "Call WF-3" → Merge "Post Notify" → Code "Tally" → Postgres "Write Run".

**`workflows/wf3_notify.json` — built, tested, correct. 7 nodes.** Execute Workflow Trigger → Code
"Prepare Notification" (reshapes, joins `missing_skills` into display text) → Postgres "Insert
Notification" (`ON CONFLICT (posting_id, channel) DO NOTHING` — the *one* place in this project where a
Postgres write deliberately has no guaranteed-row-back guarantee, because zero rows on conflict is the
correct send-once behavior, not a bug) → Code "Build Embed" (formats `deadline`, builds the embed text) →
Discord "Send Discord Embed" → Code "Tally" → Postgres "Write Run".

**WF-1 wired to call WF-2**: `Dedup Upsert` now fans out to both the existing `Tally Results` path and a
new `Build Score Payload` (pairs `was_inserted` flags against `Call WF-L1`'s full items by array position,
same technique as the existing `Tally Results`) → `Call WF-2` (`mode: once`, batches every newly-inserted
posting from one collection run into a single WF-2 execution and a single `runs` row).

**Two pre-existing, silent bugs were found and fixed** that had nothing to do with today's new code — see
`DECISIONS.md` for full writeups: (1) `$vars.PP_CONFIG_BASE_URL` resolves to `undefined` because n8n
Variables is license-gated on this instance, meaning **every WF-L0 fetch since Phase 1 has been silently
broken**, reverted to `$env` with `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"`; (2) `Decide Outcome`'s
`JSON.parse(resp.body)` never worked for a real fresh fetch because the parsed config actually lands under
`resp.data` as an already-parsed object, same family of bug as WF-1's parsers but never applied to WF-L0
itself. Both were masked in Phase 1 testing and only surfaced once Phase 2 needed a genuine fresh 200
round-trip. **New bugs found in today's own code:** `$('NodeName').item.json` cross-references are
unreliable specifically after an Anthropic node or through a Merge node with an unfired branch — fixed
with `$('NodeName').all()[$itemIndex].json` throughout WF-2's LLM and notify-decision paths.

**Testing method:** the CLI's `pinData`-on-a-trigger approach (used successfully for WF-L1's fixtures
originally) turned out not to generalize — confirmed as CLI-`execute`-only, not a production issue, by
building a parent test workflow that invokes WF-2 through a **real** `executeWorkflowTrigger` via a
genuine `Execute Workflow` node call, exactly matching how WF-1 invokes WF-2 in production. That path
worked on the first try once the two Phase-1-era bugs above were fixed, producing real Anthropic-scored
evaluations (a FastAPI/Postgres/Redis/RAG posting scored 95, a Power BI/DAX/ETL posting scored 82) and
real Discord messages in the configured channel, confirmed visually.

**Verified for real, end to end:** prefilter correctly rejects an out-of-market posting and passes an
in-market one; cache-hit path correctly skips a repeat LLM call and reuses the persisted score;
`deadline`/`eligibility` extraction correctly pulls `"2026-09-30"` and a CGPA/graduation-year eligibility
line verbatim from posting text and renders as `"30th September, 2026"` in the Discord embed; send-once
verified by re-running the identical notify call and confirming zero rows, zero second Discord message,
`notifications` count unchanged. All test workflows (11 of them, name-prefixed `_TEST`), test `postings`/
`evaluations`/`notifications`/`runs` rows, and test JSON files were deleted after verification.

**Phase 2 is complete.** Next: Phase 3 (WF-5 error handling, the zero-result alarm gap already noted for
WF-1, config-fetch-failure alarm) — or, if the user prefers, activating WF-1 first to start real
collection now that scoring and alerts actually work.

### 2026-08-14 — Phase 3 core: root-caused a `source: database` execution bug, closed both alarm gaps

Picked up mid-Phase-3 after a context compaction, with WF-5 already built but `source: database` Execute
Workflow calls failing for real, non-CLI executions with "No information about the workflow to execute
found." A long investigation into n8n's newer dual publishing system (`workflow_published_version` /
publication outbox) turned out to be a complete dead end — full writeup in `DECISIONS.md`. The real cause,
found by reading n8n's own source inside the container: every `executeWorkflow` node in this project is
`typeVersion 1.2`, which expects `workflowId` as a resource-locator object (`{__rl, value, mode: "id"}`),
not the bare ID string every `Call WF-*` node actually had. Fixed all six occurrences (WF-0→WF-L1,
WF-1→WF-L0/WF-L1/WF-2, WF-2→WF-L0/WF-3). Verified immediately and repeatedly against the real running
instance (CLI `execute` no longer works alongside a running server on this n8n version — port 5679
conflict — so all verification this session was via genuine UI/schedule-triggered executions).

Caught and reversed a near-miss along the way: publishing WF-1's fix also flipped its `active` flag to
`true` as an undocumented side effect of the CLI's `publish:workflow` command, arming its real hourly
schedule against live ATS APIs without the explicit go-ahead that's been sitting in "blocked on the user"
since Phase 2. Caught within the same restart cycle, deactivated immediately, confirmed via `runs`/
`execution_entity` that zero real fires happened in the ~10-minute window it was live.

Closed both outstanding Phase 3 alarm gaps, each verified against real conditions:
- **WF-1 zero-result gap** — replaced the single blended `Tally Results`/`Write Run` with a per-source
  `Aggregate Per Source` (seeds every known source at fetched=0 before folding in real results, so a
  silent source always gets a `runs` row) plus `Update Source Zero-Streak` and `Check Zero Alarm`. Two
  real WF-1 executions 15 minutes apart organically produced a genuine test case — three sources
  (`ashby:deel`, `lever:mistral`, `lever:plaid`) returned zero both times and correctly triggered the
  alarm by name; sources with one real hit and one zero correctly sat at streak=1, no false alarm. This
  same run also incidentally validated the whole pipeline at real scale for the first time — 1,558 fresh
  postings, 275 scored (range 5-72, avg 17, healthy real distribution), 0 crossed the notify threshold, 0
  Discord messages sent.
- **WF-L0 fallback-alarm gap** — added a parallel branch off `Decide Outcome` (`Is Fallback Alarm?` →
  `Call WF-5 (fallback alarm)`) that fires alongside, not instead of, the normal path that returns cached
  config to the caller. Verified live with a seeded fake `config_cache` row for a nonexistent filename: a
  real Discord alarm landed with the exact composed message, and the calling execution still reported
  `status: success`.

Also independently re-confirmed WF-5's real (non-manual) dispatch mechanism: n8n's own source shows
`dispatchesErrorWorkflow = !isManualMode && !suppressErrorWorkflow` — the editor's "Execute workflow"
button deliberately never triggers error workflows, only real schedule/webhook/sub-workflow-triggered
executions do. Two real automatic WF-0 failures (leftover deliberately-bad fixture, since removed) fired
during restart cycles and both correctly dispatched to WF-5, both confirmed landing in Discord.

Cleanup: deleted the leftover deliberately-bad WF-0 test fixture, all throwaway test workflows, a fake
`config_cache` row, and stray test `pinData` sitting in WF-L1's committed JSON since Phase 1.

**Phase 3's core error-handling work is done and independently verified live.** Remaining Phase 3 items
are process, not code: weekly workflow export to git via the n8n REST API, and a deliberate chaos test
(dead token mid-run recovers unattended).

### 2026-08-14 — Phase 4 begins: WF-1d discover built and verified; a real WF-L0 bug found and fixed

Asked about better Indian-market sources before starting Phase 4 proper. Checked four candidates
(Internshala, Wellfound, Cutshort, Hirist) for real rather than assuming — none integrate compliantly
(robots.txt blocks, no public API, or wrong-direction API); full reasoning in `DECISIONS.md`. Along the
way found the stored "SerpAPI account" n8n credential is the wrong type entirely for WF-1b's needs (it's a
deprecated LangChain agent-tool credential, not usable from a plain HTTP node) — had the owner recreate it
as `httpQueryAuth`.

Built **WF-1d discover**. Tested the plan's own assumption (guess a company's ATS token from its name)
against 49 real, currently-hiring India-based YC companies before writing the workflow: 0 hits across all
six platforms. Traced why (real board tokens often come from the legal entity name, not the brand — e.g.
Razorpay's real Greenhouse token is `razorpaysoftwareprivatelimited`) and found what actually works
instead: extracting the real ATS link from the company's own `/careers` or `/jobs` page, then confirming it
against the real provider API. Built WF-1d on that mechanism instead of the originally-sketched one.

Two real, non-obvious bugs found building and testing WF-1d against the live instance:
- n8n's Code node sandbox doesn't expose the `URL` constructor — `new URL(...)` inside a `try/catch`
  silently swallowed every item with no visible error, identical-looking to a genuine zero-result batch.
  Fixed with a plain regex instead.
- **A real, latent bug in WF-L0 itself**, affecting every one of its callers (WF-1, WF-2, and now WF-1d),
  not just this new workflow. Read n8n's own `ExecuteWorkflow.node.js` source: a `source: database` call in
  `mode: once` returns literally whatever the sub-workflow's own last-executed node output was — branches
  included. Phase 3's fallback-alarm addition gave WF-L0 a second, competing terminal node, so n8n's own
  internal bookkeeping non-deterministically picked either the intended `Finalize` node or the wrong one
  (an IF node's raw two-branch shape) as "the" result — confirmed by pulling raw execution data for real
  calls: WF-1's historical call got lucky (1 branch), WF-1d's didn't (2 branches, real data stranded on the
  branch nothing was listening to). Fixed by restructuring WF-L0 so it has exactly one true terminal node
  again (`Is Fallback Alarm?` now runs sequentially before `Is Fresh?`, reconverging through a `Merge`
  node) — the fix lives entirely in WF-L0's own file, so WF-1 and WF-2 needed no changes and are
  automatically safe now too. Full writeup, including how to check any future sub-workflow graph for this
  same trap, in `DECISIONS.md`.

Verified WF-1d for real, end to end, after both fixes: 49 real candidates considered, 3 genuine ATS boards
discovered and confirmed — Bolna AI (Ashby), Razorpay (Greenhouse), Weekday (Workable) — a real ~6% hit
rate on the very first live run. WF-1d left `active: false`, same standing policy as WF-1, pending the
owner's decision to turn on weekly external traffic to company career pages.

**Next:** WF-1b collect-aggregators (JSearch + SerpApi `google_jobs`, now that the credential is fixed),
then WF-1c collect-pages, then probing Keka/Darwinbox/Zoho Recruit and a free-tier usage projection —
rounding out Phase 4.

### 2026-08-14 — Reopened and resolved: Cutshort + Hirist really do work; WF-1c built and verified live

Owner pushed back on the earlier rejection of all four candidate sources. Re-checked each site's own
`robots.txt` specifically rather than re-asserting the first answer — the first pass had wrongly equated
"no dedicated jobs API" with "not scrapeable," without checking whether a plain, polite, `robots.txt`-
respecting scraper (exactly what WF-1c was always designed to be for arbitrary company career pages) would
actually be permitted. It would, for two of the four: Cutshort publishes `sitemap_jobs.xml` with real job
URLs at a path their own `robots.txt` doesn't block; Hirist's `robots.txt` only blocks generic CMS/admin
paths, not job content, plus a mandatory 10s crawl-delay. Internshala and Wellfound remain genuinely
blocked, each for a different specific reason (explicit disallow on the needed pages; no discoverable job
URLs at all despite individual pages not being disallowed). Full reasoning in `DECISIONS.md`.

Built **WF-1c collect-pages** around Cutshort and Hirist. Added a coarse, deliberately lossy slug-keyword
prefilter before any page fetch (Cutshort alone produces ~4-5k newly-updated postings/day, almost none of
them internships) plus a hard per-run cap, given Hirist's sitemap has no usable date field at all (every
entry shares the same bulk-touched `lastmod`) and its 10s-per-request crawl-delay could otherwise turn an
unreviewed first run into hours of unattended fetching.

First live test found a real bug: `Dedup Upsert` failed on `postings_source_id_fkey` — WF-1c has no
per-company `sources` row the way WF-1's ATS boards do (via `Sync Sources`), so `source_id` must be `NULL`
here, with the existing unconstrained `source` text column carrying `cutshort`/`hirist` instead. Fixed and
re-verified: 30 real candidates, 29 passed LLM validation, all 29 landed in `postings`, real scores from
WF-2 ranged 5-92 and split exactly as intended (genuine intern matches scored high with sensible reasoning,
noise the loose slug filter let through — an "Accounts Executive," a "Fashion Consultant" — correctly
scored 5-15). 6 postings crossed the notify threshold; all 6 real Discord alerts confirmed landed.

WF-1c left `active: false`, same standing policy as WF-1 and WF-1d. **Phase 4 status:** WF-1d and WF-1c
both built and verified live; WF-1b (aggregators) and the Keka/Darwinbox/Zoho Recruit probe + free-tier
usage projection remain.

### 2026-08-14 — WF-1b built (SerpApi, verified live); X/Twitter added via Google search, not scraping

Built **WF-1b collect-aggregators** against SerpApi's `google_jobs` engine — the only aggregator with a
real credential (JSearch stays scaffolded, `enabled: false`, its real response shape never observed).
Found two real n8n mechanics along the way: the `httpQueryAuth` credential's "Name" field *is* the actual
query parameter key sent to the API (not a separate label), which had silently been sending
`?SerpAPI query auth=<key>` instead of `?api_key=<key>`; and `google_jobs` has a documented ~90s max
response time, well outside a first-guess timeout. Real response shape observed live: `jobs_results[]`
with `source_link` as the real apply URL and structured `detected_extensions`. Quota-gated against
`api_quota` (guaranteed-row pattern, same as WF-L0's `Get Cached`), capped *before* spending, not after.
Verified live: 7 real queries, 30 postings, 2 real Discord alerts confirmed. `sources.json`'s `serpapi`
entry flipped to `enabled: true` and pushed.

Owner then asked to integrate X/Twitter. Checked it the same way as the earlier four sources: `robots.txt`
blanket-blocks every generic bot (no carve-out like Cutshort had), and the official API dropped its free
tier entirely in Feb 2026. Owner asked for a free path anyway rather than a paid one. Found one: Googlebot
*is* one of the few crawlers X grants any access to, so querying Google itself (`site:x.com "hiring" ...`
via SerpApi's plain `google` engine) surfaces real hiring-tweet snippets with zero requests ever sent to
x.com — the same non-scraping pattern that made Cutshort/Hirist legitimate, one level more indirect. Wired
as a second SerpApi query type sharing the *same* quota bucket as `google_jobs` (not a separate one — same
account, same real 250/month cap), running weekly rather than daily to leave headroom, with Anthropic
extracting structured fields from the unstructured snippet text. Found and fixed a real bug on the first
test — `x_search_queries` was added to the config schema but never forwarded by `Combine Configs`, so it
silently never reached the query builder regardless of the day-of-week gate. Verified live after the fix
(gate temporarily forced on for one real run, then reverted — never committed): 22 real X-sourced postings,
8 real Discord alerts confirmed. Full reasoning for both in `DECISIONS.md`.

WF-1b left `active: false`. **Phase 4 status:** WF-1d, WF-1c, and WF-1b all built and verified live.
Remaining: probing Keka/Darwinbox/Zoho Recruit and a free-tier usage projection across every provider.
