#!/usr/bin/env bash
# mock-api.sh — canned Pangolin Integration API mock for agent-executable QA.
#
# Usage:
#   PANGOLIN_API_KEY=<any-non-empty> mock-api.sh <METHOD> <PATH> [--body '<json>']
#
# Auth: any non-empty PANGOLIN_API_KEY passes; missing key -> 401 envelope.
# State: .mock-state.json (repo root, git-ignored) persists creates so that
#        idempotency tests (Todo 7) can assert "no duplicates" via state counts.
# Envelope shape (documented): { "data": ..., "success": bool, "error": bool,
#                                "message": string, "status": number }
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${PANGOLIN_MOCK_STATE:-$REPO_DIR/.mock-state.json}"

METHOD="${1:-}"
PATH_ARG="${2:-}"
BODY=""
if [[ "${3:-}" == "--body" && -n "${4:-}" ]]; then
  BODY="$4"
fi

# Split query string off the path (e.g. /org/x/sites?limit=100&offset=0)
QUERY=""
if [[ "$PATH_ARG" == *\?* ]]; then
  QUERY="${PATH_ARG#*\?}"
  PATH_ARG="${PATH_ARG%%\?*}"
fi

qparam() { # <name> <default> — read a query param from $QUERY
  local name="$1" default="$2" rest val
  rest="${QUERY#*"${name}="}"
  if [[ "$rest" != "$QUERY" ]]; then
    val="${rest%%&*}"
    [[ -n "$val" ]] && { echo "$val"; return; }
  fi
  echo "$default"
}

# --- envelope helpers ------------------------------------------------------
envelope() { # <data-json> <success> <error> <message> <status>
  jq -n --argjson data "$1" --argjson success "$2" --argjson error "$3" \
    --arg message "$4" --argjson status "$5" \
    '{data:$data, success:$success, error:$error, message:$message, status:$status}'
}

auth_ok() {
  [[ -n "${PANGOLIN_API_KEY:-}" ]]
}

ensure_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" <<'EOF'
{
  "sites": [
    {"siteId": 33, "name": "home-nuc", "type": "newt", "address": "100.90.128.2", "online": true},
    {"siteId": 8723, "name": "site-1", "type": "newt", "address": "100.90.128.0/24", "online": false}
  ],
  "domains": [
    {"domainId": "dg-aldervall", "baseDomain": "aldervall.se", "verified": true, "type": "ns"}
  ],
  "resources": [
    {"resourceId": 9943, "name": "Home Assistant", "subdomain": "hs", "fullDomain": "hs.aldervall.se", "domainId": "dg-aldervall", "mode": "http", "enabled": true},
    {"resourceId": 9944, "name": "Bitwarden", "subdomain": "bw", "fullDomain": "bw.aldervall.se", "domainId": "dg-aldervall", "mode": "http", "enabled": true}
  ],
  "targets": [
    {"targetId": 11280, "resourceId": 9943, "siteId": 33, "ip": "100.90.128.2", "port": 8123, "method": "http"},
    {"targetId": 11281, "resourceId": 9944, "siteId": 33, "ip": "100.90.128.2", "port": 8080, "method": "http"}
  ],
  "users": [
    {"userId": "8rtf9feccl9vli3", "email": "niklas@aldervall.se"},
    {"userId": "user2", "email": "user2@aldervall.se"}
  ],
  "roles": [
    {"roleId": 1, "name": "admin", "description": "Admin role"},
    {"roleId": 2, "name": "user", "description": "Default user role"}
  ],
  "clients": [
    {"clientId": 501, "name": "laptop", "online": true},
    {"clientId": 502, "name": "phone", "online": false}
  ],
  "healthchecks": [],
  "counters": {"siteId": 9000, "resourceId": 9000, "targetId": 9000, "healthCheckId": 9000}
}
EOF
  fi
}

