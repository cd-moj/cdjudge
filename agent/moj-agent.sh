#!/bin/bash
# judge/agent/moj-agent.sh — agente de juiz API-first (modelo PULL + CACHE).
# Só conexões de SAÍDA (curl). Não clona repositório: baixa o PACOTE de cada problema
# (sob demanda) p/ um CACHE local, calibra na 1ª vez (e quando o problema muda) e
# REPORTA o TL ao MOJ. Guarda o tl+checksum no cache p/ re-reportar ao ser relançado.
# Assim a consistência de NFS vira só "aproveitar o cache" e levantar um juiz é trivial.
#
#   MOJ_API=https://moj.example/api/v1 CAPABILITY=pos bash moj-agent.sh
set -u
SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SELF/inventory.sh"

: "${MOJ_API:=http://localhost/api/v1}"
: "${WORKER_TOKEN_FILE:=/home/prof/judge/etc/worker.token}"   # mojw_<segredo> (600)
: "${MOJTOOLS_DIR:=$HOME/mojtools}"
: "${JUDGE_CACHE:=$HOME/.cache/moj/problems}"                 # cache local de pacotes
: "${CAPABILITY:=pos}"
: "${HEARTBEAT_SECS:=3}"
: "${AGENT_HOST:=$(hostname)}"
BAT="$MOJTOOLS_DIR/build-and-test.sh"
export JUDGE_CACHE
export HOSTNAME="$AGENT_HOST"   # calibreitor/build-and-test usam tl.$HOSTNAME = tl.$AGENT_HOST
mkdir -p "$JUDGE_CACHE" 2>/dev/null

TOKEN="$(cat "$WORKER_TOKEN_FILE" 2>/dev/null)"   # nota: $(<f 2>/dev/null) some com o conteúdo
[[ -n "$TOKEN" ]] || { echo "moj-agent: sem worker token em $WORKER_TOKEN_FILE" >&2; exit 1; }

alog() { echo "[moj-agent $(date +%H:%M:%S)] $*" >&2; }

# Raiz da jaula (sandbox): por PADRÃO usamos o ROOTFS reprodutível JÁ MONTADO em $HOME/moj-sysroot
# (o operador provisiona/monta; não recriamos), NÃO o host — assim todo juiz fica idêntico.
#   CAGE_ROOT ausente/vazio -> $HOME/moj-sysroot (a convenção; já montado)
#   CAGE_ROOT=host          -> força o toolchain do HOST (escape hatch)
#   CAGE_ROOT=<dir>         -> esse rootfs específico
#   AGENT_BUILD_ROOTFS=1    -> se faltar, CONSTRÓI com make-sysroot.sh (precisa podman); default NÃO recria
ensure_rootfs() {
  case "${CAGE_ROOT:-}" in
    host|HOST|/) alog "jaula: HOST (CAGE_ROOT=host) — toolchain não-reprodutível"; unset CAGE_ROOT; return 0;;
    "")          CAGE_ROOT="$HOME/moj-sysroot";;       # convenção: rootfs já montado no HOME
  esac
  if [[ -d "$CAGE_ROOT/usr" && -d "$CAGE_ROOT/etc" ]]; then
    export CAGE_ROOT; alog "jaula: rootfs $CAGE_ROOT"; return 0
  fi
  # rootfs AUSENTE: por padrão NÃO recria (o moj-sysroot é montado/provisionado pelo operador).
  # Só constrói sob demanda: AGENT_BUILD_ROOTFS=1 (com podman + make-sysroot).
  local log="${AGENT_ROOTFS_LOG:-/tmp/moj-sysroot.$AGENT_HOST.log}"
  if [[ "${AGENT_BUILD_ROOTFS:-0}" == 1 ]] && command -v podman >/dev/null 2>&1 && [[ -f "$MOJTOOLS_DIR/make-sysroot.sh" ]]; then
    alog "jaula: rootfs ausente em $CAGE_ROOT — construindo (AGENT_BUILD_ROOTFS=1; log: $log)…"
    if bash "$MOJTOOLS_DIR/make-sysroot.sh" --out "$CAGE_ROOT" >>"$log" 2>&1 && [[ -d "$CAGE_ROOT/usr" ]]; then
      export CAGE_ROOT; alog "jaula: rootfs pronto em $CAGE_ROOT"; return 0
    fi
    alog "jaula: FALHA ao construir o rootfs (ver $log) — caindo p/ HOST"
  else
    alog "jaula: rootfs ausente em $CAGE_ROOT — não recrio (AGENT_BUILD_ROOTFS=1 p/ construir); usando HOST"
  fi
  unset CAGE_ROOT   # fallback seguro: ainda julga, mesmo que no host
  return 0
}

