#!/bin/bash
# judge/agent/moj-agent.sh — agente de juiz API-first (modelo PULL).
# Só conexões de SAÍDA (curl): registra capacidade+inventário, manda heartbeat e,
# quando o heartbeat devolve um job, julga com mojtools e devolve o resultado.
# Aposenta root-daemon + job-receiveitor (sem porta de entrada, sem nc, sem poll-storm).
#
#   MOJ_API=https://moj.example/api/v1 CAPABILITY=pos bash moj-agent.sh
set -u
SELF="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SELF/inventory.sh"

: "${MOJ_API:=http://localhost/api/v1}"
: "${WORKER_TOKEN_FILE:=/home/prof/judge/etc/worker.token}"   # mojw_<segredo> (NFS, 600)
: "${MOJTOOLS_DIR:=$HOME/mojtools}"
: "${PROBLEMSDIR:=/home/prof/judge/problems}"
: "${UPDATE_SCRIPT:=/home/prof/judge/update-problems.sh}"
: "${CAPABILITY:=pos}"
: "${HEARTBEAT_SECS:=3}"
: "${AGENT_HOST:=$(hostname)}"
BAT="$MOJTOOLS_DIR/build-and-test.sh"
export PROBLEMSDIR

TOKEN="$(< "$WORKER_TOKEN_FILE" 2>/dev/null)"
[[ -n "$TOKEN" ]] || { echo "moj-agent: sem worker token em $WORKER_TOKEN_FILE" >&2; exit 1; }

alog() { echo "[moj-agent $(date +%H:%M:%S)] $*" >&2; }

_api() {  # _api <path> <json-body> -> resposta no stdout (vazio em erro)
  curl -fsS -m 30 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "$2" "$MOJ_API$1" 2>/dev/null
}

INVHASH=""
register() {
  local specs problems body
  specs="$(agent_specs_json)"; problems="$(agent_problems_json)"
  INVHASH="$(agent_inv_hash "$problems")"
  body="$(jq -cn --arg host "$AGENT_HOST" --arg cap "$CAPABILITY" \
    --argjson specs "$specs" --argjson problems "$problems" --arg ih "$INVHASH" \
    '$specs + {host:$host, capability:$cap, problems:$problems, inv_hash:$ih}')"
  _api /judge/register "$body" >/dev/null \
    && alog "registrado ($(jq -r 'length' <<<"$problems") problemas, inv=$INVHASH)" \
    || alog "falha ao registrar"
}

# array JSON [{name,code,time,tl}] dos testes, a partir do workdir do build-and-test.
agent_tests_json() {  # $1=workdir $2=tl
  local wb="$1" tl="$2" line file code t
  [[ -f "$wb/log.verdictall" ]] || { echo '[]'; return; }
  {
    while IFS= read -r line; do
      [[ "$line" =~ ^VERDICT\[(.+)\]=(.+)$ ]] || continue
      file="${BASH_REMATCH[1]}"; code="${BASH_REMATCH[2]}"
      t=""; [[ -s "$wb/$file-log.timelog" ]] && \
        t="$(grep -m1 '^real' "$wb/$file-log.timelog" 2>/dev/null | awk '{print $NF}')"
      jq -cn --arg n "$file" --arg c "$code" --arg t "$t" --arg tl "$tl" \
        '{name:$n, code:$c, time:($t|tonumber? // null), tl:($tl|tonumber? // null)}'
    done < "$wb/log.verdictall"
  } | jq -s -c '.'
}

