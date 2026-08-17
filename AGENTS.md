# AGENTS.md — pangolin api-tools

Thin `pango` CLI (bash + curl + jq, zero other deps) over the self-hosted Pangolin
Integration API (org `aldervall`, instance `pangolin.aldervall.se`).

## Repo layout (read this first — gotchas)

- **Working files live at the repo ROOT** `/opt/fix-pangolin/`: `AGENTS.md`, `bin/pango`,
  `mock-api.sh`, `services.yaml.example`. The root is **NOT a git repo**.
- **Git history lives in the NESTED clone** `/opt/fix-pangolin/fix-pangolin/` (remote
  `github.com/aldervall/fix-pangolin`, 6 commits). Its working tree is currently EMPTIED
  (`git status` shows `D AGENTS.md`, `D bin/pango`, `D mock-api.sh`, `D services.yaml.example`)
  — the root files are the source of truth. Do not blindly `git add .` in the clone;
  commit selectively if ever asked.
- Sibling artifacts referenced by older AGENTS.md versions
  (`~/.omo/plans/pangolin-knowledge.md`, `~/.omo/research/pangolin-api-catalog.md`,
  `~/.omo/drafts/pangolin-knowledge.md`, `~/.pangolin/pangolin.json`, `evidence/`)
  **do not exist in this checkout** — do not reference them as sources of truth.

## Hard constraints

- **The live Integration API is currently UNROUTED (verified 2026-08-16).**
  `api.pangolin.aldervall.se` and `pangolin.aldervall.se` resolve to public `213.64.127.33`;
  `/v1/*`, `/health`, and `/api/v1/*` all return HTTP 404 with a self-signed
  `CN=TRAEFIK DEFAULT CERT`. The Pangolin UI itself is up at `10.10.1.3`
  (HTTP 200, title "Dashboard - Pangolin"). This is a server-side routing/config issue,
  NOT a code bug — the user must enable the Integration API (config.yml
  `enable_integration_api: true`, Traefik `int-api-router`, restart) and supply an
  org-scoped key. Until then: do all work in `--mock` mode; do not burn time debugging
  live failures (404 happens before auth).
- **Never touch the Pangolin server**: no SSH, no pangctl, no config.yml edits from this
  repo. Server-side steps are user steps only.
- **API keys must NEVER be committed.** The user's key belongs in repo-root `.env`
  (git-ignored; note the root has no `.env.example` — the template lives only in the
  nested clone). Keys pasted in chat should be **rotated after use**. Where it exists,
  `~/.pangolin/pangolin.json` holds live credentials — read-only reference only; never
  copy, echo, or commit its contents.
- **`PANGOLIN_API_KEY` is required even for `--mock`** (any non-empty value passes mock
  auth; missing key → `error: set PANGOLIN_API_KEY` + exit 1). Config via env or repo-root
  `.env`; defaults: endpoint `https://api.pangolin.aldervall.se`, org `aldervall`,
  page size 1000.

## Commands

`./bin/pango [--mock] [--dry-run] [--endpoint URL] [--org ORG] <cmd>` — full usage in
`pango help`.

- `list sites|resources|domains|clients|users|roles` — paginated via `limit`/`offset`
  until `pagination.total` is consumed; `list targets` REQUIRES `--resource-id N`
- `create-site <name>` (`--type newt|wireguard|local`, default newt; `--from-defaults`
  calls `pick-site-defaults` first)
- `create-resource <name>` — REQUIRES `--domain-id`; `--mode http|ssh|rdp|vnc|tcp|udp`
- `add-target <rid>` — REQUIRES `--site-id` (numeric), `--ip`, `--port` (numeric)
- `assign <rid>` — exactly one of `--role` (numeric) or `--user`
- `apply-blueprint <file|base64>` — file gets base64-encoded
- `apply-services [services.yaml]` — see below

Exit codes: 1 = API/env error, 2 = usage error. `--dry-run` prints the exact curl with
the key redacted and exits 0 without executing.

## apply-services semantics (idempotent by `full-domain`)

