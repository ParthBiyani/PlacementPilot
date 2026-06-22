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

---

## 2026-08-14 — `executeWorkflow` node's `workflowId` needs the resource-locator shape, not a bare string

**Context.** Phase 3 testing hit a wall on WF-0: `Call WF-L1` failed every real, non-CLI execution with
"No information about the workflow to execute found. Please provide either the 'id' or 'code'!" — despite
`source: database` being set and a bare workflow ID string being present in the node's parameters. This
looked identical to an n8n publish/activation problem, and a long investigation went down that path first
(see the dead-end entry immediately below) before the real cause turned up in n8n's own source inside the
container: `ExecuteWorkflow/GenericFunctions.js`'s `getWorkflowInfo()` does
`if (nodeVersion === 1) { workflowInfo.id = this.getNodeParameter('workflowId', itemIndex); } else { const
{ value } = this.getNodeParameter('workflowId', itemIndex, {}); workflowInfo.id = value; }`. Every
`Call WF-*` node in this project is `typeVersion: 1.2`, so it takes the `else` branch — destructuring
`value` out of a bare string yields `undefined`, exactly matching the observed error.

**Decision.** Changed every `executeWorkflow` node's `workflowId` parameter from a bare ID string to the
resource-locator object the node actually expects: `{"__rl": true, "value": "<id>", "mode": "id"}`. Six
occurrences across three files: WF-0→WF-L1, WF-1→WF-L0/WF-L1/WF-2, WF-2→WF-L0/WF-3. WF-L0's new fallback
alarm call to WF-5 (added the same session, see further below) was built with the correct shape from the
start.

**Why.** This is the only change that mattered — no publish/activation state, no n8n config flag, and no
restart-timing issue was ever actually involved. Verified directly: after the fix (with no other change),
a real UI-triggered execution of WF-0 correctly showed `Call WF-L1 — Workflow: 773d1f4a0f6b4bf7` and
completed successfully end to end.

**Consequences.** Every future `executeWorkflow` node in this project (WF-1b/WF-1c/WF-1d, WF-6, anything
else added later) must use the resource-locator shape for `workflowId`, never a bare string, regardless of
whether the ID came from a hardcoded value or an expression. This is now the standing pattern, alongside
the existing SHA-256/Crypto-node and `$env`-not-`$vars` patterns.

**Open question, deliberately not resolved:** it's unclear whether this bug is new (introduced by an n8n
version bump between Phase 1 and this session, silently breaking previously-working calls) or whether it
was present all along and Phase 1/2's "verified" `source: database` calls happened to route around it —
e.g. via CLI executions or manual clicks that exercise different code paths than a real chained
sub-workflow call. No evidence was found either way, and it isn't worth chasing further now that the fix
is in and independently re-verified this session; noted here only so a future "wait, didn't we already
test this?" moment isn't mistaken for a regression.

---

## 2026-08-14 — Dead end: `workflow_published_version` / publication outbox is not what needed fixing

**Context.** Recorded so nobody re-investigates this path on a future "Execute Workflow can't find the
sub-workflow" error. Before finding the real cause above, this session spent a long time inspecting n8n's
newer dual publishing system: `workflow_entity.active`/`activeVersionId` (what the CLI's
`publish:workflow` command sets) is architecturally separate from a `workflow_published_version` table
that a `WorkflowPublishedDataService` queries at runtime — with an outbox table
(`workflow_publication_outbox`) apparently meant to populate it asynchronously via a
`WorkflowPublicationApplier`.

**What was actually true, read directly from n8n's own source in the running container:** this entire
second system is gated behind `N8N_USE_WORKFLOW_PUBLICATION_SERVICE` (config key
`workflows.useWorkflowPublicationService`), **which defaults to `false` and is not set anywhere in this
project's `docker-compose.yml`.** With it off — the actual state of this instance — every code path that
matters (`source: database` Execute Workflow resolution in `workflow-execute-additional-data.js`'s
`getPublishedWorkflowData()`, and error-workflow loading in `workflow-execution.service.js`'s
`loadErrorWorkflowData()`) falls through to the legacy branch, which needs only
`workflow_entity.activeVersionId` pointing at a valid `workflow_history` row — exactly what the CLI's
`publish:workflow` command already sets correctly. The empty `workflow_published_version` table observed
throughout the investigation was never the problem; it's simply unused while the flag is off.

