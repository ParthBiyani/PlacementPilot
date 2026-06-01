# PlacementPilot v3 — PRD & Roadmap

**Owner:** Parth Biyani
**Status:** Draft for build
**Portfolio role:** This is the **orchestration & integration** project. Agentic reasoning depth is carried by the two LangGraph projects — deliberately *not* by this one.
**One-line positioning:** A production-grade n8n automation with a tested Python sidecar for the parts that need regression tests.

---

## 1. What this is (and isn't)

n8n orchestrates the whole pipeline: scheduling, multi-source fan-out, error branches, retries, LLM scoring, notifications, human-in-the-loop status tracking, and Gmail event handling. A small local FastAPI service ("the sidecar") owns exactly two things — deduplication and the evaluation harness — because those need version control, unit tests, and a CI gate that Function nodes can't give you.

**Explicit non-goals.** Cut, not deferred:

| Cut | Why |
|---|---|
| LinkedIn / Naukri / Instahyre scraping | ToS violation, actively blocked, no good interview answer |
| Auto-apply / form autofill | Fragile research problem, weak signal to recruiters |
| Career coach, interview prep, resume optimizer | Different product |
| Web dashboard | A SQL query answers every stats question I actually have |
| Custom scheduler recovery logic | Cron + dedup makes missed runs harmless |
| Multi-agent reasoning, planning loops, tool-calling agents | **Belongs in the LangGraph projects.** Keeping it out of here makes both stories cleaner. |

Success is not feature count. It is: *this ran unattended for 8+ weeks, the workflows survive failure, and I can prove the scorer works.*

---

## 2. Success criteria

1. Runs unattended ≥ 8 weeks with < 2 manual interventions.
2. Scorer achieves ≥ 0.85 agreement with my labels on a held-out set of 200 hand-labeled jobs.
3. Deterministic prefilter eliminates ≥ 60% of postings before any LLM call.
4. Cost per run measured, and reduced by a stated % after caching + prefilter.
5. Zero duplicate notifications across the full run window.
6. Every workflow has an error branch that has actually fired at least once in production and been recovered from without me touching it.

Criterion 6 is the n8n-specific one. Anyone can build a happy path in n8n; surviving a source outage is what separates a demo from a deployment.

---

## 3. Sources (v1 — final)

| Source | Method | n8n node |
|---|---|---|
| Greenhouse | Public JSON board API | HTTP Request |
| Lever | Public JSON postings API | HTTP Request |
| Ashby | Public JSON board API | HTTP Request |
| Gmail | Gmail trigger, read-only | Gmail Trigger |

All three ATS APIs are official, documented, unauthenticated, stable. A `companies` table maps company → ATS + board token; the collector loops over it, so adding a company is a row insert, not a workflow edit. **That's the modularity claim worth making** — not "10+ sources."

**v2 candidates, only after §2 is met:** career-page RSS (n8n has a native RSS trigger, cheap win), Y Combinator jobs JSON, curated Telegram channels.

---

## 4. Architecture

### Workflow topology

Five separate n8n workflows, connected by Execute Workflow. Splitting them is deliberate — it gives independent error handling, independent retry, and a topology you can explain on a whiteboard.