# Deploys atrás de túnel SSH/proxy. MOJ_RESOLVE="host:porta:IP" mapeia o nome p/ o túnel
# (curl --resolve) preservando SNI/cert/Host — ideal p/ HTTPS (8443) via reverse tunnel.
# MOJ_HOST_HEADER manda "Host: <nome>" (caso HTTP por vhost). Ambos opcionais.
: "${MOJ_HOST_HEADER:=}"
: "${MOJ_RESOLVE:=}"
_HH=(); [[ -n "$MOJ_HOST_HEADER" ]] && _HH=(-H "Host: $MOJ_HOST_HEADER")
[[ -n "$MOJ_RESOLVE" ]] && _HH+=(--resolve "$MOJ_RESOLVE")

_api() {  # _api <path> <json-body> -> resposta no stdout (vazio em erro)
  curl -fsS -m 30 "${_HH[@]}" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "$2" "$MOJ_API$1" 2>/dev/null
}
_api_get() {  # _api_get <path> -> corpo no stdout
  curl -fsS -m 30 "${_HH[@]}" -H "Authorization: Bearer $TOKEN" "$MOJ_API$1" 2>/dev/null
}
_api_get_file() {  # _api_get_file <path> <outfile> -> baixa (rc!=0 em erro)
  curl -fsS -m 180 "${_HH[@]}" -H "Authorization: Bearer $TOKEN" -o "$2" "$MOJ_API$1" 2>/dev/null
}
_uri() { jq -rn --arg s "$1" '$s|@uri'; }   # url-encode (id tem '#')

# ----------------------------------------------------------------- cache de pacotes
cache_id_dir() { printf '%s/%s' "$JUDGE_CACHE" "$(printf '%s' "$1" | tr '#/' '__')"; }

# tl_to_json <tlfile> -> {lang:val} a partir do bash TL[lang]=val
tl_to_json() {
  ( declare -A TL TLMOD; source "$1" 2>/dev/null
    for k in "${!TL[@]}"; do printf '%s\t%s\n' "$k" "${TL[$k]}"; done ) \
  | jq -R -s -c 'split("\n")|map(select(length>0)|split("\t")|{(.[0]):.[1]})|add // {}'
}

# report_tl <id> <checksum> <pkgdir> : reporta ao MOJ o TL calibrado (tl.$AGENT_HOST).
report_tl() {
  local id="$1" cks="$2" pkg="$3" tlf="$3/tl.$AGENT_HOST" tlj
  [[ -f "$tlf" ]] || tlf="$pkg/tl"
  [[ -f "$tlf" ]] || { alog "report_tl: sem tl p/ $id"; return 1; }
  tlj="$(tl_to_json "$tlf")"
  _api /judge/tl-report "$(jq -cn --arg h "$AGENT_HOST" --arg id "$id" --arg c "$cks" \
        --argjson tl "$tlj" '{host:$h, id:$id, checksum:$c, tl:$tl}')" >/dev/null
}