**Consequences.** Do not chase `workflow_published_version` / the publication outbox / "is it *really*
published" on this instance again — the CLI's existing `import:workflow` → `publish:workflow` → restart
sequence (already the project's standing pattern since Phase 1) is sufficient and correct for
`source: database` resolution and error-workflow dispatch as long as
`N8N_USE_WORKFLOW_PUBLICATION_SERVICE` stays unset. If that env var is ever deliberately turned on for some
future reason, this whole conclusion needs re-checking.

---

## 2026-08-14 — Near-miss: fixing the `executeWorkflow` bug briefly activated WF-1 for real

**Context.** The CLI's `publish:workflow` command sets `active: true` *and* `activeVersionId` together —
there is no way to update just the version pointer without also flipping the workflow's own trigger live.
Applying the `workflowId` fix to `wf1_collect_ats.json` required a `publish:workflow` + restart cycle like
every other workflow this session, which — as a side effect neither asked for nor noticed until checked —
set WF-1's `active` flag to `true`, arming its real hourly Schedule Trigger against live Greenhouse/Lever/
Ashby APIs. Activating WF-1 has been an explicit "blocked on the user" decision since Phase 2 completed;
this bypassed that without asking.

**Decision.** Caught by checking `workflow_entity.active` immediately after the restart (a habit worth
keeping any time `publish:workflow` touches a schedule/webhook/poll-triggered workflow). Deactivated
immediately via `import:workflow` (which syncs `active: false` from the committed JSON's own `"active":
false` field) — no restart needed for deactivation to take effect, confirmed by the "Deactivating
workflow..." message it prints immediately. Cross-checked `runs` and `execution_entity` for the ~10-minute
window WF-1 was actually live: zero real fires occurred (its hourly schedule didn't cross a boundary in
that window), so no unintended external traffic happened.

**Why.** `publish:workflow`'s coupling of "make this the resolvable version" and "make this workflow's own
trigger live" is not obvious from the command's name or its own output, and is easy to miss precisely
because the workflow ends up in the *correct* state for source-database resolution — the only thing wrong
is a side effect on a completely different property.

**Consequences.** Standing rule: whenever `publish:workflow` is run against a workflow with its own
schedule/webhook/poll trigger (as opposed to an `executeWorkflowTrigger`-only sub-workflow like WF-L0/
WF-L1/WF-2/WF-3), check `workflow_entity.active` immediately after and reconcile it against the intended
state before moving on — don't assume publishing a fix left activation state untouched.

---

## 2026-08-14 — Phase 3 alarm surface completed: WF-1 zero-result gap, WF-L0 fallback alarm, both verified live

**Context.** Two gaps had been called out since Phase 1/2 but left for Phase 3: a provider branch in WF-1
that returns zero postings never reached `Write Run` (zero items = the node never fires, so a source going
silent was indistinguishable from "didn't run"), and WF-L0's `fallback_alarm` outcome returned cached data
successfully but never actually alarmed despite CLAUDE.md requiring it to.

**Decision — WF-1.** Replaced the single blended `Tally Results` → `Write Run` pair with a per-source
aggregation: `Aggregate Per Source` seeds one entry for every source `Get Active ATS Sources` returned
*before* fetching (fetched=0, new_count=0), then folds in whatever `Dedup Upsert` actually produced —
guaranteeing one `runs` row per source every run regardless of whether that source returned any postings,
the same guaranteed-row idea as WF-L0's `Get Cached` LEFT JOIN. A parallel `Update Source Zero-Streak`
node increments `sources.consecutive_zero` on a zero-fetch source and resets it to 0 the moment a source
recovers; `Check Zero Alarm` throws (after both writes have already committed, so the alarm can never
block the data it's reporting on) once any source's streak reaches 2, dispatching through WF-1's existing
`errorWorkflow` setting to WF-5. Also had to add `source_id` to `Dedup Upsert`'s `RETURNING` clause, since
the per-posting `source_id` wasn't previously being returned at all.

**Decision — WF-L0.** Added a parallel branch off `Decide Outcome` (independent of the main
fresh/cached/hard-fail branch that returns data to the caller): `Is Fallback Alarm?` checks
`outcome === 'fallback_alarm'`, and on true calls WF-5 directly via `Call WF-5 (fallback alarm)` — using
its `executeWorkflowTrigger` "explicit call" entry point, the same one WF-1's zero-result alarm and the
`_TEST wf5 explicit` verification from earlier this session already exercised. This branch runs
side-by-side with, not instead of, the normal `Finalize` path, so the caller still gets the cached config
back successfully — alarming and degrading gracefully are not mutually exclusive.

**Why.** Both were verified against real conditions, not fixtures. WF-1: two real, independently-triggered
executions of the real 15-source board list 15 minutes apart happened to produce exactly this scenario
without being contrived — `ashby:deel`, `lever:mistral` and `lever:plaid` returned zero postings both
times (their `consecutive_zero` correctly reached 2), while sources that succeeded once and then returned
zero the second time correctly sat at 1, and `Check Zero Alarm` correctly named only the three that
crossed the threshold. WF-L0: seeded a real `config_cache` row for a nonexistent filename, called WF-L0
for real, and got a real Discord alarm with the exact composed message, while the calling test workflow's
execution still completed with `status: success` — confirming the graceful-degrade-and-alarm behavior
together, not just one half of it.

**Consequences.** All three of Phase 3's alarm requirements from CLAUDE.md's TODO — WF-5 wired to every
workflow, the zero-result alarm, the config-fetch-failure alarm — are now built and independently verified
live. Remaining Phase 3 items are process, not code: weekly workflow export to git via the n8n REST API,
and a deliberate chaos test (dead token mid-run recovers unattended).

---

## 2026-08-14 — Four candidate Indian job sources rejected after real verification, not assumption

**Context.** The owner asked about better sources for the Indian market. A first-pass recommendation named
four: Internshala, Wellfound (formerly AngelList Talent), Cutshort, Hirist. None were verified before being
suggested — checking them for real, the same discipline this project has used for every ATS endpoint since
Phase 0, changed the answer.

**Decision.** None of the four are being integrated.
- **Internshala** — `robots.txt`, fetched directly (not summarized), disallows `/internship/search/`,
  `/internship/details/`, `/job/search/`, `/job/details/` under `User-Agent: *` — the exact pages a scraper
  would need. CLAUDE.md's polite-fetching rule requires honouring `robots.txt`; this isn't a judgment call.
- **Wellfound** — no official public jobs API exists anymore (the old AngelList Talent API is gone); every
  option found is a paid third-party scraper. Breaks both the no-scraping-without-permission principle and
  the $0/month goal (P4).
- **Cutshort** — has a real, documented API (`developers.cutshort.io`), but it's a B2B recruiter tool for
  *searching candidates* and managing applications, not a jobs feed for candidates. Wrong direction.
- **Hirist** — same as Wellfound: no public API, third-party scrapers only.
- **Indirect route via SerpApi's `google_jobs` engine also doesn't work** — confirmed from SerpApi's own
  docs, that engine has no `site:`/domain-restriction parameter at all, only free-text `q` plus location/
  language. There's no way to target a specific job board through it, in either direction.

**Why.** Recommending a source without checking whether it can actually be integrated compliantly wastes
build time and risks shipping something that violates the project's own non-goals (no bot-detection evasion,
no scraping against `robots.txt`). Better to find this out before writing a single node than after.

**Consequences.** No new config for these four. The existing Phase 4 plan (WF-1b's licensed aggregators,
which already carry LinkedIn/Naukri/Indeed coverage, plus WF-1d's accelerator-portfolio discovery) remains
the legitimate path to broader Indian-market coverage. If a genuinely compliant path to any of these four
turns up later (e.g. Wellfound ships a real public API), revisit then — not before.

---

## 2026-08-14 — The stored "SerpAPI account" credential was the wrong type for what WF-1b needs

**Context.** Investigating the SerpApi-based routing idea above required understanding how the existing
"SerpAPI account" n8n credential (type `serpApi`) actually gets used. It turned out to not be usable by a
plain HTTP Request node at all.

**Decision.** Traced the credential type to `@n8n/n8n-nodes-langchain`'s `ToolSerpApi` node — a
**deprecated, hidden** AI-agent tool sub-node (`outputs: [NodeConnectionTypes.AiTool]`, no regular data
output) meant to be wired into an Agent's tool list, not called directly in a linear workflow. It calls
`@langchain/community`'s generic Google Search wrapper (not the `google_jobs` engine) and returns
LLM-tool-formatted text, not structured JSON. A plain `httpRequest` node's authentication dropdown only
accepts generic types (`httpQueryAuth`, `httpHeaderAuth`, etc.) — it cannot select a `serpApi`-typed
credential at all. Had the owner create a new credential of type **Query Auth** (`httpQueryAuth`, param
name `api_key`) holding the same key, which a normal HTTP Request node can attach and use to call
`serpapi.com/search.json?engine=google_jobs&...` directly.

**Why.** This would have blocked WF-1b regardless of the Indian-sources question — it's specific to how
this n8n instance's credential was originally created, not to any particular query. Worth catching now
rather than mid-build.

**Consequences.** WF-1b's SerpApi calls must use the `httpQueryAuth` credential, not the original `serpApi`
one (left in the store, unused, harmless). Any future SerpApi credential should be created as `httpQueryAuth`
from the start.

---

## 2026-08-14 — WF-1d discover: naive ATS token-guessing yields ~0%; career-page link extraction works

**Context.** `accelerators.json`'s own comment sketched WF-1d as "extract company names and domains, then
probe ATS token patterns for each." Before building that, tested the assumption against real data: 49 real,
currently-hiring, India-located YC companies, guessing each one's Greenhouse/Lever/Ashby/Workable/
SmartRecruiters/Recruitee token from its YC `slug` field.

**Decision.** Naive slug-guessing is not the mechanism WF-1d uses. **Zero hits out of 49 companies across
all six platforms.** Traced why with a real example: Razorpay's actual Greenhouse token is
`razorpaysoftwareprivatelimited` (their full legal entity name), not `razorpay` — board tokens are chosen
by whoever set up the ATS account and are frequently unrelated to the brand slug. What does work, verified
on the same company: Razorpay's own `/careers` (well, `/jobs/` in their case) page directly links their
real Greenhouse URL in plain HTML — `curl` with a normal user-agent sees it fine, no JS rendering needed.
WF-1d now: for each India-located, currently-hiring, Active company from an enabled `json`-method
accelerator, tries three candidate career-page paths (`/careers`, `/jobs`, homepage), regex-extracts a
known ATS domain link from whichever page responds, then **confirms** the extracted token against the real
provider API pattern (the same `boards-api.greenhouse.io`-style patterns WF-1 already uses) before
registering it — so a confidently-wrong regex match still gets caught by the same 200-or-nothing check
WF-1's own fetchers rely on.

**Why.** Building the naive version first would have shipped a workflow that discovers almost nothing,
directly contradicting the project's "usefulness first" priority. Verified for real: WF-1d's first live run
found and confirmed 3 genuine boards (Bolna AI/Ashby, Razorpay/Greenhouse, Weekday/Workable) out of 49
candidates — a real ~6% hit rate, not a guess, and one that compounds every week as more accelerators get
enabled.

**Consequences.** `accelerators.json`'s own comment describing "probe ATS token patterns" is now
technically stale (the token comes from an extracted link, not a guess) but the *outcome* it describes
(boards that respond get registered in `discovered_sources`) is unchanged, so left as-is rather than
rewritten for a wording nuance. Any future accelerator enabled with `method: "json"` gets this same
treatment automatically; `method: "html"` accelerators (Techstars, Antler, etc.) still need their own
extraction logic before enabling, unchanged from the original design.

---

## 2026-08-14 — n8n Code node sandbox has no `URL` global; two silent-zero-item bugs found building WF-1d

**Context.** WF-1d's `Build Career Page Candidates` node used `new URL(j.website).origin` to derive each
company's domain, wrapped in a `try/catch` that `continue`s past parse failures (reasonable defensive
coding for genuinely malformed URLs). It silently produced zero output items against 49 items of
demonstrably valid input (`https://razorpay.com`, `http://dripcapital.com`, ...).

**Decision.** n8n's Code node sandbox does not expose the `URL` constructor — `new URL(...)` throws
`ReferenceError: URL is not defined` for every single call, and the `try/catch` (there for a different,
legitimate reason) swallowed it silently, producing the exact same symptom as a genuine zero-result batch:
no error surfaced anywhere, node shows a clean green checkmark, just zero items out. Fixed by replacing it
with a plain regex (`/^https?:\/\/[^\/]+/i`) that has no dependency on sandbox-provided globals.

**Why.** This is the third distinct flavor of "silent zero items, no visible error" found in this project
(the others: zero-item branches never reaching a downstream node at all, and n8n's `getWorkflowInfo()`
resolving `workflowId` to `undefined` from a malformed parameter shape) — each looks identical from the
canvas (a clean run, just an early stop) but has a completely different root cause. Diagnosing this one
required reading the raw `execution_data` row directly from Postgres rather than trusting the canvas UI,
since the UI simply doesn't distinguish "zero items because nothing matched" from "zero items because every
iteration silently threw."

**Consequences.** Standing rule: **never assume a Node.js/browser global is available inside an n8n Code
node** — only what's been seen working in this project's own tests (`JSON`, regex, plain string/array/
object methods, `Math`, `Date`) should be assumed present. If a genuinely new built-in is needed, verify it
with a throwaway one-line test node first rather than discovering the gap via a silently-empty downstream
node. Also worth remembering generally: a `try/catch` written to handle one failure mode can just as easily
swallow a completely different one, silently — when a batch produces suspiciously exact "0 of N" output,
suspect the catch block before suspecting the input data.

---

## 2026-08-14 — WF-L0 had two competing terminal nodes, corrupting `executeWorkflow`'s output non-deterministically

**Context.** WF-1d's `Call WF-L0` node — built with the exact same, by-then-already-fixed resource-locator
`workflowId` shape used everywhere else — still failed silently, with nothing downstream of it ever firing.
Unlike every other case this project has hit, the node itself showed a clean green checkmark with real,
correct-looking data in its output panel, which is what made this one genuinely hard to catch: the bug
wasn't in the caller at all.

**Decision.** Read n8n's own `ExecuteWorkflow.node.js` source directly: in `mode: "once"`, the node's
`execute()` method sets `workflowResult = executionResult.data` and returns it as-is — `executionResult.data`
is literally **the sub-workflow's own last-executed node's raw output array, branches included**. WF-L0
used to have exactly one terminal node (`Finalize`), so this was never visible. Earlier this session, Phase
3's fallback-alarm fix added a **second**, parallel terminal node (`Call WF-5 (fallback alarm)`, reached
whenever `Is Fallback Alarm?`'s condition was true, with its false branch simply dangling with no further
connections). With two competing "last node" candidates, n8n's own bookkeeping non-deterministically picked
either `Finalize` (giving callers the intended `{file, config, outcome}` shape) or `Is Fallback Alarm?`
itself (an IF node — giving callers its raw two-branch `[[], [items]]` shape instead). Confirmed empirically
by pulling raw `execution_data` for three different real calls: WF-1's historical call showed 1 branch
(lucky), WF-1d's showed 2 branches with real data stranded on index 1 (unlucky) — same target workflow,
same caller-side parameters, different result, purely from WF-L0's own internal ambiguity. **Fixed by
restructuring WF-L0 so `Is Fallback Alarm?` runs *before* `Is Fresh?` instead of in parallel with it**, both
paths reconverging through a `Merge` node (append mode, matching the existing WF-2 cache-hit/cache-miss
merge pattern) before continuing to the original `Is Fresh?` → `Upsert Cache`/`Finalize` chain — so
`Finalize` is unambiguously the only node in the whole graph with no outgoing connections. `Call WF-5`'s own
return value is irrelevant to the caller (it's a side effect, the alarm), so a small `Restore Payload After
Alarm` node re-emits `Decide Outcome`'s original data after the alarm call completes, rather than letting
WF-5's response shape leak into the main data path.

**Why.** This was a real, latent correctness bug affecting **every** caller of WF-L0 (WF-1, WF-2, and now
WF-1d) from the moment the fallback-alarm branch was added earlier this session — WF-1's and WF-2's
"success" in the interim was luck of n8n's internal execution-order bookkeeping, not evidence the calls were
actually safe. It would have been trivial to reintroduce on any future workflow that adds a second dangling
terminal branch to a sub-workflow already called via `source: database`.

**Consequences.** Standing rule for every `executeWorkflowTrigger`-entry sub-workflow (WF-L0, WF-L1, WF-2,
WF-3, and any future one): **must have exactly one node with no outgoing connections.** Verify this
explicitly (as done here — walk the connections graph, list nodes absent as a connection source or with
every branch empty) any time a new parallel branch is added to a workflow that other workflows call via
`source: database`. This check is now baked into how WF-1d's own connections were validated before import,
and should be repeated for WF-L0/WF-L1/WF-2/WF-3 any time their graphs change again. No changes were needed
to WF-1's or WF-2's own JSON — the fix lives entirely in WF-L0, so every caller is automatically corrected.

**Side finding, not the actual cause but worth recording:** opening a node's detail panel in the n8n editor
to inspect its output (asked of the owner mid-debugging, before the real cause above was found) resulted in
a `workflowInputs`/`mappingMode: "defineBelow"` block appearing in that node's *stored* parameters that was
never written to the source JSON file — this instance has autosave enabled by default
(`workflows.autosaveDisabled = false`), so merely viewing a node can persist a UI-side default back into
the database, silently diverging from the committed file. Re-importing from the clean file removed it and
is the correct recovery — but it's a real trap for CLI-driven development: after any UI inspection session,
re-import before trusting that the live workflow still matches the repo.

---

## 2026-08-14 — Reopened the four-source question: Cutshort and Hirist are real after all

**Context.** The owner pushed back on the earlier rejection of all four candidate sources ("I don't want
to hear no, find a way"). Rather than re-assert the same conclusion, re-checked each site's own
`robots.txt` specifically (not just "is there a public API") — the first pass had wrongly conflated "no
dedicated jobs API" with "not legitimately scrapeable," without checking whether the sites' own stated
crawl policy would actually permit a polite, in-house scraper of the kind WF-1c was always designed to be.

**Decision.** The corrected picture, per-site:
- **Internshala — still blocked.** Confirmed again, no new path found: `robots.txt` disallows the exact
  search/details pages under `User-Agent: *`, for every bot.
- **Wellfound — still not viable, but for a different, more precise reason than first stated.**
  Individual job/company pages are *not* explicitly disallowed by `robots.txt` — only `/search` and various
  account/auth paths are. But their actual published sitemap (`sitemap.xml.gz` → `basics.xml.gz`) contains
  only 86 static marketing pages (`/about`, `/hire`, `/remote`, ...), no job or company URLs at all. With
  no sanctioned discovery mechanism and the only browse path (`/search`) explicitly disallowed, there's no
  compliant way to find a real job URL to fetch in the first place.
- **Cutshort — genuinely viable, built into WF-1c.** Their `sitemap_jobs.xml` explicitly publishes
  individual job URLs at `/job/{slug}`, and that exact path is *not* in the `robots.txt` disallow list
  (only a different, likely legacy path, `/view/j/`, is blocked). ~43k total URLs, ~4-5k with real,
  per-job `lastmod` timestamps updated in any given 24h window — a genuine, usable recency signal.
- **Hirist — genuinely viable, built into WF-1c.** `robots.txt` only blocks generic CMS/admin paths
  (Joomla-style: `/components/`, `/admin/`, etc.), not job content at all, plus a mandatory
  `Crawl-delay: 10`. They publish a dedicated jobs sitemap (`new_sitemap-j-1.xml.gz`, ~30k URLs) — but
  every entry shares the same `lastmod` (bulk-touched on each site rebuild), so unlike Cutshort's, it
  carries no usable per-job recency signal.

**Why.** The first pass's reasoning ("no official API → must be a paid scraper or nothing") skipped the
step this project has otherwise applied consistently since Phase 0: check the site's own stated policy
before concluding anything. A polite, `robots.txt`-respecting, rate-limited, identified-User-Agent scraper
is not "bot-detection evasion" — it's exactly what WF-1c (career pages, Tier D) was already designed to be
for arbitrary company sites; the only thing that changes here is treating Cutshort/Hirist as two more sites
in that same category, at their own stated terms, rather than as sources needing a dedicated aggregator API.

**Consequences.** WF-1c collect-pages built around these two sources specifically (see the build entry
below). Internshala and Wellfound remain correctly excluded — not from a lack of effort, but because no
compliant path exists for either, for two genuinely different reasons.

---

## 2026-08-14 — WF-1c collect-pages built and verified live: real Cutshort/Hirist postings, real alerts

**Context.** Built on the two sources confirmed viable above. Cutshort alone produces ~4-5k newly-updated
postings/day, almost none of them internships (their own profile: 1-12 years experience, general tech
hiring) — fetching and LLM-extracting every one would be both wasteful and expensive. Hirist's sitemap
carries no usable recency signal at all (see above), so date-filtering isn't an option there either.

**Decision.** Added a coarse, deliberately lossy prefilter *before* any page fetch or LLM call: regex
keyword matching directly against the job URL's slug (which embeds role/location/company text on both
sites) for an entry-level/intern signal plus a relevant-role signal, reusing `preferences.json`'s existing
`exclude.role_keywords` list to drop obvious non-matches early. This is explicitly **not** the same
guarantee as WF-2's own conservative "ambiguous always passes" prefilter — it exists purely to control
volume and cost before the expensive step, and accepts real recall risk in exchange. A hard cap
(`MAX_CANDIDATES_PER_RUN = 30`) was added for the same reason on the first live run, given Hirist's 10s
crawl-delay alone could otherwise turn an unreviewed first test into hours of unattended fetching. Also
added an anti-join against `postings.apply_url` before fetching, so re-running the same sitemap daily
doesn't re-fetch and re-extract jobs already collected.

**A real bug found on the first live test:** `Dedup Upsert` failed with `postings_source_id_fkey` violated
— `postings.source_id` has a foreign-key constraint against `sources(id)`, which WF-1's ATS boards satisfy
by registering a real row per company first (`Sync Sources`), but WF-1c has no per-company `sources` row
for a Tier D collector. Fixed by setting `source_id: null` and relying on the existing, unconstrained
`source` text column (already how WF-1 labels `greenhouse`/`lever`/`ashby`) to carry `cutshort`/`hirist`
instead.

**Why.** Verified for real, end to end, after the fix: 30 real candidates (capped), 29 passed LLM
validation (1 correctly rejected as not a genuine posting), all 29 landed in `postings`, all handed to
WF-2 for real scoring. Real score distribution (5-92) split exactly as intended — genuine matches like
"Backend Engineering Intern" at Springer Capital (92) and "AI/ML Trainee — Generative AI" at WINIT (92)
scored high with sensible reasoning; noise let through by the loose slug prefilter (a "Junior Accounts
Executive," a "Jr. Facade Designer," a "Fashion Consultant") correctly scored 5-15, WF-2's real prefilter
and LLM scoring doing exactly the relevance job the slug filter was never meant to do. 6 postings crossed
`notify.min_score`; all 6 real Discord alerts confirmed landed by the owner.

**Consequences.** WF-1c left `active: false`, same standing policy as WF-1 and WF-1d — starts real daily
external traffic to Cutshort and Hirist once switched on. The 30 collected postings, their real evaluations,
and the 6 real notifications from this test are genuine product output, not test artifacts, and were kept
(matching how WF-1's and WF-1d's own real test data was handled). Worth revisiting later: the current
`.slice(0, 30)` cap takes candidates in whatever order the two sitemaps were merged (Cutshort first), so a
single run can end up entirely Cutshort with zero Hirist representation, as happened on this first run —
not a bug, just worth balancing (e.g. interleaving) once real daily volume after prefiltering is better
understood.

---

## 2026-08-14 — WF-1b collect-aggregators built and verified live against real SerpApi

**Context.** JSearch has no credential in the n8n store yet (blocked on the user), so only SerpApi's
`google_jobs` engine could be built and tested for real. Rather than guess JSearch's response shape to
"complete" the workflow, its branch was scaffolded (config-gated, `enabled: false` in `sources.json`) but
left genuinely unimplemented — repeating the mistake this project has avoided everywhere else (guessing an
API shape instead of observing one) isn't worth it just to look more finished.

**Two real n8n mechanics found while wiring the first credential-authenticated HTTP node this project has
used** (every prior HTTP call hit an unauthenticated public endpoint):
1. n8n's `httpQueryAuth` generic credential type has exactly two fields, "Name" and "Value" — and per its
   own source (`HttpQueryAuth.credentials.js`), the "Name" field's *value* is used directly as the query
   parameter key sent to the API (`requestOptions.qs[httpQueryAuth.name] = httpQueryAuth.value`). It is
   **not** a separate display label distinct from a "parameter name" field — there is no such field. The
   owner had (reasonably) entered a human-readable label ("SerpAPI query auth") there per my own earlier
   instruction, which silently sent `?SerpAPI query auth=<key>` instead of `?api_key=<key>`, producing a
   real "Invalid API key" 401 that had nothing to do with the key itself. Fixed by renaming that field to
   literally `api_key`.
2. SerpApi's `google_jobs` engine has a **documented, real** max response time of ~90 seconds (SerpApi's
   own published benchmark: avg 15s, max 90.782s across 106 requests) — far outside what a first-guess
   HTTP timeout (15s, then 45s) would tolerate. Confirmed via `wget` from inside the container that a
   fast, correct 401 came back instantly for an invalid key on the same endpoint, ruling out a genuine
   network/connectivity problem before raising the timeout to 100s and getting a real 200 with real data.

**Real response shape, observed live (not assumed):** `jobs_results[]`, each with `company_name`, `title`,
`location`, `source_link` (the real apply URL — more reliable than `share_link`, a Google-internal
tracking redirect), `description`, and `detected_extensions: {posted_at, schedule_type}` (structured, e.g.
`"Full–time"` — note the en-dash, not a hyphen, so substring matching rather than exact comparison is
used for `employment_type` mapping).

**Quota.** `api_quota` keyed by `(provider, period_month)`, checked before spending via the same
guaranteed-row LEFT JOIN pattern as WF-L0's `Get Cached`. Config's `monthly_limit` (currently 250 for
SerpApi, matching the vendor-doc figure already in `sources.json`) is the source of truth; `api_quota.used`
just tracks consumption against it. Query count is capped by `remaining` before any call is made, not
after, so a run can never overspend even if it dies partway through.

**Consequences.** Verified live: 7 real `google_jobs` queries, 30 real postings landed, all correctly
deduplicated and scored, 2 real Discord alerts confirmed by the owner. `config/sources.json`'s `serpapi`
entry flipped to `enabled: true` and pushed — this is a real, functioning Tier C source now, not a stub.
JSearch stays `enabled: false` until its credential exists and its real response shape has actually been
observed.

---

## 2026-08-14 — X/Twitter: direct access is blocked twice over; Google-indexed tweets via SerpApi work

**Context.** Owner asked to integrate X/Twitter as a source immediately after the WF-1b build above.
Checked it the same way as the earlier four candidates before concluding anything.

**Decision.** Direct access to X is not viable, for two independent reasons: `robots.txt` carries a
blanket `Disallow: /` under `User-agent: *` (only Googlebot/Bingbot/facebookexternalhit are named, and
even they're restricted to narrow paths — there's no carve-out analogous to Cutshort's open `/job/` path);
and the official X API dropped its free tier entirely in February 2026 (pay-per-use, $0.005/read, no free
allowance for new developers), which would violate the project's own $0/month goal (P4) as an ongoing cost,
not a one-time signup. The owner asked to find a free path anyway rather than accept a paid API.

**What actually works: querying Google itself, not X.** Googlebot is one of the few crawlers X's
`robots.txt` grants any access to, so a `site:x.com "hiring" ...`-style query through SerpApi's plain
`google` engine (not `google_jobs`, which has no site-filter at all — see the earlier rejected-sources
entry) returns real organic search results whose snippets already contain enough hiring-post text to
extract a posting from, with zero requests ever sent to x.com/twitter.com. This is the same category of
solution as Cutshort/Hirist: not scraping the blocked site, just reading what a fully compliant, licensed
third party (Google, via SerpApi) already surfaced publicly. Verified with a real call before building
anything: real hiring tweets came back (e.g. "Intuit is hiring a Software Engineer intern... Salary:
₹50,000/month"), filtered to individual `/status/<id>` tweet links only — account/profile-page results
(e.g. an aggregator account's bio mashing multiple openings into one snippet) aren't reliably extractable
as a single posting and are dropped.

**Quota is shared, not separate.** X-search draws from the *same* `serpapi` provider's 250/month budget as
`google_jobs`, since it's the same underlying account and key — modeling it as an independent quota bucket
would have let combined usage silently exceed the real cap. With `google_jobs` already at ~7 queries/day
(~210/month), there's only ~40/month of headroom, so X-search runs **weekly, not daily** (a handful of
queries, gated on `new Date().getUTCDay() === 0`), keeping combined usage safely under 250. Unlike
`jobs_results`, organic search snippets are unstructured prose, so extraction goes through Anthropic Haiku
(same pattern as WF-1c) rather than being parsed directly.

**A real bug found on first test:** the new `x_search_queries` config field never reached the query
builder — `Combine Configs` forwarded only `{aggregators, queries}`, silently dropping the new field
before it ever got read downstream. Not a timing or caching issue (checked and ruled out `config_cache`
staleness first) — just a field that was added to the config schema but never added to the one node that
was supposed to forward it. Fixed by adding `x_search_queries` to `Combine Configs`'s output. A day-of-week
gate this specific (`getUTCDay() === 0`) also can't be verified on its normal schedule without waiting a
full week, so it was tested with a temporary forced-on override on a real execution, confirmed working,
then reverted — the override was never committed.

**Consequences.** Verified live, end to end, after the fix: 12 real SerpApi calls (7 job + 5 X-search), 22
real X-sourced postings extracted and landed in `postings`, 8 crossed the notify threshold, all 8 real
Discord alerts confirmed by the owner. `source = 'serpapi_x'` distinguishes these from `google_jobs`-
sourced postings (`source = 'serpapi'`) in case the two ever need different handling later.

---

## 2026-08-14 — Score contract extended with `ctc_or_stipend`, same verbatim-only pattern as before

**Context.** Owner asked for CTC/stipend in the Discord message, mid-session, right after WF-1b/X-Twitter
landed. Same category of request as the earlier `deadline`/`eligibility` addition (Phase 2) — bolt onto
the existing scoring call rather than a separate pass, since the full posting text is already in front of
the LLM.

**Decision.** Added `ctc_or_stipend` to the JSON contract (nullable string, `prompts/v1.md`,
`evaluations.ctc_or_stipend`), extracted **verbatim, never inferred** — same constraint as `deadline`/
`eligibility`, for the same reason: an invented figure is actively worse than "Not stated." Threaded
through every node that already carries `deadline`/`eligibility` (`Check Cache`, both `Validate Attempt`
nodes, `Finalize From Attempt 1`, `Use Cached Evaluation`, `Persist Evaluation`, `Decide Notify`, WF-3's
`Prepare Notification`/`Insert Notification`/`Build Embed`) — identical shape, identical pattern, no new
mechanism needed.

**Why.** Verified extraction with two real Anthropic calls against already-collected real postings with
stipend text in their description: "Salary: 25k - 40k / month" → `"₹25,000–₹40,000/month"`, and "Expected
Stipend: 2-3 LPA" → `"2-3 LPA"` (passed through verbatim where the source was already a clean figure).
Neither test posting happened to cross the notify threshold (72 and 35), so the Discord embed's new
`**CTC/Stipend:**` line wasn't independently re-confirmed against a live send this session — it uses the
exact code pattern already visually confirmed for `deadline`/`eligibility` in Phase 2, so risk is low, but
this is recorded as a known gap rather than silently claimed as fully verified.

**Consequences.** Bumps `prompt_version` again (template text changed) — by design, same as every prior
contract change: old cached scores are correctly treated as stale. `db/schema.sql` gained a nullable
`ctc_or_stipend TEXT` column, applied live via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`.

---

## 2026-08-14 — Keka/Darwinbox/Zoho Recruit: none offer a Greenhouse-style public Tier A API

**Context.** Last Phase 4 TODO item: probe these three ATS platforms for a public, tokenless per-company
job API analogous to Greenhouse/Lever/Ashby/Workable/SmartRecruiters/Recruitee — the pattern WF-1's whole
Tier A design is built on.

**Decision.** None of the three offer it.
- **Darwinbox** — its own API documentation states outright that access is "privileged users only,
  request-only basis." No public, cross-tenant endpoint exists at all.
- **Zoho Recruit** — its own documentation confirms every API endpoint is scoped to the OAuth client's own
  organization; there is no public cross-tenant endpoint, which is explicitly why third-party aggregators
  consume the public career page HTML instead.
- **Keka** — the only one of the three with a real, promising, `robots.txt`-permitted public per-company
  career page (`{company}.keka.com/careers/`, e.g. `oneplus.keka.com` — confirmed via `robots.txt`, which
  explicitly *allows* `/careers` while blocking the rest of the subdomain, and confirmed via real examples:
  Fynd, Adda247, OnePlus, SmartDocs all host their hiring on Keka this way). But the page is a JS SPA, and
  the real job-listing API call was not locatable via static analysis of the loaded bundle — only a
  per-job application-uniqueness-check endpoint (`/api/jobs/{id}/isemailunique`) was found, not a listing
  endpoint. Finding the real one would need live browser DevTools network inspection, not available here.

**Why.** This isn't a gap in effort — all three were genuinely checked (their own docs for Darwinbox/Zoho,
real `robots.txt` + real customer examples + bundle analysis for Keka) before concluding. It matches a
pattern already seen twice this session (Cutshort, Hirist): most ATS/job platforms outside the
Greenhouse/Lever/Ashby-style "big few" simply don't expose an open, per-company API the way those do —
when they're reachable at all, it's via their rendered career page, not a documented public endpoint.

**Consequences.** Keka companies remain a real, viable *future* Tier D target (same career-page-fetch +
LLM-extraction pattern as WF-1c) once the actual listing endpoint is found or a browser-based inspection
happens — just not a Tier A (WF-1-style token-probe) one. Darwinbox and Zoho Recruit customers would need
the same Tier D treatment; neither was prioritized this session given WF-1c already covers two real
sources and Phase 4's remaining budget went to the free-tier usage projection instead.

---

## 2026-08-14 — Free-tier usage projection, using real observed data instead of vendor-doc guesses

**Context.** Last remaining Phase 4 item. With WF-1b/WF-1c/WF-1d now built and genuinely exercised this
session, real cost/volume numbers exist for the first time — this projection uses those instead of the
vendor-doc placeholders `sources.json` has carried since Phase 0.

**Real, observed numbers this session:** 334 real Anthropic evaluations, average **$0.00285/posting
scored** (Haiku pricing: $1/1M input + $5/1M output tokens), ~$1.04 total spend across all testing. SerpApi
quota at 26/250 used this session (inflated by repeated test runs, not representative of steady-state
daily usage).

**Decision — SerpApi (shared `serpapi` bucket, 250/month cap).** By design: 7 `google_jobs` queries/day
× 30 ≈ 210/month, plus 5 `x_search` queries/week × ~4.3 weeks ≈ 21.5/month = **~231.5/month, ~93% of the
250 cap.** Tight but under — there is very little headroom left in this budget. Any future addition to
either query list needs to come out of this same shared total, not be added on top of it.

**Decision — Anthropic (not quota-capped, real ongoing $ cost).** Using the real observed $0.00285/
evaluation: at a conservative 30-60 genuinely-new postings/day once the system settles past its inflated
first-run volume (day one scored far more than a steady state would, since every existing posting counted
as "new"), projected cost is **roughly $2.60–$5.15/month** — small, and explicitly outside the $0/month
goal already (P4 excludes LLM tokens by design). This is the only meaningfully uncertain number here: it
depends on real steady-state volume across WF-1/WF-1b/WF-1c combined, which isn't known until they've
actually run unattended for a real stretch, not just test executions.

**Decision — everything else.** Greenhouse/Lever/Ashby (WF-1's Tier A boards) are genuinely free, public,
unauthenticated APIs with no quota concept at all — polite rate-limiting (already built) is the only
constraint, not a spend cap. JSearch, Adzuna, Jooble, Careerjet remain unverified — no credential exists
for any of them yet (JSearch scaffolded but disabled; the other three are still pending account signups,
per CLAUDE.md's "Blocked on the user"), so their real free-tier limits are still the original vendor-doc
placeholders from Phase 0, not measured.

**Consequences.** `sources.json`'s `monthly_limit` figures for `serpapi` (250) are now confirmed accurate
by real usage, not just vendor docs. The other three aggregators' limits stay flagged as unverified until
those accounts exist. Given SerpApi is already near its cap, any decision to activate WF-1b for real,
continuous daily operation should account for the fact that there's little room to add more queries later
without either dropping some existing ones or accepting occasional skipped days near month-end.

---

## 2026-08-15 — Adzuna declined by the user; 2 of 3 WF-1d discoveries promoted; credential mechanics for JSearch/Careerjet

**Context.** Follow-up on the standing "blocked on the user" list. The user declined to sign up for Adzuna
("seems very fishy") and asked how to actually enter the RapidAPI/JSearch and Careerjet credentials once
those accounts exist, plus asked what "promoting" WF-1d's discoveries and "approving a starter company
list" actually mean.

**Decision — Adzuna.** Not pursued. The user's call, not a technical finding — recorded here per the
project's standing rule that decisions to reject something go in this file too. SerpApi already covers a
meaningful chunk of the same aggregator ground (`google_jobs` indexes Naukri/LinkedIn/Indeed/Instahyre),
so this isn't a coverage gap worth pushing back on.

**Decision — starter company list.** Treated as already effectively satisfied rather than a still-open
item: Phase 0's real, live-probed 15 sources (PhonePe, Groww, Postman, Stripe, Databricks, etc.) already
serve the same function a formal "propose 30, get approval" step would have — they were seeded because
they demonstrably worked, not because they were pre-approved from a list. No further action unless the
user wants a larger, more deliberate list proposed separately.

**Decision — WF-1d promotion, 2 of 3.** Promoted Bolna AI (Ashby) and Razorpay (Greenhouse) from
`discovered_sources` into `sources.json`'s real `ats` array — both providers WF-1's `By Provider` switch
already handles. **Weekday (Workable) was not promoted** — WF-1 has no Workable case in that switch, and
its `fallbackOutput: -1` isn't wired to anything, so an unmatched provider silently vanishes rather than
erroring. Adding Weekday as-is would have registered a real `sources` row that never actually gets fetched,
which the zero-result alarm built in Phase 3 would eventually and *correctly* flag as consecutive zeros —
a real, misleading alarm for a source that isn't actually broken, just unsupported. Left for the user to
decide whether extending WF-1 with a fourth (Workable) branch is worth it for one company.

**Decision — JSearch/Careerjet credential mechanics, verified against this n8n instance's own source
rather than guessed** (matching the SerpApi credential lesson from earlier this session — get burned once,
verify from then on). JSearch needs two headers (`X-RapidAPI-Key`, `X-RapidAPI-Host`); n8n's `HttpHeaderAuth`
credential type only has one Name/Value pair and its own UI explicitly says to use "Custom Auth" for
multi-header cases. `HttpCustomAuth` takes a single JSON field shaping `{headers, body, qs}` together —
confirmed via its own credential class source, not assumed. Careerjet's current (v4) API uses HTTP Basic
Auth (API key as username, empty password) per its own docs, which maps directly to n8n's standard
`httpBasicAuth` credential type — no custom JSON needed there.

**Consequences.** `sources.json` now has 17 real ATS entries (was 15). JSearch and Careerjet stay
unconfigured until the user creates the underlying accounts and enters credentials using the steps above;
WF-1b's JSearch branch remains deliberately unimplemented until then (see the earlier WF-1b entry — still
true, still the right call).

---

## 2026-08-15 — JSearch built and verified live: wrong credential type given first, real endpoint is /search-v2

**Context.** With credentials now in place, built out WF-1b's previously-scaffolded, deliberately-inert
JSearch branch for real.

**Decision — credential type, corrected.** Initially instructed the user to create a **Custom Auth**
credential (needed since JSearch requires two headers, `X-RapidAPI-Key` and `X-RapidAPI-Host`, and n8n's
simple `httpHeaderAuth` only holds one). Wrong: n8n's HTTP Request node **V1** — the only version this
entire project uses, for consistency — doesn't support Custom Auth at all; checked its source directly and
the `authentication` parameter only accepts `basicAuth`/`digestAuth`/`headerAuth`/`queryAuth`/`oAuth1`/
`oAuth2`. Custom Auth is a V2+-only feature. Corrected by checking whether a static header (the non-secret
`X-RapidAPI-Host`, always `jsearch.p.rapidapi.com`) and a credential-injected header (the secret
`X-RapidAPI-Key`, via ordinary `httpHeaderAuth`) can coexist on one V1 request — confirmed from source
that `headerParametersJson` and `httpHeaderAuth` both write into the same `requestOptions.headers` object
additively, not exclusively. No Custom Auth needed at all; a second, ordinary Header Auth credential does
the whole job.

**Decision — real endpoint, found by direct comparison against the user's own account.** The commonly-
documented `/search` path returned "Endpoint '/search' does not exist" — a RapidAPI **gateway**-level
error (`x-rapidapi-proxy-response: true` in the response headers), meaning the request never reached
JSearch's backend at all, independent of whether the key was valid. Spent several rounds ruling out the
key (re-copied, still failed identically) and confirming the subscription was active (RapidAPI's own
in-browser "Test Endpoint" succeeded) before asking the user to paste the *specific* endpoint's own code
snippet from RapidAPI's sidebar — which uses `/search-v2`, not `/search`. The commonly-cited `/search` path
is apparently deprecated or account-specific; `/search-v2` is the real, current one for this key. Real
response shape confirmed live: `data.jobs[]` (not `data[]` directly), with a genuinely clean ISO
`job_posted_at_datetime_utc` (no relative-date parsing needed, unlike SerpApi's `google_jobs`) and a real
direct `job_apply_link` (not a redirect, unlike SerpApi's `share_link`).

**Why the credential-type mistake matters.** This is the third time this session a wrong n8n credential
type was handed out before being corrected against real behavior (SerpApi's original `serpApi` type, then
its Query Auth "Name" field, now this). Standing rule going forward: **before instructing the user to
create any n8n credential type, check that type's actual source/behavior against the specific node
`typeVersion` actually in use** — a credential type that exists in principle may not be usable by the
particular node version this project has standardized on.

**Consequences.** Verified live, end to end: 7 real JSearch queries, real postings landed (`source =
'jsearch'`), quota correctly tracked in the same shared `api_quota` mechanism (own separate 200/month cap,
not shared with SerpApi's 250) — a combined WF-1b run this test produced 101 fetched / 55 new postings
across both providers, 5 real Discord alerts confirmed by the owner (2 traceable to JSearch specifically).
`sources.json`'s `jsearch` entry flipped to `enabled: true` and pushed, with a note recording the real
endpoint path so it's never re-guessed as `/search` again.