```
WF-1  collect          Schedule (4h) ─► Postgres: get companies
                       ─► Loop Over Items ─► Switch(ats)
                            ├─ HTTP: Greenhouse
                            ├─ HTTP: Lever
                            └─ HTTP: Ashby
                       ─► Code: normalize to common schema
                       ─► HTTP: sidecar POST /dedupe
                       ─► Postgres: upsert new postings
                       ─► Execute Workflow: WF-2
                       [Error Workflow: WF-5]

WF-2  score            Postgres: unscored postings
                       ─► Code: prefilter (deterministic, no LLM)
                       ─► Postgres: check evaluations cache by content_hash
                       ─► IF cache miss
                            └─ Anthropic node (Haiku, structured output)
                               ─► Code: validate schema
                               ─► IF invalid ─► retry once ─► else flag + alert
                       ─► Postgres: write evaluation + token counts
                       ─► IF score ≥ threshold ─► Execute Workflow: WF-3
                       [Error Workflow: WF-5]

WF-3  notify           Postgres: check session_state (is 24h window open?)
                       ─► IF open  ─► Twilio: free-form WhatsApp + reply buttons
                          IF closed ─► Twilio: approved template message
                       ─► Postgres: log notification

WF-3b inbound          Webhook (Twilio inbound WhatsApp)
                       ─► Postgres: refresh session_state timestamp
                       ─► Code: parse command (applied <id> | detail <id> | status | pause)
                       ─► Postgres: update application status
                       ─► Twilio: free-form confirmation (session now open)

WF-4  gmail            Gmail Trigger (15m)
                       ─► Anthropic: classify {oa|interview|rejection|offer|referral|other}
                       ─► Code: extract company/role/deadline
                       ─► IF ≠ other ─► Execute Workflow: WF-3 + Postgres

WF-5  error handler    Set as Error Workflow on WF-1/2/4
                       ─► Postgres: log to runs table
                       ─► IF source returned 0 twice consecutively ─► WhatsApp alarm
                       ─► IF daily spend cap breached ─► disable WF-2 via n8n API
```

### Sidecar (FastAPI, ~300 LOC)

```
POST /dedupe   → [postings] → [{posting, is_duplicate, canonical_id, similarity}]
POST /evaluate → run eval harness against labeled set, return metrics
GET  /health
```

Only two endpoints. Everything else stays in n8n. The line is: *anything that needs a unit test lives in Python; anything that's glue lives in n8n.* Say exactly that in the README — it's a maturity signal, not a hedge.

### Storage

**Postgres from day one**, not SQLite. n8n's Postgres node is far better supported, and it's how you'd actually deploy. Runs in the same Docker Compose as n8n.

---

## 5. Data model

```sql
CREATE TABLE companies (
  name TEXT PRIMARY KEY, ats TEXT NOT NULL, board_token TEXT NOT NULL, active BOOLEAN DEFAULT true
);

CREATE TABLE postings (
  id              TEXT PRIMARY KEY,   -- sha256(norm_company|norm_role|norm_location)
  content_hash    TEXT NOT NULL,      -- sha256(norm_description) → cache key
  canonical_id    TEXT REFERENCES postings(id),  -- set if near-duplicate
  company TEXT NOT NULL, role TEXT NOT NULL, location TEXT,
  employment_type TEXT, apply_url TEXT NOT NULL, source TEXT NOT NULL,
  description TEXT, posted_date TIMESTAMPTZ,
  embedding       BYTEA,              -- 384-dim, all-MiniLM-L6-v2
  first_seen TIMESTAMPTZ NOT NULL, last_seen TIMESTAMPTZ NOT NULL
);

CREATE TABLE evaluations (
  content_hash TEXT, prompt_version TEXT, model TEXT,
  match_score INT, should_apply BOOLEAN, reason TEXT, missing_skills JSONB,
  input_tokens INT, output_tokens INT, created_at TIMESTAMPTZ,
  PRIMARY KEY (content_hash, prompt_version, model)
);

CREATE TABLE applications (
  posting_id TEXT REFERENCES postings(id),
  status TEXT NOT NULL,  -- discovered|applied|oa|interview|offer|rejected|closed
  updated_at TIMESTAMPTZ, notes TEXT
);

CREATE TABLE runs (
  id SERIAL PRIMARY KEY, workflow TEXT, source TEXT,
  started_at TIMESTAMPTZ, finished_at TIMESTAMPTZ,
  fetched INT, new INT, deduped INT, prefiltered INT,
  llm_calls INT, cache_hits INT, cost_usd NUMERIC, error TEXT
);

CREATE TABLE labels (
  posting_id TEXT PRIMARY KEY REFERENCES postings(id),
  human_label BOOLEAN NOT NULL, split TEXT NOT NULL, labeled_at TIMESTAMPTZ
);
```

`runs` produces every honest number on the resume. Don't skip it.

---

## 6. Deduplication (sidecar)