# report_calib_log <id> <checksum> <logfile> [pkgdir] : envia ao MOJ o LOG de calibração
# (limitado) + o report.html POR SOLUÇÃO (pkg/.calib-reports/*), p/ o autor ver no editor, por
# juiz, como cada solução se comportou. Falha não atrapalha o julgamento.
report_calib_log() {
  local id="$1" cks="$2" lf="$3" pkg="${4:-}" log="" reports='[]'
  [[ -f "$lf" ]] && log="$(tail -c 60000 "$lf" 2>/dev/null)"
  if [[ -d "$pkg/.calib-reports" ]]; then
    local rf n=0 sz
    for rf in "$pkg/.calib-reports/"*.html; do
      [[ -f "$rf" ]] || continue
      sz="$(stat -c%s "$rf" 2>/dev/null || echo 0)"; (( sz > 0 && sz <= 500000 )) || continue
      (( n++ >= 12 )) && break
      reports="$(jq -c --arg n "$(basename "$rf" .html)" --rawfile h "$rf" '. + [{name:$n, html_b64:($h|@base64)}]' <<<"$reports" 2>/dev/null)" || reports='[]'
    done
  fi
  _api /judge/calib-report "$(jq -cn --arg h "$AGENT_HOST" --arg id "$id" --arg c "$cks" --arg log "$log" --argjson reports "$reports" \
        '{host:$h, id:$id, checksum:$c, log:$log, reports:$reports}')" >/dev/null || true
}

# ensure_cached <id> [force_report] [full] : garante o pacote no cache p/ a versão ATUAL e que
# o TL esteja calibrado+reportado. Baixa+calibra na 1ª vez ou se o checksum mudou. full=1 força
# recalibração rodando TODAS as soluções (Calibrar explícito). Ecoa o diretório do pacote.
ensure_cached() {
  local id="$1" force="${2:-0}" full="${3:-0}" cdir meta mj sc local_cks
  cdir="$(cache_id_dir "$id")"; meta="$cdir/.moj-cache.json"
  mkdir -p "$cdir" 2>/dev/null
  mj="$(_api_get "/judge/package-meta?id=$(_uri "$id")")"
  [[ "$(jq -r '.exists // false' <<<"$mj" 2>/dev/null)" == true ]] || { alog "pkg inexistente: $id"; return 1; }
  sc="$(jq -r '.checksum // empty' <<<"$mj" 2>/dev/null)"
  [[ -n "$sc" ]] || { alog "sem checksum p/ $id"; return 1; }
  local_cks="$(jq -r '.checksum // empty' "$meta" 2>/dev/null)"

  # cache válido (mesma versão) + já calibrado: opcionalmente re-reporta e sai (full=1 recalibra)
  if [[ "$full" != 1 && -d "$cdir/pkg" && "$local_cks" == "$sc" && -f "$cdir/pkg/tl.$AGENT_HOST" ]]; then
    if [[ "$force" == 1 ]]; then
      report_tl "$id" "$sc" "$cdir/pkg" \
        && jq -c --argjson now "$EPOCHSECONDS" '.tl_reported=true|.reported_at=$now' "$meta" >"$meta.t" 2>/dev/null \
        && mv -f "$meta.t" "$meta"
    fi
    printf '%s' "$cdir/pkg"; return 0
  fi

  # (1ª vez ou mudou) baixa+extrai+calibra+reporta, sob lock por-problema
  (
    flock 9 || exit 1
    local lc; lc="$(jq -r '.checksum // empty' "$meta" 2>/dev/null)"
    if [[ "$full" != 1 && -d "$cdir/pkg" && "$lc" == "$sc" && -f "$cdir/pkg/tl.$AGENT_HOST" ]]; then exit 0; fi  # outro já fez
    # baixa+extrai só se ainda não temos a versão atual (em full reaproveita o pacote do cache)
    if [[ ! -d "$cdir/pkg" || "$lc" != "$sc" ]]; then
      local tar="$cdir/.pkg.tgz" top src
      _api_get_file "/judge/package?id=$(_uri "$id")" "$tar" || { alog "falha baixar $id"; exit 1; }
      rm -rf "$cdir/.new"; mkdir -p "$cdir/.new"
      tar -xzf "$tar" -C "$cdir/.new" --no-same-owner 2>/dev/null || { alog "tar inválido $id"; rm -f "$tar"; exit 1; }
      rm -f "$tar"
      top="$(find "$cdir/.new" -mindepth 1 -maxdepth 1)"
      if [[ "$(printf '%s\n' "$top" | grep -c .)" -eq 1 && -d "$top" ]]; then src="$top"; else src="$cdir/.new"; fi
      rm -rf "$cdir/pkg.tmp"; cp -a "$src" "$cdir/pkg.tmp" 2>/dev/null
      rm -rf "$cdir/.new"
      rm -rf "$cdir/pkg"; mv "$cdir/pkg.tmp" "$cdir/pkg" 2>/dev/null
    fi
    # calibra (gera tl.$AGENT_HOST) e reporta. full=1 (Calibrar explícito) roda TODAS as soluções
    # (good/pass/slow/wrong) p/ o log mostrar o comportamento de cada uma; senão só as good
    # (rápido, sob demanda). Robusto a toolchain ausente (pula a linguagem, não aborta).
    if [[ "$full" == 1 ]]; then
      MOJ_PROBLEM_ID="$id" bash "$MOJTOOLS_DIR/calibreitor.sh" "$cdir/pkg" >"$cdir/.calib.log" 2>&1
    else
      MOJ_PROBLEM_ID="$id" CALIBRATE_ONLY_GOOD=1 bash "$MOJTOOLS_DIR/calibreitor.sh" "$cdir/pkg" >"$cdir/.calib.log" 2>&1
    fi
    [[ -f "$cdir/pkg/tl.$AGENT_HOST" ]] || { alog "calibração não gerou tl p/ $id (ver $cdir/.calib.log)"; exit 2; }
    report_tl "$id" "$sc" "$cdir/pkg" || alog "report_tl falhou $id"
    report_calib_log "$id" "$sc" "$cdir/.calib.log" "$cdir/pkg"
    jq -cn --arg id "$id" --arg c "$sc" --argjson now "$EPOCHSECONDS" \
       '{id:$id, checksum:$c, tl_reported:true, calibrated_at:$now, reported_at:$now}' > "$meta"
    alog "cacheado+calibrado $id (cks=${sc:0:8})"
  ) 9>"$cdir.lock"

  [[ -d "$cdir/pkg" && -f "$cdir/pkg/tl.$AGENT_HOST" ]] || return 1
  printf '%s' "$cdir/pkg"
}

