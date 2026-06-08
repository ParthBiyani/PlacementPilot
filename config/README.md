# config/

**These three files are the whole control surface.** Edit one, push, and the next run behaves
differently. You never open a workflow to change what jobs you get or where they come from.

They are fetched over HTTPS by `WF-L0 lib-config` from `PP_CONFIG_BASE_URL` (set in `.env`), validated,
and cached in Postgres with their `ETag`. If a fetch fails, the last good copy is used **and an alarm
fires** — the tool never runs on nothing and never fails quietly.

Nothing secret belongs here. API keys live in the n8n credential store. These files are safe to publish.

---

## preferences.json — what you want

| Field | Meaning |
|---|---|
| `profile.graduation_year` | Drives the grad-year prefilter rule. A posting restricted to a different batch is rejected before any LLM call. |
| `profile.summary` | **Sent to the scorer verbatim.** Write it as you'd describe yourself to a recruiter. This is the single highest-leverage field in the whole system. |
| `profile.skills` / `projects` | Also sent to the scorer; feed `missing_skills` in each result. |
| `must_have.locations` | Lowercase city names. Normalization collapses aliases, so `bengaluru` and `blr` both match `bangalore`. |
| `must_have.remote_ok` | If true, remote postings bypass the location check. |
| `must_have.employment_types` | `internship`, `full_time`, `apprenticeship`, `contract`. |
| `must_have.max_experience_years` | Rejected only when a posting states a requirement **above** this. Unstated experience is not a rejection. |
| `exclude.role_keywords` | Substring match against the role title. Keep these unambiguous — see the warning below. |
| `exclude.companies` | Never notify about these, whatever the score. |
| `notify.min_score` | 0–100. The score at or above which you get pinged. Start at 75 and tune after Phase 7's evaluation, not before. |
| `poll.ats_minutes` | How often ATS boards are polled. This is your alert latency floor. |
| `queries` | Role × location strings spent against the aggregator quota. Each costs one call per provider per day, so keep the list tight. |

> **Editing `profile` re-scores everything.** `prompt_version` is `sha256(prompt_template + profile)`, so
> changing your summary or skills invalidates the score cache automatically. That is intended — it costs
> some tokens and guarantees you never see a score computed against a stale version of you.

> **The prefilter is deliberately conservative.** It rejects only on unambiguous mismatch; anything
> uncertain goes to the LLM. So put only clear disqualifiers in `exclude.role_keywords` — a broad word
> like `engineer` or `associate` will silently cost you real matches. A missed good job is a real loss; a
> fraction of a cent of tokens is not.

---

## sources.json — where to look

`ats` — one row per company board. Adding a company is a row, not a workflow edit.

```json
{ "provider": "greenhouse", "token": "postman", "company": "Postman" }
```

`provider` is one of `greenhouse`, `lever`, `ashby`, `workable`, `smartrecruiters`, `recruitee`.
`token` is the board identifier in the company's careers URL. To check one before adding it:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://boards-api.greenhouse.io/v1/boards/TOKEN/jobs
```

`200` means it's real. Every entry currently in the file was probed this way on 2026-08-13.

`aggregators` — free-tier job APIs, all `enabled: false` until you add the matching credential in n8n.
`monthly_limit` is enforced: `WF-1b` checks `api_quota` **before** spending a call and skips any provider
at its cap, so a free tier can't be blown through by accident.

`career_pages` / `rss` — companies with no supported ATS. Fetched once daily, honouring `robots.txt`.

---

## accelerators.json — how the source list grows itself

`WF-1d` (Phase 4) reads each enabled accelerator, extracts its portfolio companies, then probes every
pattern in `ats_probe_patterns` against each company name. Boards that answer get registered
automatically in `discovered_sources`.

This is the point of the file: **add one accelerator, gain its entire portfolio's job boards.** Only `yc`
is verified so far — it serves ~10MB of company JSON, refreshed daily. The rest are disabled until their
extraction is confirmed; enabling an unverified one logs a failure rather than breaking the run.

Discovery never writes back to these files. Your config stays yours.