run_job() {  # $1 = job JSON (roda em background; faz o próprio POST de result)
  local job="$1" id contest problem login lang filename code_b64
  id="$(jq -r '.id // empty' <<<"$job")"
  contest="$(jq -r '.contest // empty' <<<"$job")"
  problem="$(jq -r '.problem_id // empty' <<<"$job")"
  login="$(jq -r '.login // ""' <<<"$job")"
  lang="$(jq -r '(.lang // .language // "") | ascii_downcase' <<<"$job")"
  filename="$(basename "$(jq -r '.filename // "solution"' <<<"$job")")"
  code_b64="$(jq -r '.code_b64 // .fileb64 // ""' <<<"$job")"

  local pkg="$PROBLEMSDIR/$problem"
  [[ -d "$pkg" ]] || pkg="$PROBLEMSDIR/${problem//#//}"   # repo#prob -> repo/prob
  local work src; work="$(mktemp -d)"; src="$work/$filename"
  printf '%s' "$code_b64" | base64 -d > "$src" 2>/dev/null

  local out wb verdict
  out="$(bash "$BAT" "$lang" "$src" "$pkg" y 2>/dev/null)"
  wb="$(printf '%s\n' "$out" | head -n1)"
  verdict="$(printf '%s\n' "$out" | tail -n1)"
  [[ -n "$verdict" ]] || verdict="Judge Error (no verdict)"

  local CORRECT=0 TOTALTESTS=0 TOTALTIME=0 FINALRESP="$verdict" TL_LANG=""
  [[ -f "$wb/report.env" ]] && source "$wb/report.env" 2>/dev/null
  local tests html_b64 score
  tests="$(agent_tests_json "$wb" "$TL_LANG")"
  html_b64=""; [[ -f "$wb/report.html" ]] && html_b64="$(base64 -w0 "$wb/report.html")"
  score="$(printf '%s' "$FINALRESP" | grep -oE '[0-9]+p$' | tr -d p)"; score="${score:-0}"

  local payload
  payload="$(jq -cn \
    --arg host "$AGENT_HOST" --arg id "$id" --arg c "$contest" --arg p "$problem" \
    --arg login "$login" --arg lang "$lang" --arg v "$verdict" \
    --argjson score "${score:-0}" --argjson correct "${CORRECT:-0}" \
    --argjson total "${TOTALTESTS:-0}" --argjson dur "${TOTALTIME:-0}" \
    --arg tl "$TL_LANG" --argjson tests "$tests" --arg html "$html_b64" \
    '{host:$host, id:$id, contest:$c, problem_id:$p, login:$login, lang:$lang,
      verdict:$v, score:$score, correct:$correct, total_tests:$total, duration_s:$dur,
      tl_used:($tl|tonumber? // null), tests:$tests,
      report_html_b64:(if $html=="" then null else $html end)}')"
  _api /judge/result "$payload" >/dev/null \
    && alog "result enviado id=$id verdict=$verdict" \
    || alog "FALHA ao enviar result id=$id"
  rm -rf "$work" "$wb" 2>/dev/null
}