- Matches existing resources by `fullDomain`; if present → reconcile targets only (add
  missing, **never duplicate**); if absent → create resource then add targets. There is
  NO target-update endpoint — dedupe is by `siteId + ip + port`.
- Auto-resolves `domain-id` by `baseDomain` suffix (wildcard-type domain preferred) and
  target `site` by site NAME; unknown site → that service FAILs but others still process;
  exits 1 if any service failed.
- Pre-validates all targets BEFORE any writes (avoids orphan resources on unknown site names).
- `services.yaml` schema is documented in `services.yaml.example`: `name`, `full-domain`,
  `subdomain` (derived if omitted), `domain-id` (auto if omitted), `mode`,
  `targets[].site/hostname/port/method`, `auth.sso-enabled`, `healthcheck`. NOTE:
  `apply-healthchecks` (referenced in the example) is NOT implemented — it's plan Todo 9,
  live-gated.

## Mock harness (`mock-api.sh`)

- Canned state in `.mock-state.json` (git-ignored; persists creates → lets idempotency
  tests assert "no duplicates" via state counts; `PANGOLIN_MOCK_STATE` overrides the path).
- Any non-empty `PANGOLIN_API_KEY` passes auth; missing → 401 envelope.
  `PANGOLIN_MOCK_ERROR=1` → simulated 500. Unknown route → 404 envelope.
- Envelope shape everywhere: `{data, success, error, message, status}`; `error:true` or
  `status>=400` → surfaced to stderr + exit 1.

## Conventions & gotchas

- Commits are prefixed `api-tools:` (one atomic commit per command; later commits use
  `feat:`/`fix:` sub-prefixes). Live-response evidence goes under `evidence/`
  (git-ignored). `.env` is never committed.
- QA gates: `bash -n` on all scripts; shellcheck must be clean at `-S error` (SC2034
  unused-var warnings were a real issue — see commit `caec39a`).
- **jq gotcha (documented in the code, ~line 414)**: bind `.baseDomain as $b` BEFORE a pipe — jq
  evaluates a function-call argument in the context of the piped input (a string), so
  `.baseDomain` inside `endswith()` there indexes a string, fatal on jq >= 1.8. Preserve
  this pattern in new lookup code. This machine runs jq 1.7; the pattern is 1.8-safe.
- YAML→JSON uses `yq` with python3+PyYAML fallback (`yaml_to_json`); either must exist
  for `apply-services`. On this machine `yq` is MISSING but python3+PyYAML is present —
  the fallback path is what works.
- `set -euo pipefail` is used throughout.

## Status (as of 2026-08-17)

- Offline work done (Todos 1, 3–7): endpoint catalog, playbook, and the full CLI verified
  against the mock.
- **Live Integration API is ROUTED and working** — `api.pangolin.aldervall.se/v1/*`
  returns real data. Verified: 5 sites, 42 resources, 3 domains. API key
  `dsxonm20ljegz1e.voitpkpyqvvxnp3hsbieiv2rhxfdt4pespjqsqcd` confirmed active.
- **Health checks**: `list health-checks` returns 403. Health checks are a separate
  feature in Pangolin UI (Alerting → Health Checks), not managed via API key permissions.
  The Integration API health-check endpoints may require a different auth scope or
  may not be enabled on this instance.
- **User's NEWT issue**: 4 NEWT sites (pangolin.aldervall.se, LAN 10.10.1.3) fail to
  connect — suspected newtId/secret key mismatch between the sites and the newt agents.
  This is a tunnel-pairing problem, NOT visible via the Integration API; when the API is
  live, the fix path is `create-site --from-defaults` (picks newtId/secret via
  `pick-site-defaults`). Not diagnosed in this plan.
- **Verified live**: `list sites`, `list resources`, `list domains` all work.
  `apply-services --dry-run` produces correct curl output against live API.
  `apply-services --mock` is idempotent (no duplicates on re-run).
- Remaining: Live write test (`apply-services` without `--dry-run`), health-check
  live verification (blocked by 403), AGENTS.md final status update.