# report_cached_tls : ao subir/relançar, re-reporta o TL de todos os problemas do cache
# já calibrados (o MOJ repovoa o TL por host sem recalibrar).
report_cached_tls() {
  local d id cks n=0
  [[ -d "$JUDGE_CACHE" ]] || return 0
  while IFS= read -r d; do
    [[ -f "$d/.moj-cache.json" && -d "$d/pkg" ]] || continue
    id="$(jq -r '.id // empty' "$d/.moj-cache.json" 2>/dev/null)"
    cks="$(jq -r '.checksum // empty' "$d/.moj-cache.json" 2>/dev/null)"
    [[ -n "$id" && -n "$cks" && -f "$d/pkg/tl.$AGENT_HOST" ]] || continue
    report_tl "$id" "$cks" "$d/pkg" && n=$((n+1))
  done < <(find "$JUDGE_CACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  (( n > 0 )) && alog "re-reportei TL de $n problema(s) do cache"
}

INVHASH=""
register() {
  local specs problems langs body
  specs="$(agent_specs_json)"; problems="$(agent_problems_json)"; langs="$(agent_langs_json)"
  INVHASH="$(agent_inv_hash "$problems")"
  local cbytes; cbytes="$(du -sb "$JUDGE_CACHE" 2>/dev/null | cut -f1)"; [[ "$cbytes" =~ ^[0-9]+$ ]] || cbytes=0
  body="$(jq -cn --arg host "$AGENT_HOST" --arg cap "$CAPABILITY" \
    --argjson specs "$specs" --argjson problems "$problems" --argjson langs "$langs" \
    --arg cage "${CAGE_ROOT:-}" --argjson cb "$cbytes" --arg ih "$INVHASH" \
    '$specs + {host:$host, capability:$cap, problems:$problems, langs:$langs,
               cage_root:(if $cage=="" then null else $cage end),
               cache_bytes:$cb, inv_hash:$ih}')"
  _api /judge/register "$body" >/dev/null \
    && alog "registrado ($(jq -r 'length' <<<"$problems") problemas, $(jq -r 'length' <<<"$langs") linguagens, inv=$INVHASH)" \
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

# resultado de Judge Error simples (sem testes), p/ falhas de preparo do pacote.
_post_judge_error() {  # $1=id $2=contest $3=problem $4=login $5=lang $6=msg
  _api /judge/result "$(jq -cn --arg host "$AGENT_HOST" --arg id "$1" --arg c "$2" \
     --arg p "$3" --arg login "$4" --arg lang "$5" --arg v "$6" \
     '{host:$host,id:$id,contest:$c,problem_id:$p,login:$login,lang:$lang,verdict:$v,
       score:0,correct:0,total_tests:0,duration_s:0,tl_used:null,tests:[],report_html_b64:null}')" >/dev/null
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

  # garante o pacote no cache (baixa + calibra na 1ª vez / se mudou)
  local pkg; pkg="$(ensure_cached "$problem")" || {
    _post_judge_error "$id" "$contest" "$problem" "$login" "$lang" "Judge Error (pacote indisponível)"
    alog "FALHA preparar pacote id=$id problem=$problem"; return; }

  local work src; work="$(mktemp -d)"; src="$work/$filename"
  printf '%s' "$code_b64" | base64 -d > "$src" 2>/dev/null

  local out wb verdict
  # MOJ_PROBLEM_ID: id real do problema p/ o report (o pacote no cache é <id>/pkg) + ativa a
  # coleta do toolchain no build-and-test (só p/ submissão real, não na calibração).
  out="$(MOJ_PROBLEM_ID="$problem" bash "$BAT" "$lang" "$src" "$pkg" y 2>/dev/null)"
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
  local upd="$1" reqid repo kind target logf rc okj problems pc
  reqid="$(jq -r '.reqid // empty' <<<"$upd")"
  repo="$(jq -r '.repo // ""' <<<"$upd")"
  kind="$(jq -r '.kind // "calibrate"' <<<"$upd")"
  target="$(jq -r '.target // ""' <<<"$upd")"
  logf="$(mktemp)"; rc=0
  case "$kind" in
    calibrate)   # Calibrar explícito: roda TODAS as soluções (full=1) e reporta TL + log
      if [[ -n "$target" ]]; then
        ensure_cached "$target" 1 1 >/dev/null 2>"$logf"; rc=$?
        # anexa o LOG da calibração (calibreitor) ao report -> visível no MOJ sem ssh.
        local _cd; _cd="$(cache_id_dir "$target")"
        if [[ -f "$_cd/.calib.log" ]]; then
          local _fails; _fails="$(grep -c 'was waiting Accepted' "$_cd/.calib.log" 2>/dev/null)"
          if [[ "${_fails:-0}" -gt 0 ]]; then
            echo "### ATENÇÃO: $_fails solução(ões) NÃO passaram na calibração de $target em $AGENT_HOST:" >> "$logf"
            grep 'was waiting Accepted' "$_cd/.calib.log" 2>/dev/null \
              | sed -E 's#^.*/sols/good/##; s# Check /tmp/.*$##' >> "$logf"
            echo "### (toolchain ausente/erro no juiz, ou solução realmente incorreta)" >> "$logf"
            rc=2   # calibrou (TL existe) mas com falhas -> sinaliza p/ o MOJ
          fi
          echo "=== calibreitor.log ($target @ $AGENT_HOST) ===" >> "$logf"
          cat "$_cd/.calib.log" >> "$logf"
        fi
      else echo "calibrate sem target" > "$logf"; rc=1; fi ;;
    *)           # index/update: legados — agora o SERVIDOR indexa e mantém o store
      echo "kind=$kind é legado no modelo cache (o servidor indexa); nada a fazer no juiz." > "$logf"; rc=0 ;;
  esac
  problems="$(agent_problems_json)"; pc="$(jq 'length' <<<"$problems")"
  INVHASH="$(agent_inv_hash "$problems")"
  okj=false; (( rc == 0 )) && okj=true
  _api /judge/update-report "$(jq -cn --arg host "$AGENT_HOST" --arg reqid "$reqid" \
    --arg repo "$repo" --arg kind "$kind" --arg target "$target" --argjson ok "$okj" \
    --arg log "$(base64 -w0 < "$logf")" --argjson pc "${pc:-0}" --argjson val null \
    '{host:$host, reqid:$reqid, repo:$repo, kind:$kind, target:$target, ok:$ok,
      log_b64:$log, problems_count:$pc, validation:$val}')" >/dev/null \
    && alog "report enviado reqid=$reqid kind=$kind ok=$okj" || alog "FALHA report reqid=$reqid"
  rm -f "$logf"
  register   # re-registra o inventário atualizado (e volta a free)
}

