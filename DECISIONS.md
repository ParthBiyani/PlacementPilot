# DECISIONS.md

Why, not what. Append-only, newest last. Every meaningful decision goes here — including decisions to
*reject* something, which are usually the ones worth remembering.

Format: `## YYYY-MM-DD — <decision>` with **Context**, **Decision**, **Why**, **Rejected alternatives**,
**Consequences**.

---

## 2026-08-13 — The PRD is a starting point, not a specification

**Context.** [PRD.md](PRD.md) frames PlacementPilot as a portfolio artifact: it optimises for résumé
bullets, interview answers and "what a hiring manager actually reads."

**Decision.** Treat it as the source of *rationale*, not requirements. The project's purpose is that the
owner actually lands preference-matched interviews with minimal effort. Priority order for every design
choice: **usefulness first, then keeping it alive, then provability.**

**Why.** The owner is unable to keep up with off-campus applications manually; that is the problem being
solved. A tool optimised to *describe well* and a tool optimised to *work* diverge — most visibly in
sequencing, where the PRD defers the useful parts (scoring, notification) behind weeks of infrastructure.

**Consequences.** Phases are reordered so real alerts arrive at Phase 2. Success criteria are rewritten
as P1–P5 (outcomes) with N1–N7 as enablers. The PRD's résumé section is now a by-product, not a goal.

---

## 2026-08-13 — Everything in n8n; no Python sidecar

**Context.** The PRD splits the system: n8n for glue, a tested FastAPI sidecar for deduplication and the
evaluation harness, on the rule *"anything that needs a unit test lives in Python."*

**Decision.** Drop Python entirely. All logic lives in n8n Code nodes; shared logic lives in library
sub-workflows (`WF-L0`, `WF-L1`) invoked via Execute Workflow.

**Why.** Owner's requirement: one runtime, no second service to deploy, install or keep alive, and a
system anyone can run by importing workflows. A sidecar means two deployables and a Docker network,
which conflicts directly with the portability decision below.

**Rejected alternatives.** Keeping the sidecar for dedup only — still two deployables, still blocks
n8n Cloud.

**Consequences.** *This is a real cost, accepted knowingly.* We lose `pytest` and a CI regression gate,
which the PRD called a differentiator. Replacements: `WF-0 selftest` runs frozen fixtures through the
same `WF-L1` the collectors use, daily; and the Phase 7 promotion gate blocks any prompt whose F1 falls
below the frozen baseline. Both are real gates. Neither is as strong as CI. Because shared logic sits in
sub-workflows rather than being copy-pasted, `WF-0` tests the code that actually runs.

---

## 2026-08-13 — Portability is the binding constraint

**Context.** Owner requires the project to run unchanged on n8n Cloud, a laptop, or a Raspberry Pi, and
to be forkable by a stranger who wants it for their own job hunt.

**Decision.** Portability outranks convenience everywhere. Concretely: no npm imports in Code nodes, no
host filesystem access, no community nodes on the critical path, Postgres reached only via a connection
string in a credential, and no personal data outside `config/` and the credential store.

**Why.** n8n Cloud forbids external modules in Code nodes; community nodes don't exist there; there is no
filesystem. Any one of those dependencies silently pins the project to a self-hosted box forever.

**Consequences.** SHA-256 comes from the native **Crypto node** (verified 2026-08-13 to work on Cloud),
not `require('crypto')`. `docker-compose.yml` deliberately does **not** set `NODE_FUNCTION_ALLOW_EXTERNAL`
or `NODE_FUNCTION_ALLOW_BUILTIN` — if a workflow seems to need them, it is doing something a native node
should do. Discord inbound cannot use a community trigger node and must verify Ed25519 signatures in
import-free JavaScript (see below).

---

## 2026-08-13 — Config lives in files, fetched over HTTPS

**Context.** Owner must be able to change job criteria and add or remove sources by editing a file —
without touching workflows. But "no host filesystem" rules out reading files from disk.

