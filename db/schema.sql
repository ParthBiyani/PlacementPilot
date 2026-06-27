-- PlacementPilot — schema
-- Apply once against an empty database:
--   psql "$DATABASE_URL" -f db/schema.sql
-- Safe to re-run: every statement is IF NOT EXISTS / OR REPLACE.
--
-- Portability note (N1): nothing here assumes a local Postgres. Docker Compose,
-- Neon and Supabase all work; pg_trgm is available on all three.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------------------
-- Sources
-- ---------------------------------------------------------------------------

-- Manual sources come from config/sources.json; discovered ones from WF-1d.
-- Both land here so collectors read exactly one table.
CREATE TABLE IF NOT EXISTS sources (
  id            TEXT PRIMARY KEY,              -- e.g. 'greenhouse:nvidia'
  kind          TEXT NOT NULL,                 -- ats | aggregator | rss | careerpage
  provider      TEXT NOT NULL,                 -- greenhouse | lever | ashby | jsearch | ...
  company       TEXT,                          -- NULL for aggregators
  config        JSONB NOT NULL DEFAULT '{}',   -- board token, url, query params
  poll_tier     TEXT NOT NULL DEFAULT 'daily', -- hourly | daily | weekly
  origin        TEXT NOT NULL DEFAULT 'manual',-- manual | discovered
  active        BOOLEAN NOT NULL DEFAULT true,
  last_ok_at    TIMESTAMPTZ,
  consecutive_zero INT NOT NULL DEFAULT 0,     -- drives the zero-result alarm (N6)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sources_active_tier_idx ON sources (active, poll_tier);

-- Raw output of the accelerator crawl, before ATS probing confirms a board.
-- Workflows never write back to config/ — the user's files stay theirs.
CREATE TABLE IF NOT EXISTS discovered_sources (
  id           TEXT PRIMARY KEY,
  accelerator  TEXT NOT NULL,                  -- yc | techstars | antler | ...
  company      TEXT NOT NULL,
  domain       TEXT,
  probe_result JSONB,                          -- which ATS patterns responded
  promoted     BOOLEAN NOT NULL DEFAULT false, -- true once copied into sources
  found_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Postings
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS postings (
  id              TEXT PRIMARY KEY,            -- sha256(norm_company|norm_role|norm_location)
  content_hash    TEXT NOT NULL,               -- sha256(norm_description) → score cache key
  canonical_id    TEXT REFERENCES postings(id),-- set when a near-duplicate (Phase 6)
  source_id       TEXT REFERENCES sources(id),
  company         TEXT NOT NULL,
  role            TEXT NOT NULL,
  location        TEXT,
  employment_type TEXT,
  apply_url       TEXT NOT NULL,
  source          TEXT NOT NULL,               -- provider name, denormalized for queries
  description     TEXT,
  norm_company    TEXT NOT NULL,               -- dedup scope: compare only within a company
  norm_description TEXT,                       -- truncated + normalized, for pg_trgm
  posted_date     TIMESTAMPTZ,
  first_seen      TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS postings_content_hash_idx ON postings (content_hash);
CREATE INDEX IF NOT EXISTS postings_norm_company_idx ON postings (norm_company);
CREATE INDEX IF NOT EXISTS postings_first_seen_idx   ON postings (first_seen DESC);

-- Near-duplicate search is scoped per company, so the trigram index only ever
-- serves small candidate sets — O(n) per company, never O(n^2) globally.
CREATE INDEX IF NOT EXISTS postings_norm_desc_trgm_idx
  ON postings USING gin (norm_description gin_trgm_ops);

-- Fuzzy company-name matching for WF-4 (Gmail): a recruiter email's "From"
-- name or signature rarely matches norm_company exactly (extra suffixes,
-- abbreviations), so this backs a similarity() lookup rather than exact/ILIKE.
CREATE INDEX IF NOT EXISTS postings_norm_company_trgm_idx
  ON postings USING gin (norm_company gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- Prompts and scoring
-- ---------------------------------------------------------------------------

-- prompt_version = sha256(prompt_template + profile block), computed by the
-- Crypto node. Editing the profile in preferences.json therefore changes the
-- version and busts the score cache automatically — no manual bump, no stale
-- scores. See CLAUDE.md "Conventions".
CREATE TABLE IF NOT EXISTS prompts (
  version     TEXT PRIMARY KEY,
  template    TEXT NOT NULL,
  profile     TEXT NOT NULL,
  model       TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'draft',   -- draft | active | archived
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Only one prompt may be active at a time; the Phase 7 promotion gate enforces
-- the F1 floor before flipping this.
CREATE UNIQUE INDEX IF NOT EXISTS prompts_single_active_idx
  ON prompts ((status)) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS evaluations (
  content_hash   TEXT NOT NULL,
  prompt_version TEXT NOT NULL,
  model          TEXT NOT NULL,
  match_score    INT,
  should_apply   BOOLEAN,
  reason         TEXT,
  missing_skills JSONB,
  deadline       TEXT,   -- free text as stated in the posting (e.g. 'Rolling', '2026-09-15'); null if not stated -- never inferred
  eligibility    TEXT,   -- free text as stated in the posting (e.g. 'Final year, CGPA 7.0+'); null if not stated -- never inferred
  ctc_or_stipend TEXT,   -- free text as stated in the posting (e.g. '₹50,000/month', '12-18 LPA'); null if not stated -- never inferred
  input_tokens   INT,
  output_tokens  INT,
  cost_usd       NUMERIC(10,6),
  invalid        BOOLEAN NOT NULL DEFAULT false,  -- flagged after retry, never silently dropped
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (content_hash, prompt_version, model)
);

-- ---------------------------------------------------------------------------
-- Application tracking
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS applications (
  posting_id TEXT PRIMARY KEY REFERENCES postings(id),
  status     TEXT NOT NULL,   -- discovered|applied|not_interested|oa|interview|offer|rejected|closed
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  notes      TEXT
);

-- The enforcement point for N4. Send-once is a database guarantee, not
-- workflow logic — a retry or a concurrent run cannot produce a second alert.
CREATE TABLE IF NOT EXISTS notifications (
  id         BIGSERIAL PRIMARY KEY,
  posting_id TEXT NOT NULL REFERENCES postings(id),
  channel    TEXT NOT NULL DEFAULT 'discord',
  message_id TEXT,                             -- Discord message id, for in-place edits
  sent_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (posting_id, channel)
);

-- WF-4 (Gmail): dedup/idempotency cache on Gmail message ID, and a real
-- audit trail of every classification made, independent of whether it
-- matched a tracked posting.
CREATE TABLE IF NOT EXISTS gmail_messages (
  account            TEXT NOT NULL DEFAULT 'primary', -- which mailbox this came from (WF-4 polls >1)
  message_id         TEXT NOT NULL,             -- unique per-account only, not globally -- see PK below
  classification     TEXT NOT NULL,             -- oa|interview|rejection|offer|referral|other
  company            TEXT,
  role               TEXT,
  deadline           TEXT,                      -- verbatim, never inferred -- same rule as evaluations
  matched_posting_id TEXT REFERENCES postings(id),
  match_similarity   NUMERIC(4,3),               -- pg_trgm score for the match, null if unmatched
  invalid            BOOLEAN NOT NULL DEFAULT false,
  processed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account, message_id)              -- composite: Gmail message IDs aren't globally unique
);

-- ---------------------------------------------------------------------------
-- Instrumentation
-- ---------------------------------------------------------------------------

-- Every workflow run writes here. This table is the only source of honest
-- numbers — latency, cost, kill rate, failure counts.
CREATE TABLE IF NOT EXISTS runs (
  id           BIGSERIAL PRIMARY KEY,
  workflow     TEXT NOT NULL,
  source_id    TEXT,
  started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at  TIMESTAMPTZ,
  fetched      INT NOT NULL DEFAULT 0,
  new_count    INT NOT NULL DEFAULT 0,
  deduped      INT NOT NULL DEFAULT 0,
  prefiltered  INT NOT NULL DEFAULT 0,
  prefilter_reasons JSONB,                     -- {reason: count} — reported, never targeted
  llm_calls    INT NOT NULL DEFAULT 0,
  cache_hits   INT NOT NULL DEFAULT 0,
  notified     INT NOT NULL DEFAULT 0,
  cost_usd     NUMERIC(10,6) NOT NULL DEFAULT 0,
  error        TEXT
);

CREATE INDEX IF NOT EXISTS runs_started_idx  ON runs (started_at DESC);
CREATE INDEX IF NOT EXISTS runs_workflow_idx ON runs (workflow, started_at DESC);

-- Free-tier budget tracking (N7). WF-1b reads this BEFORE spending a call and
-- skips any provider at its cap.
CREATE TABLE IF NOT EXISTS api_quota (
  provider     TEXT NOT NULL,
  period_month TEXT NOT NULL,                  -- 'YYYY-MM'
  used         INT NOT NULL DEFAULT 0,
  limit_calls  INT NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, period_month)
);

-- ---------------------------------------------------------------------------
-- Caches
-- ---------------------------------------------------------------------------

-- Config arrives over HTTPS (no host filesystem, per N1). If the fetch fails we
-- serve last_good_body and alarm — never fail silently, never run on nothing.
CREATE TABLE IF NOT EXISTS config_cache (
  file           TEXT PRIMARY KEY,             -- preferences.json | sources.json | accelerators.json
  etag           TEXT,
  body           JSONB NOT NULL,
  fetched_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_good_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS robots_cache (
  domain     TEXT PRIMARY KEY,
  rules      TEXT,
  allowed    BOOLEAN NOT NULL DEFAULT true,
  fetched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + interval '7 days'
);

-- ---------------------------------------------------------------------------
-- Evaluation and self-test
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS labels (
  posting_id  TEXT PRIMARY KEY REFERENCES postings(id),
  human_label BOOLEAN NOT NULL,                -- would I actually apply?
  split       TEXT NOT NULL,                   -- train | holdout
  labeled_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS eval_runs (
  id             BIGSERIAL PRIMARY KEY,
  prompt_version TEXT NOT NULL,
  split          TEXT NOT NULL,
  n              INT NOT NULL,
  precision      NUMERIC(5,4),
  recall         NUMERIC(5,4),                 -- weighted above precision by design
  f1             NUMERIC(5,4),
  kappa          NUMERIC(5,4),
  run_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- WF-0 runs these through WF-L1 and diffs against `expected`. This is the only
-- regression net in an all-n8n system — treat a red fixture as a build break.
CREATE TABLE IF NOT EXISTS test_fixtures (
  id       TEXT PRIMARY KEY,
  kind     TEXT NOT NULL,                      -- normalize | dedup_key | interaction | trgm_sweep
  input    JSONB NOT NULL,
  expected JSONB NOT NULL,
  note     TEXT
);