run_update() {  # $1 = request JSON (roda em background; faz o próprio POST de report)
  local upd="$1" reqid repo kind target logf rc problems pc valjson pkg
  reqid="$(jq -r '.reqid // empty' <<<"$upd")"
  repo="$(jq -r '.repo // ""' <<<"$upd")"
  kind="$(jq -r '.kind // "update"' <<<"$upd")"
  target="$(jq -r '.target // ""' <<<"$upd")"
  logf="$(mktemp)"; rc=0; valjson=null
  pkg="$PROBLEMSDIR/${target//#//}"
  case "$kind" in
    index)      # valida (portão) + indexa o problema alvo
      if [[ -n "$target" && -d "$pkg" ]]; then
        ( cd "$pkg/.." && git pull --recurse-submodules ) >"$logf" 2>&1 || true
        bash "$MOJTOOLS_DIR/validate-problem.sh" "$pkg" "$target" >>"$logf" 2>&1; rc=$?
        [[ -f "$RUNDIR/validation/$target.json" ]] && valjson="$(cat "$RUNDIR/validation/$target.json")"
      else echo "index: pacote inexistente p/ '$target' ($pkg)" >"$logf"; rc=1; fi ;;
    calibrate)  # roda o calibreitor (tl.<host>) e re-indexa
      if [[ -n "$target" && -d "$pkg" ]]; then
        ( cd "$pkg/.." && git pull --recurse-submodules ) >"$logf" 2>&1 || true
        bash "$MOJTOOLS_DIR/calibreitor.sh" "$pkg" >>"$logf" 2>&1; rc=$?
        bash "$MOJTOOLS_DIR/validate-problem.sh" "$pkg" "$target" >>"$logf" 2>&1 || true
        [[ -f "$RUNDIR/validation/$target.json" ]] && valjson="$(cat "$RUNDIR/validation/$target.json")"
      else echo "calibrate: pacote inexistente p/ '$target'" >"$logf"; rc=1; fi ;;
    *)          # update (default): git pull + make do repo inteiro
      if [[ -r "$UPDATE_SCRIPT" ]]; then bash "$UPDATE_SCRIPT" stdout "$repo" >"$logf" 2>&1; rc=$?
      elif [[ -n "$repo" && -d "$PROBLEMSDIR/${repo//#//}" ]]; then
        ( cd "$PROBLEMSDIR/${repo//#//}" && git pull --recurse-submodules ) >"$logf" 2>&1; rc=$?
      else echo "sem UPDATE_SCRIPT ($UPDATE_SCRIPT) e repo inválido: '$repo'" >"$logf"; rc=1; fi ;;
  esac
  problems="$(agent_problems_json)"; pc="$(jq 'length' <<<"$problems")"
  INVHASH="$(agent_inv_hash "$problems")"
  local okj=false; (( rc == 0 )) && okj=true
  _api /judge/update-report "$(jq -cn --arg host "$AGENT_HOST" --arg reqid "$reqid" \
    --arg repo "$repo" --arg kind "$kind" --arg target "$target" --argjson ok "$okj" \
    --arg log "$(base64 -w0 < "$logf")" --argjson pc "${pc:-0}" --argjson val "$valjson" \
    '{host:$host, reqid:$reqid, repo:$repo, kind:$kind, target:$target, ok:$ok,
      log_b64:$log, problems_count:$pc, validation:$val}')" >/dev/null \
    && alog "report enviado reqid=$reqid kind=$kind ok=$okj" || alog "FALHA report reqid=$reqid"
  rm -f "$logf"
  register   # re-registra o inventário atualizado (e volta a free)
}

# ----------------------------------------------------------------- loop principal
alog "subindo: host=$AGENT_HOST cap=$CAPABILITY api=$MOJ_API hb=${HEARTBEAT_SECS}s"
register
BUSYPID=0   # pid do job/update rodando em background (0 = livre)
while true; do
  if (( BUSYPID != 0 )) && ! kill -0 "$BUSYPID" 2>/dev/null; then BUSYPID=0; fi
  state=free; (( BUSYPID != 0 )) && state=busy

  resp="$(_api /judge/heartbeat \
    "$(jq -cn --arg h "$AGENT_HOST" --arg s "$state" --arg ih "$INVHASH" \
       '{host:$h, state:$s, inv_hash:$ih}')")"
  if [[ -n "$resp" ]]; then
    [[ "$(jq -r '.reregister // false' <<<"$resp" 2>/dev/null)" == true ]] && register
    if (( BUSYPID == 0 )); then
      upd="$(jq -c '.update // empty' <<<"$resp" 2>/dev/null)"
      job="$(jq -c '.assigned // empty' <<<"$resp" 2>/dev/null)"
      if [[ -n "$upd" && "$upd" != null ]]; then
        run_update "$upd" & BUSYPID=$!
        alog "update reivindicado reqid=$(jq -r '.reqid' <<<"$upd" 2>/dev/null) -> pid $BUSYPID"
      elif [[ -n "$job" && "$job" != null ]]; then
        run_job "$job" & BUSYPID=$!
        alog "job reivindicado id=$(jq -r '.id' <<<"$job" 2>/dev/null) -> pid $BUSYPID"
      fi
    fi
  fi
  sleep "$HEARTBEAT_SECS"
done