**Decision.** Config lives in `config/*.json` in the repo. `WF-L0 lib-config` fetches each file over
HTTPS from a base URL held in an n8n variable (`PP_CONFIG_BASE_URL`), validates its shape, and caches it
in `config_cache` with its `ETag`. Every workflow reads config through `WF-L0`.

**Why.** It is the only mechanism that behaves identically on Cloud, a laptop and a Pi. Edit → push →
next run picks it up. Free side benefits: full version history of preference changes, and a fork gets its
own config by pointing the variable at its own raw URL.

**Rejected alternatives.** Config in Postgres (not a file, so fails the requirement) · a mounted volume
(breaks Cloud) · n8n Variables (not a file, not diffable, awkward to migrate).

**Consequences.** A config fetch failure must **use the last good cached copy and alarm** — never fail
silently, never run on nothing. Workflows never write back to `config/`; discovered sources go to the
`discovered_sources` table instead, so the owner's files stay theirs.

---

## 2026-08-13 — Prompt version is a hash of template + profile

**Context.** The score cache is keyed `(content_hash, prompt_version, model)`. The PRD never specifies
where the candidate profile lives, yet the scorer is meaningless without it.

**Decision.** The profile is part of the prompt, and `prompt_version = sha256(prompt_template + profile
block)`, computed by the Crypto node.

**Why.** If the profile sat outside the versioned prompt, editing skills or graduation year would leave
every cached score stale *forever*, silently. Deriving the version from content makes cache invalidation
automatic and impossible to forget.

**Rejected alternatives.** Manual `prompt_version` bumps — one forgotten bump produces silently wrong
scoring with no symptom.

---

## 2026-08-13 — Discord, not WhatsApp

**Context.** The PRD specifies WhatsApp via Twilio, and treats the 24-hour session window as the project's
most interesting engineering.

**Decision.** Discord.

**Why.** Free with no per-message cost; no template pre-approval; no 24-hour window; rich embeds and
buttons natively. The Twilio sandbox additionally requires re-joining every 72 hours, which is flatly
incompatible with running unattended for weeks.

**Consequences.** The `session_state` table and all window-branching logic are **deleted** from the
design, not deferred. The cost: there is no native Discord Trigger in n8n (verified 2026-08-13 — only
community nodes, which break Cloud portability), so inbound interactions need a plain Webhook plus
Ed25519 signature verification written in import-free JavaScript. Discord refuses to register an endpoint
that doesn't verify correctly, so this is not optional. That difficulty is why interactions are Phase 5,
after one-way alerts are already delivering value.

---

## 2026-08-13 — Licensed aggregators, never scraping LinkedIn/Naukri

**Context.** Owner asked for LinkedIn, Naukri and Instahyre coverage — the primary Indian job platforms —
and asked whether bot detection could be evaded for free, scraping about once a day.

**Decision.** No bot-detection evasion of any kind: no fingerprint spoofing, no proxy rotation to dodge
bans, no CAPTCHA solving. Those listings arrive instead through free tiers of licensed aggregators —
JSearch (200 req/mo, carries LinkedIn/Indeed/Glassdoor/ZipRecruiter/Bayt) and SerpApi `google_jobs`
(250/mo, and Google for Jobs indexes Naukri, LinkedIn, Indeed and Instahyre), alongside Adzuna, Jooble
and Careerjet.

**Why.** In order of relevance to the owner:
1. LinkedIn job search requires an authenticated session, so the account carrying the ban risk is the
   owner's professional identity — during their job hunt. A restriction in week 3 is the worst outcome
   this project could produce.
2. It cannot run unattended. LinkedIn's Voyager API bans within 3–7 days, and Proxycurl — a funded
   company — was litigated out of existence in July 2026. N3 is simply unachievable that way.
3. There is no durable *free* evasion: free proxies are pre-blacklisted, and residential proxies cost
   more than the aggregators that make the question moot.