**Normalization.** Lowercase; strip legal suffixes (`inc`, `pvt ltd`, `technologies`, `labs`); strip seniority and req-ID noise (`sr.`, `senior`, `ii`, `(remote)`, `#12345`); collapse location aliases (`bengaluru`/`blr` → `bangalore`).

**Stage 1 — exact key.** `sha256(norm_company | norm_role | norm_location)`. Catches most of it. On hit, bump `last_seen` and stop.

**Stage 2 — near-duplicate.** Embed the description with `all-MiniLM-L6-v2` (local, free). Compare only against embeddings from the same normalized company — O(n) per company, not O(n²) globally. Cosine ≥ **0.90** → duplicate; set `canonical_id`, prefer the direct-ATS `apply_url`.

**Calibrate, don't guess.** Hand-label 50 pairs, sweep 0.80–0.95, pick max-F1, put the curve in the README. Unit-tested in the sidecar; that test is why this lives in Python.

---

## 7. Prefilter (n8n Code node, pre-LLM)

Cheapest-first, short-circuit on first rejection:

1. Blacklisted role keywords (sales, marketing, BPO, support, HR, recruiter)
2. Location not in `{remote, bangalore, pune, hyderabad, gurugram, delhi ncr, noida}`
3. Experience requirement > 1 year
4. Graduation-year exclusion ("2025 batch only" vs my 2027)
5. Non-tech department field where the ATS provides one

Log the rejection reason to `runs`. **Report the kill rate** — it's a stronger cost story than "used a cheaper model," and it costs zero tokens.

---

## 8. LLM scoring (n8n Anthropic node)

**Model:** Haiku for volume scoring; Sonnet only for the Sunday digest. Single provider, simple token accounting.

**Contract:** enforce this shape, validate in a Code node.

```json
{ "match_score": 0-100, "should_apply": bool,
  "reason": "≤300 chars", "missing_skills": ["≤5 items"] }
```

Invalid → one retry with the error appended → still invalid → flag row, alert via WF-5, never silently drop.

**Caching:** keyed on `(content_hash, prompt_version, model)`. Description edits bust the cache; URL changes don't. Bumping `prompt_version` invalidates cleanly, which makes eval iteration cheap.

**Prompt versioning in n8n is a real weak point** — workflow JSON diffs are unreadable. Fix: store prompts in a Postgres `prompts` table keyed by version, fetch in the workflow. Now prompt history is queryable and the eval harness can pin a version. Small design decision, good interview answer.

---

## 9. Evaluation harness (sidecar) — the differentiator

**Label set.** After ~2 weeks of collection, sample 200 postings stratified across companies and roles. Label 1/0 by hand: *would I actually apply?* 120 train / 80 held-out. One sitting, consistent criteria.

**Metrics.** Precision, recall, F1, Cohen's κ against my labels. **Recall matters more than precision** — a missed good job is a real loss, a bad notification costs five seconds. Tune the threshold accordingly and say so; that reasoning is what an interviewer is probing.

**Loop.** Eval → inspect disagreements → revise prompt → bump version → re-run.

| Prompt | Precision | Recall | F1 | Notes |
|---|---|---|---|---|
| v1 | | | | baseline, zero-shot |
| v2 | | | | added 3 few-shot examples |
| v3 | | | | explicit grad-year rule |

Never tune against held-out. Touch it once, at the end.

**Regression gate.** `pytest` runs 30 frozen cases in CI; a prompt change that drops F1 fails the build. Cheap to build, disproportionate signal.

---

## 10. Reliability — the n8n showcase

This section *is* the project's differentiator, since the reasoning depth lives elsewhere. Make it deep.

