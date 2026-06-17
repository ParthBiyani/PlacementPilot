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

---

## 2026-08-14 — Two HTTP Request pitfalls found building WF-L0, binding on every future HTTP node

**Context.** Building and CLI-testing WF-L0 against the real running n8n instance (not blind JSON
authoring) surfaced two behaviors that would have silently broken every workflow that fetches an external
URL — WF-1c career pages, WF-1b aggregators, WF-1d discovery, WF-4 Gmail's classify step all use
`n8n-nodes-base.httpRequest`.

**Finding 1 — `$env` is denied by default in this n8n version.** An expression like
`{{ $env.PP_CONFIG_BASE_URL }}` throws `ExpressionError: access to env vars denied`, contradicting the
assumption (never actually verified before building) that env vars would be readable from expressions.
**Decision:** use n8n's own **Variables** feature (`$vars.NAME`) instead — which is what the original
design already specified in `CLAUDE.md` ("a URL held in an n8n variable"); the first implementation just
used `$env` by mistake. Seeded via direct SQL insert into `n8n.variables` this session (not a secret, so
no chat/credential-store question); the equivalent supported path is Settings → Variables in the UI.
**Consequence:** `docker-compose.yml` no longer passes `PP_CONFIG_BASE_URL` into the n8n container's
environment for this purpose — the `.env` entry is now just the human-readable reference for what to set
as the Variable.

**Finding 2 — `ignoreResponseCode: true` does not cover a non-JSON body.** With
`responseFormat: "json"`, a non-2xx response whose body isn't valid JSON (e.g. GitHub raw's plain-text 404
page) throws `Response body is not valid JSON` regardless of `ignoreResponseCode` — that option only
suppresses treating the *status code* as an error, not a body-parsing failure. **Decision:** every HTTP
Request node that must inspect status codes on failure uses `responseFormat: "string"` with
`options.fullResponse: true`, and parses the body manually (`JSON.parse` in a downstream Code node,
wrapped in try/catch) rather than relying on the node's built-in JSON mode.

**Consequences.** Both fixes are now the standing pattern for every future HTTP Request node in this
project, not just WF-L0. Verified end-to-end against the real GitHub-hosted config: all four WF-L0
outcomes exercised and passed — `fresh` (200, cache written), `cached_not_modified` (304, conditional
request via `If-None-Match`), `fallback_alarm` (fetch fails, stale cache served), `hard_fail_alarm` (fetch
fails, no cache, throws — becomes WF-5's job to alarm once Phase 3 wires it).

---

## 2026-08-14 — Postgres `executeQuery` writes need `RETURNING`, or the workflow silently dead-ends

**Context.** Building WF-0, the same bug appeared that WF-L0's `Upsert Cache` had already sidestepped by
convention (referencing `$('NodeName')` instead of relying on passthrough) without the *reason* being
written down: an `INSERT`/`UPDATE` via `n8n-nodes-base.postgres` `executeQuery` with no `RETURNING` clause
produces **zero output items**. In n8n, zero items flowing into a node means that node — and everything
downstream of it — simply does not execute. No error, no log line. WF-0's `Write Run` insert had no
`RETURNING`, so `Is All Passed?` and everything after it silently never ran; the CLI execution reported
`"status": "success"` with `"lastNodeExecuted": "Write Run"`, which looks like nothing is wrong unless you
notice the workflow stopped one node early.

**Decision:** every Postgres write node in this project ends its query with `RETURNING` something (even
just the primary key), full stop. This is not optional style — it is required for the workflow's control
flow after the write to run at all.

**Why.** This is the second time in one session that "zero items" turned out to be a silent workflow
killer distinct from an actual thrown error (the first was `Get Cached` in WF-L0, fixed with a `LEFT JOIN`
against a synthetic single row for the same underlying reason). Both were only caught by actually
executing the workflow via CLI and inspecting `lastNodeExecuted`, not by reading the JSON.

**Consequences.** Applies to every future write: WF-1's `postings` upsert, WF-2's `evaluations` insert,
WF-3's `notifications` insert, WF-3b's `applications` update, WF-4, WF-5's `runs` insert, WF-6's
`eval_runs` insert. When reviewing any future workflow (own or otherwise), a Postgres write with no
`RETURNING` immediately followed by more nodes is a bug, not a style choice.

---

## 2026-08-14 — Three more pitfalls found building WF-1, against real ATS APIs

**Context.** WF-1 is the first workflow fetching from *real third-party APIs with real data volume*
(Greenhouse, Lever, Ashby — hundreds of jobs per company), not a single controlled config file. Testing
against real Postman/Groww/Linear boards surfaced three more issues no amount of reading the JSON would
have caught.

**Finding 3 — `options.fullResponse` is silently ignored unless `jsonParameters: true` is also set.**
Without it, the HTTP Request v1 node dropped `statusCode`/`headers` entirely and returned only the parsed
body under `dataPropertyName` — no error, just a different, smaller shape than requested. WF-L0 happened
to have `jsonParameters: true` already (needed there for a custom `If-None-Match` header), which is why
its `fullResponse` worked and masked this dependency. **Decision:** `jsonParameters: true` is now set on
every HTTP Request node in this project that also sets `options.fullResponse: true`, regardless of
whether custom headers are needed.

**Finding 4 — the response body's field name depends on the server's `Content-Type`, not on
`responseFormat`.** `raw.githubusercontent.com` serves `.json` files as `text/plain` (a known GitHub
quirk), so WF-L0 correctly got a raw string under `body`. Greenhouse/Lever/Ashby correctly send
`Content-Type: application/json`, so the node auto-parses the body into an object and places it under
`dataPropertyName` (`data`) *instead of* `body` — even with `responseFormat: "string"` explicitly set.
Relying on `resp.body` unconditionally is not safe. **Decision:** every parser reads
`resp.body !== undefined ? resp.body : resp.data`, then only calls `JSON.parse` if that value is still a
string — handling both server behaviors instead of assuming one.

**Finding 5 — a Postgres `executeQuery` node with no per-item query parameters still runs once per
input item, not once total.** `Get Active ATS Sources` (a static `SELECT`, no `$1` placeholders) was fed
4 items from `Sync Sources` and executed the identical query 4 times, returning 4×4=16 rows instead of 4.
**Decision:** any query meant to run exactly once, regardless of upstream item count, must be fed by
exactly one item — a small `Collapse To Single Trigger` Code node (`return [{ json: {} }]`) sits between
any many-items node and a single-shot query.

**Also found (schema bug, not a node pitfall):** the first working version set `postings.source_id` to a
compound `board:jobid` string (e.g. `greenhouse:postman:4880153101`), which violates the
`postings_source_id_fkey` constraint — `source_id` must be exactly the board's `sources.id`
(`greenhouse:postman`). Fixed by dropping the per-job suffix; the posting's own `id` (the WF-L1 dedup
hash) already uniquely identifies it.

