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
| `WF-L0` lib-config | Execute Workflow (called by others) | on demand | ⬜ |
| `WF-L1` lib-normalize | Execute Workflow (called by others) | on demand | ⬜ |
| `WF-0` selftest | Schedule Trigger | daily | ⬜ |
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