- **Error Workflow** set on WF-1/2/4 — n8n's native mechanism, and most people never configure it.
- **Retry on Fail** at the node level: 3 attempts, exponential backoff, on every HTTP node.
- **Continue On Fail** on individual source branches so one dead ATS can't abort the run.
- **Rate limiting:** batch size 1 with a 1s interval per source; respect `Retry-After`.
- **Zero-result alarm:** source returns 0 twice consecutively → WhatsApp alert (template, since the window may be closed). This is the realistic way the project dies silently.
- **Twilio failure handling:** a rejected template send (error 63016 — outside window) falls back to queueing the alert for the next batch rather than dropping it. Log every Twilio error code to `runs`.
- **Webhook exposure:** WF-3b's webhook is the only publicly reachable surface. Validate Twilio's `X-Twilio-Signature` in a Code node before processing — an unauthenticated webhook that mutates your database is the kind of thing an interviewer will poke at.
- **Spend cap:** enforced, not configurable-in-theory — WF-5 sums today's `cost_usd` and deactivates WF-2 via the n8n REST API on breach.
- **Credentials:** n8n credential store only. No keys in nodes, none in Git.
- **Backup:** workflows exported to Git as JSON weekly via a scheduled workflow hitting the n8n API. This is how you version-control n8n honestly, and it's a good thing to have an answer for.

---

## 11. Notifications — WhatsApp (Twilio)

### The constraint that drives the design

WhatsApp Business API permits free-form bot-initiated messages **only within 24 hours of your last inbound message**. Job alerts are proactive, so most land outside that window and must use a **pre-approved template**: fixed wording, variable substitution only, no free-form LLM-generated text.

This is not a workaround to hide — it's a real platform constraint, and having designed around it correctly is a better interview answer than "I used Telegram because it was easier."

### Session tracking

```sql
CREATE TABLE session_state (
  id INT PRIMARY KEY DEFAULT 1,
  last_inbound_at TIMESTAMPTZ,
  window_open BOOLEAN GENERATED ALWAYS AS
    (last_inbound_at > now() - interval '24 hours') STORED
);
```

WF-3 branches on `window_open`. WF-3b refreshes `last_inbound_at` on every inbound message.

### Template message (window closed — the common case)

Submit for approval in Twilio/Meta as category **UTILITY** (not MARKETING — utility templates are cheaper and approve faster; framing it as a personal job-tracking utility is accurate).

```
New match: {{1}} — {{2}}
{{3}} · Score {{4}}/100
Missing: {{5}}
Apply: {{6}}

Reply "d {{7}}" for details or "a {{7}}" if you applied.
```

`{{7}}` is a short posting ref. Keep it under ~1024 chars and avoid anything that reads promotional, which is the usual rejection cause.

### Free-form message (window open)

Once you reply, the session opens for 24h and you get the full experience — LLM reason text, interactive reply buttons, digest on demand:

```
🚀 87 · NVIDIA — Software Engineer Intern
Bangalore · Internship · Greenhouse
Strong fit: Python, PyTorch, CV work maps directly to the JD.
Missing: Docker, Kubernetes
→ <apply_url>
[Applied] [Not interested]
```

### Command grammar (WF-3b)

Parsed in a Code node, not by an LLM — deterministic, free, testable:

| Reply | Effect |
|---|---|
| `a <ref>` | status → applied |
| `n <ref>` | status → not interested |
| `d <ref>` | send full free-form detail |
| `status` | counts by status |
| `pause` / `resume` | toggle WF-2 via n8n API |

### Cost and batching

Each template message is a billable Twilio conversation. At ~5 alerts/day that's negligible, but **batch alerts into one message per run** (top 3 by score, plus a count of the rest) rather than one message per posting. Cheaper, and it keeps WhatsApp usable.

The Sunday digest goes out as a separate approved template.

### Dev vs production

Build against the **Twilio WhatsApp Sandbox** (instant, no approval, but sandbox requires you to re-join every 72h and only supports free-form within session). Submit real templates in week 6 — approval takes 1–2 days, so don't leave it to the last day.

Human-in-the-loop over a Twilio webhook, with correct session-window handling, is the strongest single thing in this project's n8n story. Lead the README with it.

---

## 12. Gmail

Read-only. Gmail Trigger, 15m poll. Classify into `{oa, interview, rejection, offer, referral, other}`, extract company/role/deadline, notify on everything but `other`. Fuzzy-match company back to a posting. Cache on message ID.

---

## 13. Deployment

Docker Compose: `n8n` + `postgres` + `sidecar`. Laptop first, then a small VPS or Raspberry Pi. Committing the compose file matters — it's the difference between "I ran n8n locally" and "I deployed it."