next_id() { # <counter-key> — increments the counter in state, echoes the new value
  local key="$1" cur nxt
  cur="$(jq -r --arg k "$key" '.counters[$k] // 0' "$STATE_FILE")"
  nxt=$((cur + 1))
  jq --arg k "$key" --argjson n "$nxt" '.counters[$k] = $n' "$STATE_FILE" \
    > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  echo "$nxt"
}

save_state() { # <new-state-json>
  printf '%s\n' "$1" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# --- handlers ---------------------------------------------------------------
list_entities() { # <entity-key> <status-message>
  local key="$1" msg="$2" ps pg off data
  ps="$(qparam pageSize 0)"; [[ "$ps" == "0" ]] && ps="$(qparam limit 1000)"
  pg="$(qparam page 0)";     [[ "$pg" == "0" ]] && pg=1
  off="$(qparam offset 0)"
  # Convert limit/offset to pageSize/page for the jq slice
  if [[ "$off" -gt 0 ]]; then pg=$(( off / ps + 1 )); fi
  data="$(jq -c --arg key "$key" --argjson ps "$ps" --argjson pg "$pg" \
    '.[$key] as $all | {($key): $all[(($pg-1)*$ps):(($pg-1)*$ps + $ps)], pagination: {total: ($all | length), pageSize: $ps, page: $pg}}' \
    "$STATE_FILE")"
  envelope "$data" true false "$msg" 200
}

list_targets() { # GET /resource/{id}/targets — only targets of that resource
  local rid ps pg off data
  rid="$(sed -E 's#^/resource/([0-9]+)/targets$#\1#' <<<"$PATH_ARG")"
  ps="$(qparam pageSize 0)"; [[ "$ps" == "0" ]] && ps="$(qparam limit 1000)"
  pg="$(qparam page 0)";     [[ "$pg" == "0" ]] && pg=1
  off="$(qparam offset 0)"
  if [[ "$off" -gt 0 ]]; then pg=$(( off / ps + 1 )); fi
  data="$(jq -c --argjson rid "$rid" --argjson ps "$ps" --argjson pg "$pg" \
    '[.targets[] | select(.resourceId == $rid)] as $all |
     {targets: $all[(($pg-1)*$ps):(($pg-1)*$ps + $ps)],
      pagination: {total: ($all | length), pageSize: $ps, page: $pg}}' \
    "$STATE_FILE")"
  envelope "$data" true false "Targets retrieved successfully" 200
}

create_site() {
  local name type address newtId secret newid data
  name="$(jq -r '.name // empty' <<<"$BODY")"
  type="$(jq -r '.type // "newt"' <<<"$BODY")"
  [[ -n "$name" ]] || { envelope 'null' false true 'name is required' 400; exit 0; }
  newid="$(next_id siteId)"
  address="$(jq -r '.address // ""' <<<"$BODY")"
  newtId="$(jq -r '.newtId // ""' <<<"$BODY")"
  secret="$(jq -r '.secret // ""' <<<"$BODY")"
  local state
  state="$(jq --argjson id "$newid" --arg name "$name" --arg type "$type" \
    --arg addr "$address" --arg nt "$newtId" --arg sec "$secret" \
    '.sites += [{siteId:$id, name:$name, type:$type, address:$addr, newtId:$nt, secret:$sec, online:false}]' \
    "$STATE_FILE")"
  save_state "$state"
  data="$(jq -n --argjson id "$newid" --arg name "$name" --arg type "$type" \
    '{siteId:$id, name:$name, type:$type, online:false}')"
  envelope "$data" true false "Site created successfully" 201
}

create_resource() {
  local name domainId subdomain mode base full rid data
  name="$(jq -r '.name // empty' <<<"$BODY")"
  domainId="$(jq -r '.domainId // empty' <<<"$BODY")"
  subdomain="$(jq -r '.subdomain // ""' <<<"$BODY")"
  mode="$(jq -r 'if .mode then .mode else (if .http == true then "http" else (.protocol // "tcp") end) end' <<<"$BODY")"
  [[ -n "$name" ]] || { envelope 'null' false true 'name is required' 400; exit 0; }
  [[ -n "$domainId" ]] || { envelope 'null' false true 'domainId is required' 400; exit 0; }
  if ! jq -e --arg d "$domainId" '.domains[] | select(.domainId == $d)' "$STATE_FILE" >/dev/null 2>&1; then
    envelope 'null' false true "Domain not found: $domainId" 404; exit 0
  fi
  base="$(jq -r --arg d "$domainId" '.domains[] | select(.domainId == $d) | .baseDomain' "$STATE_FILE")"
  if [[ -n "$subdomain" ]]; then full="$subdomain.$base"; else full="$base"; fi
  rid="$(next_id resourceId)"
  local state
  state="$(jq --argjson id "$rid" --arg name "$name" --arg sub "$subdomain" \
    --arg full "$full" --arg dom "$domainId" --arg mode "$mode" \
    '.resources += [{resourceId:$id, name:$name, subdomain:$sub, fullDomain:$full, domainId:$dom, mode:$mode, enabled:true}]' \
    "$STATE_FILE")"
  save_state "$state"
  data="$(jq -n --argjson id "$rid" --arg name "$name" --arg sub "$subdomain" \
    --arg full "$full" --arg dom "$domainId" \
    '{resourceId:$id, name:$name, subdomain:$sub, fullDomain:$full, domainId:$dom}')"
  envelope "$data" true false "Http resource created successfully" 201
}

create_target() {
  local rid siteId ip port method tid data
  rid="$(sed -E 's#^/resource/([0-9]+)/target$#\1#' <<<"$PATH_ARG")"
  siteId="$(jq -r '.siteId // empty' <<<"$BODY")"
  ip="$(jq -r '.ip // empty' <<<"$BODY")"
  port="$(jq -r '.port // empty' <<<"$BODY")"
  method="$(jq -r '.method // "http"' <<<"$BODY")"
  [[ -n "$siteId" && -n "$ip" && -n "$port" ]] || {
    envelope 'null' false true 'siteId, ip and port are required' 400; exit 0; }
  if ! jq -e --argjson id "$rid" '.resources[] | select(.resourceId == $id)' "$STATE_FILE" >/dev/null 2>&1; then
    envelope 'null' false true "Resource not found: $rid" 404; exit 0
  fi
  if ! jq -e --argjson id "$siteId" '.sites[] | select(.siteId == $id)' "$STATE_FILE" >/dev/null 2>&1; then
    envelope 'null' false true "Site not found: $siteId" 404; exit 0
  fi
  tid="$(next_id targetId)"
  local state
  state="$(jq --argjson id "$tid" --argjson rid "$rid" --argjson sid "$siteId" \
    --arg ip "$ip" --argjson port "$port" --arg m "$method" \
    '.targets += [{targetId:$id, resourceId:$rid, siteId:$sid, ip:$ip, port:$port, method:$m}]' \
    "$STATE_FILE")"
  save_state "$state"
  data="$(jq -n --argjson id "$tid" --argjson rid "$rid" --argjson sid "$siteId" \
    --arg ip "$ip" --argjson port "$port" --arg m "$method" \
    '{targetId:$id, resourceId:$rid, siteId:$sid, ip:$ip, port:$port, method:$m}')"
  envelope "$data" true false "Target created successfully" 201
}

add_role() { # POST /resource/{id}/roles/add  {"roleId": N}
  local rid roleId
  rid="$(sed -E 's#^/resource/([0-9]+)/roles/add$#\1#' <<<"$PATH_ARG")"
  roleId="$(jq -r '.roleId // empty' <<<"$BODY")"
  [[ -n "$roleId" ]] || { envelope 'null' false true 'roleId is required' 400; exit 0; }
  envelope "$(jq -n --argjson roleId "$roleId" '{roleId:$roleId}')" true false "Role added successfully" 200
}

add_user() { # POST /resource/{id}/users/add  {"userId": "..."}
  local rid userId
  rid="$(sed -E 's#^/resource/([0-9]+)/users/add$#\1#' <<<"$PATH_ARG")"
  userId="$(jq -r '.userId // empty' <<<"$BODY")"
  [[ -n "$userId" ]] || { envelope 'null' false true 'userId is required' 400; exit 0; }
  envelope "$(jq -n --arg userId "$userId" '{userId:$userId}')" true false "User added successfully" 200
}

pick_site_defaults() {
  local data
  data="$(jq -n '{address:"100.90.128.0", newtId:"mock-newt-id", secret:"mock-secret"}')"
  envelope "$data" true false "Site defaults retrieved successfully" 200
}

apply_blueprint() {
  local blueprint
  blueprint="$(jq -r '.blueprint // empty' <<<"$BODY")"
  [[ -n "$blueprint" ]] || { envelope 'null' false true 'blueprint (base64 JSON) is required' 400; exit 0; }
  envelope 'null' true false "Blueprint applied successfully" 200
}

# --- healthcheck handlers -----------------------------------------------------
list_health_checks() { # GET /org/{orgId}/health-checks
  local ps pg off data
  ps="$(qparam pageSize 0)"; [[ "$ps" == "0" ]] && ps="$(qparam limit 1000)"
  pg="$(qparam page 0)";     [[ "$pg" == "0" ]] && pg=1
  off="$(qparam offset 0)"
  if [[ "$off" -gt 0 ]]; then pg=$(( off / ps + 1 )); fi
  data="$(jq -c --argjson ps "$ps" --argjson pg "$pg" \
    '.healthchecks as $all | {healthChecks: $all[(($pg-1)*$ps):(($pg-1)*$ps + $ps)], pagination: {total: ($all | length), pageSize: $ps, page: $pg}}' \
    "$STATE_FILE")"
  envelope "$data" true false "Health checks retrieved successfully" 200
}

create_health_check() {
  local body_valid name siteId data
  body_valid="$(jq 'if type == "object" and . != null then true else false end' <<<"$BODY" 2>/dev/null || true)"
  if [[ "$body_valid" != "true" ]]; then
    envelope 'null' false true 'body must be a valid JSON object' 400; exit 0
  fi
  name="$(jq -r '.name // empty' <<<"$BODY")"
  siteId="$(jq -r '.siteId // empty' <<<"$BODY")"
  [[ -n "$name" ]] || { envelope 'null' false true 'name is required' 400; exit 0; }
  [[ -n "$siteId" ]] || { envelope 'null' false true 'siteId is required' 400; exit 0; }
  if ! jq -e --argjson id "$siteId" '.sites[] | select(.siteId == $id)' "$STATE_FILE" >/dev/null 2>&1; then
    envelope 'null' false true "Site not found: $siteId" 404; exit 0
  fi
  local hcId
  hcId="$(next_id healthCheckId)"
  local state
  state="$(jq --argjson id "$hcId" --arg name "$name" --argjson siteId "$siteId" \
    '.healthchecks += [{healthCheckId:$id, name:$name, siteId:$siteId, hcEnabled:false, hcMode:"http", hcMethod:"GET", hcInterval:30, hcUnhealthyInterval:30, hcTimeout:1, hcFollowRedirects:true, hcHealthyThreshold:1, hcUnhealthyThreshold:1, hcHeaders:null, hcStatus:null}]' \
    "$STATE_FILE")"
  save_state "$state"
  data="$(jq -n --argjson id "$hcId" --arg name "$name" --argjson siteId "$siteId" \
    '{healthCheckId:$id, name:$name, siteId:$siteId, hcEnabled:false, hcMode:"http", hcMethod:"GET", hcInterval:30, hcUnhealthyInterval:30, hcTimeout:1, hcFollowRedirects:true, hcHealthyThreshold:1, hcUnhealthyThreshold:1, hcHeaders:null, hcStatus:null}')"
  envelope "$data" true false "Health check created successfully" 201
}

update_health_check() {
  local hcId body_valid data
  hcId="${PATH_ARG##*/health-check/}"
  hcId="${hcId%%/*}"
  if ! jq -e --argjson id "$hcId" '.healthchecks[] | select(.healthCheckId == $id)' "$STATE_FILE" >/dev/null 2>&1; then
    envelope 'null' false true "Health check not found: $hcId" 404; exit 0
  fi
  body_valid="$(jq 'if type == "object" and . != null then true else false end' <<<"$BODY")"
  if [[ "$body_valid" != "true" ]]; then
    envelope 'null' false true 'body must be a valid JSON object' 400; exit 0
  fi
  local state
  state="$(jq --argjson id "$hcId" --argjson body "$(jq 'del(.healthCheckId)' <<<"$BODY")" '.healthchecks |= map(if .healthCheckId == $id then ( . + $body ) else . end)' "$STATE_FILE")"
  save_state "$state"
  data="$(jq -c --argjson id "$hcId" '.healthchecks[] | select(.healthCheckId == $id)' "$STATE_FILE")"
  envelope "$data" true false "Health check updated successfully" 200
}

delete_health_check() {
  local hcId data
  hcId="${PATH_ARG##*/health-check/}"
  hcId="${hcId%%/*}"
  if ! jq -e --argjson id "$hcId" '.healthchecks[] | select(.healthCheckId == $id)' "$STATE_FILE" >/dev/null 2>&1; then
    envelope 'null' false true "Health check not found: $hcId" 404; exit 0
  fi
  local state
  state="$(jq --argjson id "$hcId" '.healthchecks = [.healthchecks[] | select(.healthCheckId != $id)]' "$STATE_FILE")"
  save_state "$state"
  envelope 'null' true false "Health check deleted successfully" 200
}

get_health_check_status_history() { # GET /org/{orgId}/health-check/{healthCheckId}/status-history
  local hcId data
  hcId="${PATH_ARG##*/health-check/}"
  hcId="${hcId%%/*}"
  if ! jq -e --argjson id "$hcId" '.healthchecks[] | select(.healthCheckId == $id)' "$STATE_FILE" >/dev/null 2>&1; then
    envelope 'null' false true "Health check not found: $hcId" 404; exit 0
  fi
  # Return a small history array
  data="$(jq -n '[{status:"healthy", checkedAt:(now | todate)}, {status:"unhealthy", checkedAt:(now | todate)}]')"
  envelope "$data" true false "Health check status history retrieved successfully" 200
}

# --- client handlers ------------------------------------------------------
create_client() {
  local name type olmId secret subnet data newid state
  name="$(jq -r '.name // empty' <<<"$BODY")"
  type="$(jq -r '.type // "olm"' <<<"$BODY")"
  olmId="$(jq -r '.olmId // empty' <<<"$BODY")"
  secret="$(jq -r '.secret // empty' <<<"$BODY")"
  subnet="$(jq -r '.subnet // empty' <<<"$BODY")"
  [[ -n "$name" ]] || { envelope 'null' false true 'name is required' 400; exit 0; }
  maxid="$(jq '[.clients[].clientId] | max // 0' "$STATE_FILE")"
  newid=$((maxid + 1))
  [[ -n "$olmId" ]] || { olmId="clientolm${newid}"; }
  [[ -n "$secret" ]] || { secret="mocksecret${newid}"; }
  [[ -n "$subnet" ]] || { subnet="100.0.0.${newid}/24"; }
  state="$(jq --argjson id "$newid" --arg name "$name" --arg type "$type" \
    --arg olmId "$olmId" --arg secret "$secret" --arg subnet "$subnet" \
    '.clients += [{clientId:$id, name:$name, type:$type, olmId:$olmId, secret:$secret, subnet:$subnet, online:false}]' \
    "$STATE_FILE")"
  save_state "$state"
  data="$(jq -n --argjson id "$newid" --arg name "$name" --arg type "$type" \
    --arg olmId "$olmId" --arg secret "$secret" --arg subnet "$subnet" \
    '{clientId:$id, name:$name, type:$type, olmId:$olmId, secret:$secret, subnet:$subnet, online:false}')"
  envelope "$data" true false "Client created successfully" 201
}

get_client() {
  local cid data
  cid="$(sed -E 's#.*/([0-9]+)$#\1#' <<<"$PATH_ARG")"
  data="$(jq -c --argjson id "$cid" '.clients[] | select(.clientId == $id)' "$STATE_FILE")"
  if [[ "$(jq 'length' <<<"$data")" -eq 0 ]]; then
    envelope 'null' false true "Client not found: $cid" 404; exit 0
  fi
  envelope "$data" true false "Client retrieved successfully" 200
}

delete_client() {
  local cid data state
  cid="$(sed -E 's#.*/([0-9]+)$#\1#' <<<"$PATH_ARG")"
  if ! jq -e --argjson id "$cid" '.clients[] | select(.clientId == $id)' "$STATE_FILE" >/dev/null 2>&1; then
    envelope 'null' false true "Client not found: $cid" 404; exit 0
  fi
  state="$(jq --argjson id "$cid" '.clients = [.clients[] | select(.clientId != $id)]' "$STATE_FILE")"
  save_state "$state"
  envelope 'null' true false "Client deleted successfully" 200
}

# --- router -----------------------------------------------------------------
main() {
  ensure_state
  if ! auth_ok; then
    envelope 'null' false true "Invalid or missing API key" 401
    exit 0
  fi
  if [[ "${PANGOLIN_MOCK_ERROR:-}" == "1" ]]; then
    envelope 'null' false true "Internal server error (simulated)" 500
    exit 0
  fi
                case "$METHOD $PATH_ARG" in
    "GET /org/"*"/sites")               list_entities sites "Sites retrieved successfully" ;;
    "GET /org/"*"/resources")           list_entities resources "Resources retrieved successfully" ;;
    "GET /org/"*"/domains")             list_entities domains "Domains retrieved successfully" ;;
    "GET /org/"*"/clients")             list_entities clients "Clients retrieved successfully" ;;
    "GET /org/"*"/users")               list_entities users "Users retrieved successfully" ;;
    "GET /org/"*"/roles")               list_entities roles "Roles retrieved successfully" ;;
    "GET /resource/"*"/targets")        list_targets ;;
    "GET /org/"*"/pick-site-defaults")  pick_site_defaults ;;
    "PUT /org/"*"/site")                create_site ;;
    "PUT /org/"*"/resource")            create_resource ;;
    "PUT /resource/"*"/target")         create_target ;;
    "POST /resource/"*"/roles/add")     add_role ;;
    "POST /resource/"*"/users/add")     add_user ;;
    "PUT /org/"*"/blueprint")           apply_blueprint ;;
    "GET /org/"*"/health-checks")     list_health_checks ;;
    "GET /org/"*"/health-check/"*"/status-history") get_health_check_status_history ;;
    "PUT /org/"*"/health-check")      create_health_check ;;
    "POST /org/"*"/health-check/"*"") update_health_check ;;
    "DELETE /org/"*"/health-check/"*"") delete_health_check ;;
    "GET /client/"*)             get_client ;;
    "PUT /org/"*"/client")             create_client ;;
    "DELETE /client/"*)             delete_client ;;
    "DELETE /org/"*"/client/"*"") delete_client ;;
    *)
      envelope 'null' false true "Not found: $METHOD $PATH_ARG" 404
      ;;
esac

}

main "$@"
