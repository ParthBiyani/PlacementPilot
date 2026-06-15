-- PlacementPilot — WF-0 selftest fixtures
--
-- Frozen regression cases for WF-L1 lib-normalize, run daily by WF-0 against
-- the SAME sub-workflow production uses (never a copy). `expected.id` values
-- were computed once, offline, against the real normalize logic running in
-- n8n's own Node runtime (see DECISIONS.md 2026-08-14) -- not guessed.
--
-- Apply after db/schema.sql:
--   docker compose exec -T postgres psql -U placementpilot -d placementpilot < db/seed_fixtures.sql

INSERT INTO test_fixtures (id, kind, input, expected, note) VALUES

-- Two postings for the same real opening, arriving from different sources
-- with different casing/company-suffix/location-alias. The exact-key dedup
-- guarantee depends on both collapsing to the identical id.
('norm-001-phonepe-a', 'normalize',
  '{"company":"PhonePe Technologies","role":"Software Engineer Intern","location":"Bengaluru","employment_type":"internship","apply_url":"https://boards.greenhouse.io/phonepe/jobs/1","source":"greenhouse","source_id":"gh-phonepe-1","description":"We are looking for a software engineer intern to join our backend team.","posted_date":"2026-08-10T00:00:00.000Z"}'::jsonb,
  '{"norm_company":"phonepe","id":"4f2940ee4e73b7a218aec09c78d4131221661eb9046b1c8191427d486502bfe6"}'::jsonb,
  'Direct ATS listing'),

('norm-002-phonepe-b', 'normalize',
  '{"company":"phonepe","role":"software engineer intern","location":"blr","employment_type":"internship","apply_url":"https://boards.greenhouse.io/phonepe/jobs/1?utm=aggregator","source":"jsearch","source_id":"js-9981","description":"We are looking for a software engineer intern to join our backend team.","posted_date":"2026-08-10T00:00:00.000Z"}'::jsonb,
  '{"norm_company":"phonepe","id":"4f2940ee4e73b7a218aec09c78d4131221661eb9046b1c8191427d486502bfe6"}'::jsonb,
  'Same opening via an aggregator -- must collapse to norm-001''s id'),

-- Seniority prefix, a trailing (Remote) tag and a req-id suffix must all be
-- stripped from the role; "Pvt Ltd" must be stripped from the company.
('norm-003-groww-noisy', 'normalize',
  '{"company":"Groww Pvt Ltd","role":"Senior Backend Engineer (Remote) #4521","location":"Mumbai","employment_type":"full_time","apply_url":"https://boards.greenhouse.io/groww/jobs/2","source":"greenhouse","source_id":"gh-groww-2","description":"Own the payments ledger service handling millions of transactions daily.","posted_date":"2026-08-11T00:00:00.000Z"}'::jsonb,
  '{"norm_company":"groww","id":"c094df47f0a782465927da16dc07f61e4ab0d10ef54ecf98e48c46097f58b954"}'::jsonb,
  'Seniority/parenthetical/req-id noise and a legal suffix, all in one posting'),

-- Location-alias collapsing: "Gurgaon" and "Gurugram" must normalize to the
-- identical location, and therefore the identical id.
('norm-004-zeta-gurgaon', 'normalize',
  '{"company":"Zeta Technologies","role":"Data Analyst","location":"Gurgaon","employment_type":"full_time","apply_url":"https://boards.greenhouse.io/zeta/jobs/3","source":"greenhouse","source_id":"gh-zeta-3","description":"Analyze transaction data to surface fraud patterns.","posted_date":"2026-08-12T00:00:00.000Z"}'::jsonb,
  '{"norm_company":"zeta","id":"c67471a7d3a0df7101c18e7f97faf839a950893f333aafb3ac8888c7ff225f90"}'::jsonb,
  'Old-name location alias'),

('norm-005-zeta-gurugram', 'normalize',
  '{"company":"Zeta Technologies","role":"Data Analyst","location":"Gurugram","employment_type":"full_time","apply_url":"https://boards.greenhouse.io/zeta/jobs/3","source":"greenhouse","source_id":"gh-zeta-3","description":"Analyze transaction data to surface fraud patterns.","posted_date":"2026-08-12T00:00:00.000Z"}'::jsonb,
  '{"norm_company":"zeta","id":"c67471a7d3a0df7101c18e7f97faf839a950893f333aafb3ac8888c7ff225f90"}'::jsonb,
  'Canonical-name location -- must collapse to norm-004''s id')

ON CONFLICT (id) DO UPDATE SET
  kind = EXCLUDED.kind, input = EXCLUDED.input, expected = EXCLUDED.expected, note = EXCLUDED.note;