**Consequences.** Identical listings, zero ban risk, $0 — but subject to hard monthly quotas, so
`api_quota` is checked *before* a call is spent and capped providers are skipped (N7). Direct fetching of
company career pages remains fine and is Tier D: public pages, cached `robots.txt` honoured, ≤1 req/s,
identifying User-Agent, conditional requests, once daily.

---

## 2026-08-13 — Immediate alerts; send-once enforced by the database

**Context.** The PRD batches alerts — top 3 per run plus a count — to control Twilio conversation cost.
Owner wants a genuinely good match sent the moment it is found.

**Decision.** No batching and no digest. A qualifying posting goes to Discord immediately. Send-once is
enforced by `UNIQUE (posting_id, channel)` on `notifications`.

**Why.** Discord messages are free, so the cost argument for batching disappears; and speed is the point
— an internship applied to an hour after posting beats one applied to a day later. But immediate sending
removes the batch that would otherwise catch a repeat, so the guarantee has to move somewhere stronger
than workflow logic: a retry, a concurrent run or a partially-failed execution cannot violate a unique
constraint.

**Consequences.** Poll cadence becomes the latency floor — ATS boards hourly (free, unlimited),
aggregators and career pages daily (quota-bound). Do not add workflow-level dedup as a substitute for the
constraint.

---

## 2026-08-13 — The prefilter is conservative; there is no kill-rate target

**Context.** The PRD makes "prefilter eliminates ≥60% of postings before any LLM call" a success
criterion, as a cost-engineering story.

**Decision.** Drop the target. The prefilter rejects only on unambiguous mismatch with stated
preferences: an excluded role keyword, a location neither remote nor allowed, an explicit experience
requirement above the maximum, a graduation-year exclusion. Anything ambiguous goes to the LLM. Kill rate
is measured and reported, never optimised toward.

**Why.** Owner's instruction, and it is correct: a relevant posting that gets filtered out is a job not
applied to. A missed good job is a real loss; a fraction of a cent of Haiku tokens is not. Optimising a
recall-critical filter for rejection rate is optimising the wrong direction.

**Consequences.** Higher LLM spend per run than the PRD envisaged, controlled instead by content-hash
caching and the enforced daily spend cap. Recall stays weighted above precision throughout Phase 7 too.

---

## 2026-08-13 — pg_trgm for near-duplicate detection, not embeddings

**Context.** The PRD specifies `all-MiniLM-L6-v2` embeddings at cosine ≥0.90, computed locally in Python.

**Decision.** Postgres `pg_trgm` trigram similarity over a normalized, truncated description, scoped per
normalized company.

**Why.** No Python runtime means no local sentence-transformers, and calling an embeddings API adds a
provider, a cost and a quota. Trigram similarity is free, runs inside the database we already have, works
on Neon and Supabase, and — critically — is calibrated exactly the same way: hand-label 50 pairs, sweep
the threshold, pick max F1.

**Rejected alternatives.** `pgvector` + a free-tier embeddings API — kept as the documented upgrade path
if trigram F1 proves insufficient in Phase 6.

**Consequences.** Comparison stays scoped per company, so it is O(n) per company rather than O(n²)
globally. The chosen threshold becomes a `WF-0` fixture so a later change can't silently move it.

---

## 2026-08-13 — Reliability is built second, not last

**Context.** The PRD hardens in Week 6, after everything else.

**Decision.** Error workflow, per-node retry, continue-on-fail and the zero-result alarm land in Phase 3,
immediately after the tool starts being useful.

**Why.** Collection runs unattended from Phase 1. Without an error branch, a source failing in week 2
means the owner silently stops receiving jobs and doesn't find out — the exact failure this tool exists to
prevent. N6 ("an error branch that has actually fired and recovered") also needs the longest possible
window in which to fire naturally.

**Consequences.** The zero-result alarm is treated as a headline feature, not a nicety: a source
returning 0 twice consecutively is the realistic way this project dies quietly.