`n8n` and the sidecar share a Docker network; the sidecar is never exposed publicly.

---

## 14. Roadmap

**Week 1 — Skeleton that runs.**
Docker Compose up, Postgres schema, `companies` seeded, WF-1 collecting from all three ATSs, normalization, WF-3 notifying on everything via the **Twilio WhatsApp Sandbox** (free-form, session kept open manually). No LLM, no dedup yet — watch the raw noise so you know what dedup has to fix. *Exit: one full 4h cycle end-to-end, alert lands on your phone.*

**Week 2 — Sidecar + filtering.**
FastAPI sidecar with `/dedupe` (exact-key only), prefilter Code node, WF-2 with Anthropic scoring, schema validation, cache table, `runs` instrumentation. *Exit: prefilter kill rate and cost/run are measured numbers, not estimates.*

**Weeks 3–4 — Collect and label.**
Let it run. Around day 21, sample and label 200 postings. Add embedding near-duplicate detection to the sidecar; calibrate the threshold on 50 labeled pairs. *Exit: labeled set in `labels`, threshold curve plotted.*

**Week 5 — Evals.**
Harness in the sidecar, baseline v1, iterate to v3, prompts moved to the `prompts` table, 30 frozen cases in CI. *Exit: results table filled, ≥ 0.85 on held-out.*

**Week 6 — Hardening + Gmail.**
WF-5 error workflow, retry/continue-on-fail across all nodes, zero-result alarm, enforced spend cap, weekly workflow-export-to-Git, WF-4 Gmail. **Submit WhatsApp templates for approval on day 1 of this week** (1–2 day turnaround), then build WF-3b: session tracking, signature validation, command grammar, template/free-form branching, batched alerts. *Exit: kill a source mid-run and watch it recover unattended; an alert sent with the window closed still arrives.*

**Weeks 7–14 — Run it and add nothing.**
No new features. Log everything. At week 14 the §2 numbers are real.

**Only then:** RSS sources, second notification channel, public write-up.

---

## 15. Resume bullet (fill in after week 14)

> **PlacementPilot** | *n8n, PostgreSQL, FastAPI, Claude API, Twilio WhatsApp, Docker* — May 2026
> - Deployed a 6-workflow n8n automation (Docker Compose: n8n + Postgres + Python sidecar) ingesting from Greenhouse/Lever/Ashby APIs and Gmail, with error workflows, per-node retry/backoff, zero-result alarms, and an enforced daily LLM spend cap.
> - Built WhatsApp human-in-the-loop tracking over Twilio with 24-hour session-window handling (approved utility templates outside the window, free-form + reply buttons inside) and signature-validated inbound webhooks.
> - Cut per-run LLM cost **__%** via a deterministic prefilter (**__%** of postings rejected pre-call) plus content-hash response caching and embedding-based near-duplicate detection.
> - Validated the relevance scorer against a **200-job hand-labeled set** (F1 **__**, recall-weighted by design) with a regression gate in CI; ran unattended **__ weeks** across **__** postings.

Every blank is a logged number by then. Three bullets, three distinct signals: deployment/reliability, cost engineering, evaluation rigor. None of it overlaps with what the LangGraph projects will claim.

---

## 16. Repo layout

```
placementpilot/
├── workflows/          wf1_collect.json  wf2_score.json  wf3_notify.json
│                       wf3b_inbound.json  wf4_gmail.json  wf5_error.json
│                       templates/  ← WhatsApp template text + approval status
├── sidecar/
│   ├── app.py          FastAPI: /dedupe, /evaluate, /health
│   ├── dedupe.py       normalization + embedding similarity
│   ├── evals/          harness.py  label_cli.py  results.md
│   ├── tests/          test_dedupe.py  test_evals.py
│   └── Dockerfile
├── db/                 schema.sql  seed_companies.sql
├── docker-compose.yml
└── README.md           ← architecture diagram, eval table, threshold curve,
                          cost numbers, and the n8n-vs-Python boundary rationale
```

The README is what a hiring manager actually reads. Lead it with the topology diagram and the "orchestration in n8n, tested logic in Python" rationale — that sentence is the whole positioning of this project.