**Consequences.** Verified end-to-end against real data after all five fixes: Postman (105 postings),
Groww (8), Linear via Ashby (32) — 145 real, correctly-parsed, correctly-deduplicated postings, zero
duplicate primary keys, `runs` rows with accurate fetched/new/deduped counts per provider, and Lever
(Mistral, genuinely zero live postings) handled without error. All test data and the throwaway test
workflow were deleted after verification.

---

## 2026-08-14 — Correction: n8n Variables are license-gated on this instance; back to `$env`, deliberately unblocked

**Context.** The "Two HTTP Request pitfalls" entry above documented switching from `$env` to `$vars`
(n8n's Variables feature) after `$env` access from expressions threw `access to env vars denied`. That
fix was never validated end-to-end — it silently resolves to `undefined` rather than erroring, so nothing
surfaced the problem until Phase 2 testing, weeks of session-time later.

**Decision.** Reverted to `$env.PP_CONFIG_BASE_URL`, deliberately unblocked via
`N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` in `docker-compose.yml` — a real, documented n8n security setting,
unrelated to the Variables feature.

**Why.** Discovered live: Settings → Variables in this n8n instance shows "Upgrade to unlock variables" —
Variables is gated behind a paid plan on this edition, and a gated Variable doesn't throw when read from
an expression, it silently resolves to `undefined`. `{{ $vars.PP_CONFIG_BASE_URL }}/{{ $json.file }}`
therefore evaluated to the literal string `undefined/preferences.json` on **every single run since Phase
1** — WF-L0 has been fetching a broken URL this entire time. It "worked" in Phase 1 testing only because
that testing happened not to exercise a genuine fresh-200 fetch against the real configured value all the
way through (see the next entry — a second, independent bug was also masking this one). This is the most
consequential bug found this session: it silently invalidated the earlier decision's stated fix without
ever surfacing an error, in a way that would have made the *entire system* non-functional in production.

**Rejected alternatives.** Upgrading the n8n plan — out of scope/cost for a $0/month tool (P4). Hardcoding
the URL directly into `wf_l0_config.json`'s HTTP node — simpler, but loses the "one place to configure, no
workflow edits" property `$env`/`$vars` both provide; `$env` unblocked achieves the same portability goal
`$vars` was meant to, without the licensing dependency.

**Consequences.** `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` and `PP_CONFIG_BASE_URL: ${PP_CONFIG_BASE_URL}`
are now standing entries in `docker-compose.yml`'s n8n environment block, with an inline comment recording
both this and the original `$env`-denied finding so nobody swings back to `$vars` without first confirming
Variables is unlocked on whatever instance is running. **Standing rule going forward: never trust a
config-read mechanism (`$vars`, `$env`, or otherwise) that "works" without a live, end-to-end 200-status
test through the real fetch path** — a silently-undefined read is indistinguishable from a correct one
until something downstream fails loudly, and here it took until Phase 2 to notice.

---

## 2026-08-14 — WF-L0's `Decide Outcome` had the same body/data pitfall as WF-1, undetected since Phase 1

**Context.** "Three more pitfalls found building WF-1" (above) documented that a JSON-content-type HTTP
response lands under `resp.data`, not `resp.body`, and fixed every WF-1 parser accordingly. WF-L0's own
`Decide Outcome` node — built earlier the same day — was never updated to match, because at the time
GitHub's `text/plain` response genuinely did populate `resp.body` as a string. Live testing during Phase 2
found `resp.body` was `undefined` and the actual content was sitting under `resp.data` as an
**already-parsed object** — contradicting the WF-1 finding's own claim that GitHub raw specifically lands
under `body`.

**Decision.** Applied the same `resp.body !== undefined ? resp.body : resp.data` fallback to
`Decide Outcome`, with `typeof raw === 'string' ? JSON.parse(raw) : raw` guarding the parse step (since
`resp.data` can already be a parsed object here, unlike the always-string `resp.body` case WF-1's finding
was originally written for).

**Why.** Whatever actually determines the body/data split (server `Content-Type`, n8n's own JSON
auto-detection, or some combination) is not stable enough to hardcode a per-source assumption — the same
GitHub endpoint that put content under `body` when WF-1 was first tested put it under `data`
(pre-parsed) when WF-L0 was retested later. Combined with the `$vars` bug above, `Decide Outcome`'s
`JSON.parse(resp.body)` was throwing on `undefined` on **every real fetch**, always landing in
`hard_fail_alarm` or `fallback_alarm` — masked because Phase 1's own WF-L0 testing happened not to isolate
a genuine fresh-200-with-real-URL case cleanly from the cache/fallback paths.

**Consequences.** The body-or-data fallback with a parse-only-if-string guard is now mandatory for **every**
HTTP Request node in this project, full stop — not just WF-1's provider parsers. `WF-L0`'s "built, tested,
correct" status recorded in `FLOW.md` on this date was accurate for the paths actually exercised then, but
wrong for a genuine fresh fetch specifically; this entry is the correction, not a retroactive edit of that
one.

---

## 2026-08-14 — pairedItem cross-node references are unreliable through AI/LangChain nodes and Merge nodes; use index lookups instead

**Context.** WF-2's `Validate Attempt 1`/`2` and `Decide Notify` code nodes recovered per-item context via
`$('NodeName').item.json`, matching a pattern already proven reliable earlier this session through
Postgres nodes (WF-L0's `Finalize` → `Decide Outcome`; WF-1's `Parse Greenhouse` → `Get Active ATS
Sources`). Live multi-item testing showed this pattern silently returning the *wrong or empty* item
specifically when the immediately-preceding node was the **Anthropic** (`@n8n/n8n-nodes-langchain.anthropic`)
node, or when resolving back through a **Merge** node whose other input branch never fired in that
execution — which is the normal case, since any given scoring batch has *some* cache hits and *some*
misses, so one Merge input is always empty.

**Decision.** Replaced every `$('NodeName').item.json` reference downstream of an Anthropic node or a
Merge node with `$('NodeName').all()[$itemIndex].json` — positional lookup by the current item's own
index, which has no dependency on pairedItem metadata at all. Left `.item.json` in place only where
already proven safe: immediately after a Postgres node, no Merge in between.

**Why.** The failure is silent, not thrown: the reference resolves to an item with the right *shape* but
wrong or missing *values* (fields present as `undefined`), so a perfectly-valid LLM JSON response can look
completely normal while scoring a blank posting. First caught by noticing a real, highly-relevant test
posting scored `match_score: 0` with the LLM's own complaint that the posting was empty — the LLM was
correct; `ctx.user_message` genuinely was blank at generation time. Index-based lookup is strictly more
reliable than name-plus-pairedItem resolution because it has no dependency on any given node type
correctly tagging or propagating pairedItem — it just reads position N of a node's own recorded output.

**Consequences.** Standing rule for every future workflow: **after an AI/LangChain node, or after a Merge
node, use `$('NodeName').all()[$itemIndex]`, never `.item`.** Treat `.item.json` as trustworthy only after
a node type already proven safe in a straight-line chain — Postgres is the only entry on that allowlist so
far; nothing else should be assumed safe by default. WF-2's `Tally` node also gained defensive `try/catch`
guards around every `$('X').all()` count for a branch that may legitimately have zero items in a given run
(cache-hits-only or misses-only batches are both normal), matching the pattern already used for
`Call WF-3`.

---

## 2026-08-14 — n8n CLI `execute`'s pinData does not reliably reach nodes beyond a direct single hop

**Context.** Testing WF-2/WF-3 needed fake input data injected at a manualTrigger substituted for the real
trigger — WF-L0/WF-1's earlier tests never actually needed this (they hardcoded return values in a Code
node, or read real seeded Postgres rows), so this is a genuinely new finding, distinct from the earlier
"CLI execute ignores pinned trigger data" note about `executeWorkflowTrigger`. Setting `pinData` on a
`manualTrigger` node and reading it via `$('TriggerName').all()` from a downstream node — even a
directly-connected one, even through nothing but a passthrough Code node — consistently returned
`[{json: {}}]`, discarding the real pinned values entirely.