# comando por-host vindo do admin (heartbeat). Hoje: limpar o cache local.
run_command() {  # $1 = command JSON {cmdid, action, ...}
  local c="$1" action; action="$(jq -r '.action // empty' <<<"$c" 2>/dev/null)"
  case "$action" in
    clearcache)
      alog "comando do admin: limpar cache ($JUDGE_CACHE)"
      pkill -f calibreitor.sh 2>/dev/null
      [[ -n "$JUDGE_CACHE" ]] && rm -rf "${JUDGE_CACHE:?}/"* 2>/dev/null
      register   # inventário agora vazio -> o MOJ vê o cache limpo
      ;;
    calibrate)   # calibração DIRECIONADA a este host (full): baixa/recalibra e reporta
      local target; target="$(jq -r '.id // empty' <<<"$c" 2>/dev/null)"
      if [[ -n "$target" ]]; then
        alog "comando: calibrar $target (full) neste host"
        ensure_cached "$target" 1 1 >/dev/null 2>&1 && alog "calibrado $target" || alog "calibrate $target falhou"
      else alog "comando calibrate sem id"; fi
      ;;
    *) alog "comando desconhecido: ${action:-<vazio>}" ;;
  esac
}

# ----------------------------------------------------------------- loop principal
moj_agent_main() {
alog "subindo: host=$AGENT_HOST cap=$CAPABILITY api=$MOJ_API cache=$JUDGE_CACHE hb=${HEARTBEAT_SECS}s"
ensure_rootfs        # jaula no rootfs reprodutível (não no host); provisiona na 1ª vez
register
report_cached_tls    # relançamento: reenvia os TLs já calibrados (sem recalibrar)
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
      cmd="$(jq -c '.command // empty' <<<"$resp" 2>/dev/null)"
      upd="$(jq -c '.update // empty' <<<"$resp" 2>/dev/null)"
      job="$(jq -c '.assigned // empty' <<<"$resp" 2>/dev/null)"
      if [[ -n "$cmd" && "$cmd" != null ]]; then
        run_command "$cmd" & BUSYPID=$!
        alog "comando reivindicado $(jq -r '.action // .cmdid' <<<"$cmd" 2>/dev/null) -> pid $BUSYPID"
      elif [[ -n "$upd" && "$upd" != null ]]; then
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
}

# executado direto -> roda o loop; "sourced" (testes) -> só expõe as funções.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && moj_agent_main
