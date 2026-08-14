# AGENTS.md — pangolin api-tools

Thin `pango` CLI (bash + curl + jq, zero other deps) over the self-hosted Pangolin
Integration API (org `aldervall`, instance `pangolin.aldervall.se`). This is the
tooling half of the `pangolin-knowledge` plan; sibling sources of truth:

- `~/.omo/plans/pangolin-knowledge.md` — the work plan (todos, acceptance criteria)
- `~/.omo/research/pangolin-api-catalog.md` — endpoint catalog parsed from the OpenAPI spec; the authoritative source for paths/bodies
- `~/.omo/drafts/pangolin-knowledge.md` — knowledge base + "Home services playbook" (curl sequences)

## Hard constraints

- **The live Integration API is DISABLED.** `api.pangolin.aldervall.se` serves a Traefik default cert and `/v1/*` is 404 on the main host (evidence: `evidence/todo2-*.md`). Live calls will fail — this is a server-side config issue, NOT a code bug. The user must enable it per `evidence/todo2-enable-integration-api-checklist.md` (config.yml `enable_integration_api: true`, Traefik `int-api-router`, restart) and supply an org-scoped key. Until then, do all work in `--mock` mode; do not burn time debugging live failures.
- **Never touch the Pangolin server**: no SSH, no pangctl, no config.yml edits from this repo. Server-side steps are user steps only.
- **`~/.pangolin/pangolin.json` holds live credentials** — read-only reference only; never copy, echo, or commit its contents.
- **`PANGOLIN_API_KEY` is required even for `--mock`** (any non-empty value passes mock auth; missing key → `error: set PANGOLIN_API_KEY` + exit 1). Config via env or repo-root `.env` (see `.env.example`); defaults: endpoint `https://api.pangolin.aldervall.se`, org `aldervall`, page size 1000.

## Commands

`./bin/pango [--mock] [--dry-run] <cmd>` — full usage in `pango help`.

- `list sites|resources|domains|clients|users|roles` — paginated via `limit`/`offset` until `pagination.total` is consumed; `list targets` REQUIRES `--resource-id N`
- `create-site <name>` (`--type newt|wireguard|local`, default newt; `--from-defaults` calls `pick-site-defaults` first)
- `create-resource <name>` — REQUIRES `--domain-id`; `--mode http|ssh|rdp|vnc|tcp|udp`
- `add-target <rid>` — REQUIRES `--site-id` (numeric), `--ip`, `--port` (numeric)
- `assign <rid>` — exactly one of `--role` (numeric) or `--user`
- `apply-blueprint <file|base64>` — file gets base64-encoded
- `apply-services [services.yaml]` — see below

Exit codes: 1 = API/env error, 2 = usage error. `--dry-run` prints the exact curl
with the key redacted and exits 0 without executing.

## apply-services semantics (idempotent by `full-domain`)

- Matches existing resources by `fullDomain`; if present → reconcile targets only (add missing, **never duplicate**); if absent → create resource then add targets. There is NO target-update endpoint — dedupe is by `siteId + ip + port`.
- Auto-resolves `domain-id` by `baseDomain` suffix (wildcard-type domain preferred) and target `site` by site NAME; unknown site → that service FAILs but others still process; exits 1 if any service failed.
- Pre-validates all targets BEFORE any writes (avoids orphan resources on unknown site names).
- `services.yaml` schema is documented in `services.yaml.example`: `name`, `full-domain`, `subdomain` (derived if omitted), `domain-id` (auto if omitted), `mode`, `targets[].site/hostname/port/method`, `auth.sso-enabled`, `healthcheck`. NOTE: `apply-healthchecks` (referenced in the example) is NOT implemented — it's plan Todo 9, live-gated.

## Mock harness (`mock-api.sh`)

- Canned state in `.mock-state.json` (git-ignored, persists creates → lets idempotency tests assert "no duplicates" via state counts).
- Any non-empty `PANGOLIN_API_KEY` passes auth; missing → 401 envelope. `PANGOLIN_MOCK_ERROR=1` → simulated 500. Unknown route → 404 envelope.
- Envelope shape everywhere: `{data, success, error, message, status}`; `error:true` or `status>=400` → surfaced to stderr + exit 1.

## Conventions & gotchas

- Commits are prefixed `api-tools:` (one atomic commit per command; later commits use `feat:`/`fix:` sub-prefixes). Live-response evidence goes under `evidence/` (git-ignored). `.env` is never committed.
- QA gates: `bash -n` on all scripts; shellcheck must be clean at `-S error` (SC2034 unused-var warnings were a real issue — see commit `caec39a`). shellcheck may not be installed on this machine.
- **jq gotcha (documented in the code, ~line 414)**: bind `.baseDomain as $b` BEFORE a pipe — jq evaluates a function-call argument in the context of the piped input (a string), so `.baseDomain` inside `endswith()` there indexes a string, fatal on jq >= 1.8. Preserve this pattern in new lookup code.
- YAML→JSON uses `yq` with python3+PyYAML fallback (`yaml_to_json`); either must exist for `apply-services`.
- `set -euo pipefail` is used throughout.

## Status (as of 2026-08-14)

Offline work done (Todos 1, 3–7): catalog, playbook, and the full CLI verified against the mock. Blocked on the user: Integration API enabled on the server (checklist in `evidence/`), org-scoped API key, and a filled `services.yaml` (only `.example` exists). Remaining: Todo 8 (live apply + verify), Todo 9 (health checks), F1–F4 final verification.
