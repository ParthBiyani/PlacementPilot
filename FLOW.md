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
| `WF-1` collect-ats | Schedule Trigger | hourly | ⬜ |
| `WF-1b` collect-aggregators | Schedule Trigger | daily | ⬜ |
| `WF-1c` collect-pages | Schedule Trigger | daily | ⬜ |
| `WF-1d` discover | Schedule Trigger | weekly | ⬜ |
| `WF-2` score | Execute Workflow (from collectors) | per batch | ⬜ |
| `WF-3` notify | Execute Workflow (from WF-2) | per posting | ⬜ |
| `WF-3b` inbound | **Webhook** — the only public surface | on interaction | ⬜ |
| `WF-4` gmail | Gmail Trigger | 15 min | ⬜ |
| `WF-5` error | Error Workflow on every workflow above | on failure | ⬜ |
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
  │        └─ miss → INSERT posting
  │
  ├─► write runs row (fetched / new / deduped)
  │
  └─► WF-2 score  (only for genuinely new postings)
           │
           ├─ Code: conservative prefilter  ◄── preferences.json via WF-L0
           │     excluded role keyword → location not remote/allowed →
           │     experience > max → grad-year excluded
           │     reject reason → runs.prefilter_reasons
           │     AMBIGUOUS ALWAYS PASSES THROUGH
           │
           ├─ Postgres: evaluations cache lookup
           │     key = (content_hash, prompt_version, model)
           │     prompt_version = sha256(template + profile)  ← Crypto node
           │     ├─ hit  → reuse, cache_hits++
           │     └─ miss ↓
           │
           ├─ Anthropic (Haiku, structured output)
           ├─ Code: validate contract
           │     { match_score 0-100, should_apply, reason ≤300, missing_skills ≤5 }
           │     ├─ valid   → ↓
           │     ├─ invalid → retry once with error appended
           │     └─ invalid twice → flag evaluations.invalid → ALARM (never dropped)
           │
           ├─ Postgres: INSERT evaluation (+ input/output tokens, cost_usd)
           │
           └─ IF match_score ≥ preferences.notify.min_score
                    │
                    └─► WF-3 notify
                             ├─ Postgres INSERT notifications (posting_id, channel)
                             │     UNIQUE(posting_id, channel) ← N4 lives here.
                             │     conflict → already sent → STOP
                             └─ Discord: embed with company, role, location,
                                score, reason, missing skills, apply link
                                + [Applied] [Not interested] [Details]
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
  └─► WF-L0 → accelerators.json
      └─► per accelerator: fetch portfolio → extract company + domain
          └─► probe ATS token patterns (greenhouse/lever/ashby/workable/…)
              └─► 200 → INSERT discovered_sources (probe_result)
                  └─► promote into sources
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
Set as the Error Workflow on every workflow above.
```
failure ──► INSERT runs (error)
        ├─ source returned 0 twice consecutively → ALARM   ← how this project dies quietly
        ├─ config fetch failed → ALARM
        └─ today's SUM(cost_usd) > cap → deactivate WF-2 via n8n REST API
```

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
| `robots_cache` | `WF-1c` | `WF-1c` |
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