**Decision.** Stopped relying on `pinData` for CLI testing altogether. Fake test input now comes from a
dedicated Code node (`return postings.map(p => ({json: p}))` or equivalent) spliced directly into the main
execution chain — not a parallel branch, see the ordering pitfall below — referenced by name from wherever
the real trigger would normally be referenced.

**Why.** Confirmed CLI-testing-only, not a production issue: building a parent workflow that invokes WF-2
through a **real** `executeWorkflowTrigger` via a genuine `Execute Workflow` node call — exactly how WF-1
invokes WF-2 in production — resolved `$('When Executed by Another Workflow').all()` correctly on the
first try, with real extracted scores landing correctly in Postgres. The bug is specifically in how the
CLI's `execute` command materializes `pinData` for a trigger node, not in n8n's real execution engine.

**A second, related ordering pitfall found in the same testing:** a Code node placed on a *parallel*
branch off the trigger (rather than spliced into the main chain) is not guaranteed to have executed yet
when a sibling branch's node references it by name — `Node 'X' hasn't been executed`, even though X is
directly connected to the trigger. Splicing the seed node into the main chain (trigger → seed → rest of
the real chain) fixes this deterministically, since n8n then has an explicit edge establishing order.

**Consequences.** Standing pattern for every future CLI test needing fake input data: a hardcoded Code
node spliced into the main chain, never `pinData` on a trigger, and never a same-trigger parallel branch
when a downstream node will reference the seed node by name.

---

## 2026-08-14 — Score contract extended with `deadline`/`eligibility`, extracted verbatim, never inferred

**Context.** After the first real Discord alert landed (Phase 2's first live end-to-end test), the owner
asked for the application deadline and eligibility criteria in the message — information that exists in a
posting's free-text description when the poster bothered to state it, but has no dedicated field in any
ATS API this project collects from.

**Decision.** Added `deadline` and `eligibility` to the LLM's JSON contract (nullable strings —
`prompts/v1.md`, `evaluations.deadline`/`evaluations.eligibility`), with the prompt explicit that both
must be **extracted verbatim from the posting text, never inferred** — no guessing a deadline from
`posted_date`, no inferring eligibility from role seniority. WF-3's Discord embed reformats a recognized
`YYYY-MM-DD` deadline into a readable form (`30th September, 2026`) and passes anything else (e.g.
`"Rolling"`) through unchanged.

**Why.** Matches the project's existing `missing_skills`-style pattern — structured extraction bolted onto
the scoring call rather than a separate LLM pass, since it's the same request already reading the full
description. Verbatim-only avoids the LLM inventing a plausible-sounding deadline or eligibility bar that
isn't actually stated, which would be actively worse than showing "Not stated."

**Consequences.** This changes the rendered prompt template text, which silently bumps `prompt_version`
(the hash includes the full template) — by design, per the existing prompt-version decision above: every
cached score under the old contract shape is correctly treated as stale and re-scored, no manual cache
bust needed. `db/schema.sql`'s `evaluations` table gained two nullable `TEXT` columns; the live database
was migrated with `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` rather than re-applying `schema.sql`, since
that file's `CREATE TABLE IF NOT EXISTS` statements don't retroactively add columns to a table that
already exists — worth remembering for any future schema change against a database that already holds
data.
