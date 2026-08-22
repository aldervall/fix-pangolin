# AGENTS.md — pangolin api-tools

Thin `pango` CLI (bash + curl + jq, zero other deps) over the self-hosted Pangolin
Integration API (org `aldervall`, instance `pangolin.aldervall.se`).

## Repo layout

- **Working files live at the repo ROOT** `/opt/fix-pangolin/`: `AGENTS.md`, `bin/pango`,
  `mock-api.sh`, `services.yaml.example`, `.env`. The root is **NOT a git repo**.
- **Git history lives in the NESTED clone** `/opt/fix-pangolin/fix-pangolin/` (remote
  `github.com/aldervall/fix-pangolin`, 7 commits). The working tree mirrors the root —
  both have identical files. If ever asked to commit, work in the nested clone; do NOT
  `git add .` blindly (`.env` must stay untracked).
- `.omo/` contains plan artifacts and evidence from prior sessions — reference only,
  not source of truth.

## Hard constraints

- **Never touch the Pangolin server**: no SSH, no pangctl, no config.yml edits from this
  repo. Server-side steps are user steps only.
- **API keys must NEVER be committed.** The user's key belongs in repo-root `.env`
  (git-ignored; template at `fix-pangolin/.env.example`). Keys pasted in chat should be
  **rotated after use**. Never copy, echo, or commit key values.
- **`PANGOLIN_API_KEY` is required even for `--mock`** (any non-empty value passes mock
  auth; missing key → `error: set PANGOLIN_API_KEY` + exit 1). Config via env or repo-root
  `.env`; defaults: endpoint `https://api.pangolin.aldervall.se`, org `aldervall`,
  page size 1000.

## Commands

`./bin/pango [--mock] [--dry-run] [--endpoint URL] [--org ORG] <cmd>` — full usage in
`pango help`.

**Reads:**
- `list sites|resources|domains|clients|users|roles` — paginated via `limit`/`offset`
  until `pagination.total` is consumed; `list targets` REQUIRES `--resource-id N`
- `list health-checks` — lists health checks for the org

**Writes:**
- `create-site <name>` (`--type newt|wireguard|local`, default newt; `--from-defaults`
  calls `pick-site-defaults` first)
- `create-resource <name>` — REQUIRES `--domain-id`; `--mode http|ssh|rdp|vnc|tcp|udp`
- `add-target <rid>` — REQUIRES `--site-id` (numeric), `--ip`, `--port` (numeric)
- `assign <rid>` — exactly one of `--role` (numeric) or `--user`
- `apply-blueprint <file|base64>` — file gets base64-encoded

**Bulk ops:**
- `apply-services [services.yaml]` — idempotent by full-domain (see below)
- `apply-healthchecks [services.yaml]` — idempotent upsert of health checks (see below)

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
- `services.yaml` schema documented in `services.yaml.example`: `name`, `full-domain`,
  `subdomain` (derived if omitted), `domain-id` (auto if omitted), `mode`,
  `targets[].site/hostname/port/method`, `auth.sso-enabled`, `healthcheck`.

## apply-healthchecks semantics (idempotent by name)

- For each service with a `healthcheck` block in `services.yaml`:
  1. Resolves `resourceId` by `fullDomain` from existing resources
  2. Resolves `siteId` from the first target's site NAME
  3. Lists existing health checks, matches by `name`
  4. If found → PUT update; if not → PUT create
- Body: `name`, `siteId`, `hcEnabled:true`, `hcMode:"http"`, `hcHostname`, `hcPort`,
  `hcPath:"/"`, `hcScheme:"http"`, `hcMethod:"GET"`, `hcInterval` (default 30),
  `hcTimeout` (default 1), `hcUnhealthyThreshold` (default 1)
- Services with no targets or unknown site names are SKIPed (never fail the whole run).

## Mock harness (`mock-api.sh`)

- Canned state in `.mock-state.json` (git-ignored; persists creates → lets idempotency
  tests assert "no duplicates" via state counts; `PANGOLIN_MOCK_STATE` overrides the path).
- Any non-empty `PANGOLIN_API_KEY` passes auth; missing → 401 envelope.
  `PANGOLIN_MOCK_ERROR=1` → simulated 500. Unknown route → 404 envelope.
- Envelope shape everywhere: `{data, success, error, message, status}`; `error:true` or
  `status>=400` → surfaced to stderr + exit 1.

**Mock routes:**
| Method | Path | Handler |
|--------|------|---------|
| GET | `/org/{org}/sites` | list_entities |
| GET | `/org/{org}/resources` | list_entities |
| GET | `/org/{org}/domains` | list_entities |
| GET | `/org/{org}/clients` | list_entities |
| GET | `/org/{org}/users` | list_entities |
| GET | `/org/{org}/roles` | list_entities |
| GET | `/resource/{id}/targets` | list_targets |
| GET | `/org/{org}/pick-site-defaults` | pick_site_defaults |
| PUT | `/org/{org}/site` | create_site |
| PUT | `/org/{org}/resource` | create_resource |
| PUT | `/resource/{id}/target` | create_target |
| POST | `/resource/{id}/roles/add` | add_role |
| POST | `/resource/{id}/users/add` | add_user |
| PUT | `/org/{org}/blueprint` | apply_blueprint |
| GET | `/org/{org}/health-checks` | list_health_checks |
| PUT | `/org/{org}/health-check` | create_health_check |
| POST | `/org/{org}/health-check/{id}` | update_health_check |
| DELETE | `/org/{org}/health-check/{id}` | delete_health_check |
| GET | `/org/{org}/health-check/{id}/status-history` | get_health_check_status_history |

## Conventions & gotchas

- QA gates: `bash -n` on all scripts; shellcheck must be clean at `-S error`.
- **jq gotcha (documented in the code, ~line 434)**: bind `.baseDomain as $b` BEFORE a
  pipe — jq evaluates a function-call argument in the context of the piped input (a
  string), so `.baseDomain` inside `endswith()` there indexes a string, fatal on
  jq >= 1.8. Preserve this pattern in new lookup code. This machine runs jq 1.7;
  the pattern is 1.8-safe.
- YAML→JSON uses `yq` with python3+PyYAML fallback (`yaml_to_json`); either must exist
  for `apply-services` and `apply-healthchecks`. On this machine `yq` is MISSING but
  python3+PyYAML is present — the fallback path is what works.
- `set -euo pipefail` is used throughout.
- `.env` is never committed. `.mock-state.json` is git-ignored.

## Live API status

The Integration API at `api.pangolin.aldervall.se` is routed and working.
Verified: `list sites`, `list resources`, `list domains` return real data.
`apply-services --dry-run` produces correct curl output against live API.
`apply-services --mock` is idempotent (no duplicates on re-run).

Health checks: `list health-checks` may return 403 depending on API key scope.
Health checks are a separate feature in Pangolin UI (Alerting → Health Checks).

## pangoclient — Client Reachability Tester

Thin `pangoclient` CLI (bash + curl + jq) over the Pangolin Integration API for testing
machine client reachability through WireGuard tunnels.

**`./bin/pangoclient [--mock] [--dry-run] [--timeout N] [--verbose] <cmd>`**

### Commands

**Reads:**
- `list clients|resources|domains` — formatted table (ID, NAME, SUBNET, ONLINE / DOMAIN, MODE / TYPE)
- `inspect <id|name>` — show client details by ID or name
- `help` — show usage with examples

**Writes:**
- `create <name>` — create a new machine client (generates olmId, secret, subnet)
- `delete <id|name>` — delete a client (best-effort; may not work on live API)

**Reachability Test:**
- `test <id|name>` — test resource reachability from a machine client's perspective
  - Creates temporary client, connects via WireGuard, probes resources, reports results
  - `--timeout N` sets probe timeout in seconds (default 5); `--verbose` shows progress

### Flags

- `--mock` — use the canned mock API (mock-api.sh)
- `--dry-run` — print the exact curl command, do not execute
- `--endpoint URL` — override PANGOLIN_API_ENDPOINT
- `--org ID` — override PANGOLIN_ORG_ID
- `--timeout N` — probe timeout in seconds (default 5)
- `--verbose` — show detailed progress output

### Prerequisites

- **pangolin CLI**: Required for live test mode. Install with:
  `curl -fsSL https://static.pangolin.net/get-cli.sh | bash`
- **WireGuard kernel module**: Required for tunnel establishment. Check with `lsmod | grep wireguard`.

### Notes

- Client delete is NOT in the Integration API. `delete` is best-effort.
- Secret is only known at creation time — `test` creates its own client.
- Follows same conventions as `pango`: bash + curl + jq, same `.env` auth.
- Exit codes: 1 = API/env error, 2 = usage error.
- `.mock-state.json` persists created clients across runs.

## User's NEWT issue (out of scope)

4 NEWT sites fail to connect — suspected newtId/secret key mismatch. This is a
tunnel-pairing problem, NOT visible via the Integration API. Fix path when API is
live: `create-site --from-defaults` (picks newtId/secret via `pick-site-defaults`).
