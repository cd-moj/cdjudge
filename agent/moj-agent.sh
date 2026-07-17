#!/bin/bash
# judge/agent/moj-agent.sh — agente de juiz API-first (modelo PULL + CACHE).
# Só conexões de SAÍDA (curl). Não clona repositório: baixa o PACOTE de cada problema
# (sob demanda) p/ um CACHE local, calibra na 1ª vez (e quando o problema muda) e
# REPORTA o TL ao MOJ. Guarda o tl+checksum no cache p/ re-reportar ao ser relançado.
# Assim levantar um juiz é trivial: ele baixa e cacheia sob demanda (sem NFS, sem clonar repo).
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

# Tetos de WALL-CLOCK por fase (anti-wedge; lição do incidente 2026-07-15): o teto é DINÂMICO —
# proporcional ao TL-por-teste × nº de testes (× soluções na calibração), com margem p/ compilação
# e reruns de TLE — e o `timeout` (que mata o GRUPO de processos: bwrap/time/compilador juntos)
# envolve o build-and-test/calibreitor DENTRO do slot. Fallback fixo só quando o pacote não dá
# p/ estimar. AGENT_LOCK_WAIT limita a espera no flock por-problema (fila atrás de calibração).
: "${AGENT_HARD_TL_FALLBACK:=1800}"
: "${AGENT_LOCK_WAIT:=3600}"
# Config de partição APLICADA persiste aqui (P6): um restart re-adota exatamente o que rodava
# (o agent.env é só o último fallback — make config o regrava e já causou o wedge C5).
AGENT_STATE="${AGENT_STATE:-$(dirname "$JUDGE_CACHE")/agent-state.json}"
# TMPDIR POR JOB: cada slot trabalha num diretório próprio sob AGENT_WORK — nenhum scratch de
# /tmp é compartilhado entre partições (e a limpeza no reap não deixa lixo acumular).
AGENT_WORK="${AGENT_WORK:-${TMPDIR:-/tmp}/moj-agent-work.$AGENT_HOST}"

TOKEN="$(cat "$WORKER_TOKEN_FILE" 2>/dev/null)"   # nota: $(<f 2>/dev/null) some com o conteúdo
[[ -n "$TOKEN" ]] || { echo "moj-agent: sem worker token em $WORKER_TOKEN_FILE" >&2; exit 1; }
# O token NUNCA vai no argv do curl: `-H "…Bearer $TOKEN"` aparece em /proc/*/cmdline (ps) p/
# QUALQUER usuário da máquina. Vai num config-file 600 (curl -K) criado uma vez; e some do
# ambiente (o `set -a` do run-agent exportaria TOKEN a todos os filhos -> /proc/*/environ).
AUTH_CFG="$(umask 077; mktemp "${XDG_RUNTIME_DIR:-/dev/shm}/moj-agent-auth.XXXXXX" 2>/dev/null || mktemp)"
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$AUTH_CFG"
trap 'rm -f "$AUTH_CFG"' EXIT
unset TOKEN
_AUTH=(-K "$AUTH_CFG")

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

_api() {  # _api <path> <json-body> -> resposta no stdout; resiliente (re-tenta um POST que falhou)
  local i out                                  # antes: 1 tentativa -> um POST perdido sumia com o TL/log
  for i in 1 2 3; do
    out="$(curl -fsS -m 30 "${_HH[@]}" "${_AUTH[@]}" -H 'Content-Type: application/json' \
      --data "$2" "$MOJ_API$1" 2>/dev/null)" && { printf '%s' "$out"; return 0; }
    sleep 2
  done
  return 1
}
_api_get() {  # _api_get <path> -> corpo no stdout
  curl -fsS -m 30 "${_HH[@]}" "${_AUTH[@]}" "$MOJ_API$1" 2>/dev/null
}
_api_file() {  # _api_file <path> <bodyfile> : POST com o corpo vindo de ARQUIVO. Obrigatório p/
  # payloads grandes (report.html em base64): um ÚNICO arg >128KB estoura MAX_ARG_STRLEN
  # ("Argument list too long") e o POST se perdia em silêncio. Re-tenta como o _api.
  local i
  for i in 1 2 3; do
    curl -fsS -m 60 "${_HH[@]}" "${_AUTH[@]}" -H 'Content-Type: application/json' \
      --data-binary "@$2" "$MOJ_API$1" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
_api_get_file() {  # _api_get_file <path> <outfile> -> baixa (rc!=0 em erro)
  curl -fsS -m 180 "${_HH[@]}" "${_AUTH[@]}" -o "$2" "$MOJ_API$1" 2>/dev/null
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
  # monta o corpo num ARQUIVO: os reports (grandes) entram por stdin no jq, nunca por argv.
  local bf; bf="$(mktemp)"
  printf '%s' "$reports" | jq -c --arg h "$AGENT_HOST" --arg id "$id" --arg c "$cks" --arg log "$log" \
        '{host:$h, id:$id, checksum:$c, log:$log, reports:.}' > "$bf" 2>/dev/null
  [[ -s "$bf" ]] && _api_file /judge/calib-report "$bf"
  rm -f "$bf"
}

# ---- tetos DINÂMICOS de wall-clock (por job/por calibração) -------------------------
# _job_cap <pkgdir> <lang> -> segundos p/ UM julgamento: (TL+2.2)s/teste ×2 (rerun de TLE)
# + compile-tl + folga. Piso 300s; fallback fixo se o pacote não dá p/ ler.
_job_cap() {
  local pkg="$1" lang="$2" n tl compl cap
  n="$(find "$pkg/tests/input" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] || { printf '%s' "$AGENT_HARD_TL_FALLBACK"; return; }
  tl="$( ( declare -A TL TLMOD; source "$pkg/tl.$AGENT_HOST" 2>/dev/null
           printf '%s' "${TL[$lang]:-${TL[default]:-5}}" ) )"
  [[ "$tl" =~ ^[0-9]+([.][0-9]+)?$ ]] || tl=5
  compl="$(cat "$pkg/scripts/$lang/compile-tl" "$MOJTOOLS_DIR/lang/$lang/compile-tl" 2>/dev/null | head -n1)"
  [[ "$compl" =~ ^[0-9]+$ ]] || compl=30
  cap="$(echo "($tl + 2.2) * $n * 2 + $compl + 60" | bc -l 2>/dev/null)"; cap="${cap%%.*}"
  [[ "$cap" =~ ^[0-9]+$ ]] || cap="$AGENT_HARD_TL_FALLBACK"
  (( cap < 300 )) && cap=300
  printf '%s' "$cap"
}
# _calib_cap <pkgdir> <full> -> segundos p/ a calibração: (CALIBRATIONTL+2.2)s/teste × nº de
# soluções (full = todas; senão só good) ×2 + compilações + folga. Piso 300s.
_calib_cap() {
  local pkg="$1" full="${2:-0}" n s caltl cap
  n="$(find "$pkg/tests/input" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  if [[ "$full" == 1 ]]; then s="$(find "$pkg/sols" -mindepth 2 -maxdepth 2 -type f 2>/dev/null | wc -l)"
  else s="$(find "$pkg/sols/good" -maxdepth 1 -type f 2>/dev/null | wc -l)"; fi
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$s" =~ ^[0-9]+$ && "$s" -ge 1 ]] \
    || { printf '%s' "$AGENT_HARD_TL_FALLBACK"; return; }
  caltl="$( ( declare -A ULIMITS TLMOD; CALIBRATIONTL=""; source "$pkg/conf" 2>/dev/null
              printf '%s' "${CALIBRATIONTL:-5}" ) )"
  [[ "$caltl" =~ ^[0-9]+([.][0-9]+)?$ ]] || caltl=5
  cap="$(echo "($caltl + 2.2) * $n * $s * 2 + $s * 30 + 120" | bc -l 2>/dev/null)"; cap="${cap%%.*}"
  [[ "$cap" =~ ^[0-9]+$ ]] || cap="$AGENT_HARD_TL_FALLBACK"
  (( cap < 300 )) && cap=300
  printf '%s' "$cap"
}

# ensure_cached <id> [force_report] [full] [req_epoch] : garante o pacote no cache p/ a versão
# ATUAL e que o TL esteja calibrado+reportado. Baixa+calibra na 1ª vez ou se o checksum mudou.
# full=1 força recalibração rodando TODAS as soluções (Calibrar explícito). req_epoch = quando o
# PEDIDO foi feito (requested_at do update / at do comando): full de um pedido MAIS VELHO que a
# última calibração full do MESMO checksum é duplicata satisfeita — skip (checksum novo SEMPRE
# recalibra). Ecoa o diretório do pacote.
ensure_cached() {
  local id="$1" force="${2:-0}" full="${3:-0}" req_epoch="${4:-0}" cdir meta mj sc local_cks
  [[ "$req_epoch" =~ ^[0-9]+$ ]] || req_epoch=0
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
    echo "$EPOCHSECONDS" > "$cdir/.last-used" 2>/dev/null   # carimbo de USO (o GC decide por ele)
    printf '%s' "$cdir/pkg"; return 0
  fi

  # (1ª vez ou mudou) baixa+extrai+calibra+reporta, sob lock por-problema. A espera no lock é
  # LIMITADA (AGENT_LOCK_WAIT): fila infinita atrás de uma calibração presa não segura o slot.
  local wait_start="$EPOCHSECONDS"
  (
    flock -w "$AGENT_LOCK_WAIT" 9 || { alog "timeout esperando lock de $id (${AGENT_LOCK_WAIT}s)"; exit 1; }
    local lc; lc="$(jq -r '.checksum // empty' "$meta" 2>/dev/null)"
    if [[ "$full" != 1 && -d "$cdir/pkg" && "$lc" == "$sc" && -f "$cdir/pkg/tl.$AGENT_HOST" ]]; then exit 0; fi  # outro já fez
    # INVARIANTE "calibra 1× por máquina": mesmo o full (Calibrar explícito) PULA se uma
    # calibração full DESTE MESMO checksum já satisfaz o pedido — seja porque completou
    # enquanto esperávamos o lock (calibrated_at >= wait_start: N pedidos concorrentes
    # colapsam em 1), seja porque o PEDIDO é mais velho que ela (calibrated_at >= req_epoch:
    # duplicata requentada da fila morre num skip). Checksum NOVO nunca cai aqui (lc != sc
    # ⇒ recalibra); um "Calibrar" deliberado POSTERIOR (pedido novo) recalibra normalmente.
    if [[ "$full" == 1 && -d "$cdir/pkg" && "$lc" == "$sc" && -f "$cdir/pkg/tl.$AGENT_HOST" ]]; then
      local _ca _fl
      _ca="$(jq -r '.calibrated_at // 0' "$meta" 2>/dev/null)"
      _fl="$(jq -r '.full // false' "$meta" 2>/dev/null)"
      if [[ "$_fl" == true && "$_ca" =~ ^[0-9]+$ ]] \
         && { (( _ca >= wait_start )) || { (( req_epoch > 0 )) && (( _ca >= req_epoch )); }; }; then
        alog "calibração full de $id: checksum já calibrado (pedido satisfeito) — pulando duplicata"
        exit 0
      fi
    fi
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
    # STUB do GC: se o TL deste MESMO checksum foi preservado ($cdir/tl.$AGENT_HOST) quando o
    # pkg/ foi removido por idade, restaura e PULA a recalibração (o GC não custa recalibrar).
    if [[ "$full" != 1 && ! -f "$cdir/pkg/tl.$AGENT_HOST" && -f "$cdir/tl.$AGENT_HOST" && "$lc" == "$sc" ]]; then
      cp -f "$cdir/tl.$AGENT_HOST" "$cdir/pkg/tl.$AGENT_HOST" 2>/dev/null
      rm -f "$cdir/tl.$AGENT_HOST"
      report_tl "$id" "$sc" "$cdir/pkg" || alog "report_tl falhou $id"
      local calat; calat="$(jq -r '.calibrated_at // empty' "$meta" 2>/dev/null)"; [[ "$calat" =~ ^[0-9]+$ ]] || calat="$EPOCHSECONDS"
      jq -cn --arg id "$id" --arg c "$sc" --argjson cal "$calat" --argjson now "$EPOCHSECONDS" \
         '{id:$id, checksum:$c, tl_reported:true, calibrated_at:$cal, reported_at:$now}' > "$meta"
      alog "tl restaurado do stub p/ $id (cks=${sc:0:8}; sem recalibrar)"
    else
      # calibra (gera tl.$AGENT_HOST) e reporta. full=1 (Calibrar explícito) roda TODAS as soluções
      # (good/pass/slow/wrong) p/ o log mostrar o comportamento de cada uma; senão só as good
      # (rápido, sob demanda). Robusto a toolchain ausente (pula a linguagem, não aborta).
      # TETO DE WALL-CLOCK dinâmico + kill do GRUPO (timeout vira líder de pgroup e sinaliza o
      # grupo inteiro: calibreitor+build-and-test+bwrap+solução) — calibração presa nunca mais
      # segura um slot p/ sempre (incidente 2026-07-15).
      local _ccap _crc
      _ccap="$(_calib_cap "$cdir/pkg" "$full")"
      if [[ "$full" == 1 ]]; then
        MOJ_PROBLEM_ID="$id" timeout -k 10 "$_ccap" \
          bash "$MOJTOOLS_DIR/calibreitor.sh" "$cdir/pkg" >"$cdir/.calib.log" 2>&1
      else
        MOJ_PROBLEM_ID="$id" CALIBRATE_ONLY_GOOD=1 timeout -k 10 "$_ccap" \
          bash "$MOJTOOLS_DIR/calibreitor.sh" "$cdir/pkg" >"$cdir/.calib.log" 2>&1
      fi
      _crc=$?
      (( _crc == 124 || _crc == 137 )) && {
        echo "### calibração MORTA pelo teto de wall-clock (${_ccap}s) — job preso/infra" >> "$cdir/.calib.log"
        alog "calibração de $id MORTA no teto de ${_ccap}s"; }
      [[ -f "$cdir/pkg/tl.$AGENT_HOST" ]] || { alog "calibração não gerou tl p/ $id (ver $cdir/.calib.log)"; exit 2; }
      rm -f "$cdir/tl.$AGENT_HOST"   # stub de checksum antigo (se havia) não vale mais
      report_tl "$id" "$sc" "$cdir/pkg" || alog "report_tl falhou $id"
      report_calib_log "$id" "$sc" "$cdir/.calib.log" "$cdir/pkg"
      jq -cn --arg id "$id" --arg c "$sc" --argjson now "$EPOCHSECONDS" \
         --argjson fl "$( [[ "$full" == 1 ]] && echo true || echo false )" \
         '{id:$id, checksum:$c, tl_reported:true, calibrated_at:$now, reported_at:$now, full:$fl}' > "$meta"
      alog "cacheado+calibrado $id (cks=${sc:0:8}; teto ${_ccap}s)"
    fi
  ) 9>"$cdir.lock"

  [[ -d "$cdir/pkg" && -f "$cdir/pkg/tl.$AGENT_HOST" ]] || return 1
  echo "$EPOCHSECONDS" > "$cdir/.last-used" 2>/dev/null   # carimbo de USO (o GC decide por ele)
  printf '%s' "$cdir/pkg"
}

# report_cached_tls : ao subir/relançar, re-reporta o TL de todos os problemas do cache
# já calibrados (o MOJ repovoa o TL por host sem recalibrar) — inclusive STUBS do GC
# (pkg/ removido, tl.$AGENT_HOST preservado ao lado do meta).
report_cached_tls() {
  local d id cks tldir n=0
  [[ -d "$JUDGE_CACHE" ]] || return 0
  while IFS= read -r d; do
    [[ -f "$d/.moj-cache.json" ]] || continue
    id="$(jq -r '.id // empty' "$d/.moj-cache.json" 2>/dev/null)"
    cks="$(jq -r '.checksum // empty' "$d/.moj-cache.json" 2>/dev/null)"
    [[ -n "$id" && -n "$cks" ]] || continue
    if [[ -d "$d/pkg" && -f "$d/pkg/tl.$AGENT_HOST" ]]; then tldir="$d/pkg"
    elif [[ -f "$d/tl.$AGENT_HOST" ]]; then tldir="$d"        # stub do GC
    else continue; fi
    report_tl "$id" "$cks" "$tldir" && n=$((n+1))
    # re-envia também o LOG da calibração (sem o pkgdir -> sem os report.html, fica leve) p/ a
    # interface não perder o "ver log" de cada juiz depois que o agente reinicia.
    [[ -f "$d/.calib.log" ]] && report_calib_log "$id" "$cks" "$d/.calib.log"
  done < <(find "$JUDGE_CACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  (( n > 0 )) && alog "re-reportei TL+log de $n problema(s) do cache"
}

# ----------------------------------------------------------------- GC do cache
# Pacote sem USO há AGENT_CACHE_MAX_DAYS vira STUB: o pkg/ (pesado: tests/sols/binários de
# checker) é removido, mas .moj-cache.json + tl.$AGENT_HOST ficam (~KB) — o TL continua sendo
# re-reportado no boot e, no próximo uso com o MESMO checksum, o ensure_cached re-baixa o
# pacote e RESTAURA o TL sem recalibrar. Knobs (agent.env):
#   AGENT_CACHE_MAX_DAYS  idade de uso p/ expirar (default 14; 0 = desliga por idade)
#   AGENT_CACHE_MAX_MB    teto do cache; acima disso evict LRU (default 0 = sem teto)
#   AGENT_CACHE_GC_HOURS  intervalo entre varreduras (default 6)
: "${AGENT_CACHE_MAX_DAYS:=14}"
: "${AGENT_CACHE_MAX_MB:=0}"
: "${AGENT_CACHE_GC_HOURS:=6}"
GC_STAMP="${TMPDIR:-/tmp}/moj-agent-gc.$AGENT_HOST.stamp"

_gc_stub_one() {  # $1=cdir -> 0 se virou stub (preserva tl+meta; remove pkg/)
  local d="$1" id szmb
  [[ -d "$d/pkg" ]] || return 1
  [[ -e "$d/.new" || -e "$d/pkg.tmp" ]] && return 1          # download em curso
  (
    flock -n 9 || exit 1                                      # ensure_cached concorrente
    [[ -d "$d/pkg" ]] || exit 1
    id="$(jq -r '.id // empty' "$d/.moj-cache.json" 2>/dev/null)"
    szmb="$(du -sm "$d/pkg" 2>/dev/null | cut -f1)"
    [[ -f "$d/pkg/tl.$AGENT_HOST" ]] && cp -f "$d/pkg/tl.$AGENT_HOST" "$d/tl.$AGENT_HOST" 2>/dev/null
    rm -rf "$d/pkg" "$d/.calib.log"
    alog "[gc] ${id:-$(basename "$d")}: pkg removido (${szmb:-?}MB; tl preservado no stub)"
  ) 9>"$d.lock"
}

gc_cache() {  # chamado no loop SÓ com BUSYPID==0 (nenhum julgamento em curso); throttle por stamp
  local now="$EPOCHSECONDS" last=0
  [[ -f "$GC_STAMP" ]] && last="$(cat "$GC_STAMP" 2>/dev/null)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( now - last < AGENT_CACHE_GC_HOURS*3600 )) && return 0
  echo "$now" > "$GC_STAMP" 2>/dev/null
  local d used cut n=0
  # 1) por idade de uso (.last-used; fallback: mtime do meta = época do download/calibração)
  if (( AGENT_CACHE_MAX_DAYS > 0 )); then
    cut=$(( now - AGENT_CACHE_MAX_DAYS*86400 ))
    while IFS= read -r d; do
      [[ -d "$d/pkg" ]] || continue
      used="$(cat "$d/.last-used" 2>/dev/null)"
      [[ "$used" =~ ^[0-9]+$ ]] || used="$(stat -c %Y "$d/.moj-cache.json" 2>/dev/null)"
      [[ "$used" =~ ^[0-9]+$ ]] || used="$now"
      (( used < cut )) && _gc_stub_one "$d" && n=$((n+1))
    done < <(find "$JUDGE_CACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  fi
  # 2) teto de tamanho: evict LRU (mais antigo .last-used primeiro) até caber
  if (( AGENT_CACHE_MAX_MB > 0 )); then
    local total szmb u
    total="$(du -sm "$JUDGE_CACHE" 2>/dev/null | cut -f1)"; [[ "$total" =~ ^[0-9]+$ ]] || total=0
    if (( total > AGENT_CACHE_MAX_MB )); then
      while IFS=$'\t' read -r u d; do
        (( total <= AGENT_CACHE_MAX_MB )) && break
        [[ -d "$d/pkg" ]] || continue
        szmb="$(du -sm "$d/pkg" 2>/dev/null | cut -f1)"; [[ "$szmb" =~ ^[0-9]+$ ]] || szmb=0
        _gc_stub_one "$d" && { total=$((total-szmb)); n=$((n+1)); }
      done < <(while IFS= read -r d; do
                 u="$(cat "$d/.last-used" 2>/dev/null)"; [[ "$u" =~ ^[0-9]+$ ]] || u=0
                 printf '%s\t%s\n' "$u" "$d"
               done < <(find "$JUDGE_CACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null) | sort -n)
    fi
  fi
  (( n > 0 )) && { alog "[gc] $n pacote(s) viraram stub"; register; }
  return 0
}

INVHASH=""
register() {  # [boot=1] — boot:true faz o servidor RE-ENFILEIRAR o que estava atribuído a este
  # host (restart devolve o trabalho em voo NA HORA, sem esperar TTL) e devolver a config vigente
  # (adotada antes do 1º heartbeat). REG_RESP guarda a resposta p/ o boot ler.
  local boot="${1:-0}" specs problems langs body
  specs="$(agent_specs_json)"; problems="$(agent_problems_json)"; langs="$(agent_langs_json)"
  INVHASH="$(agent_inv_hash "$problems")"
  local cbytes; cbytes="$(du -sb "$JUDGE_CACHE" 2>/dev/null | cut -f1)"; [[ "$cbytes" =~ ^[0-9]+$ ]] || cbytes=0
  # capability 'gpu' exige GPU de COMPUTE comprovada (nvidia-smi/rocm-smi respondendo);
  # sem ela registra como 'pos' — job com need_capability=gpu nunca cai em host cego.
  local cap="$CAPABILITY"
  if [[ "$cap" == gpu && "$(jq -c '.gpu // null' <<<"$specs")" == null ]]; then
    alog "CAPABILITY=gpu mas nenhuma GPU de compute detectada (nvidia-smi/rocm-smi) — registrando como pos"
    cap=pos
  fi
  local bootj=false; [[ "$boot" == 1 ]] && bootj=true
  body="$(jq -cn --arg host "$AGENT_HOST" --arg cap "$cap" \
    --argjson specs "$specs" --argjson problems "$problems" --argjson langs "$langs" \
    --arg cage "${CAGE_ROOT:-}" --argjson cb "$cbytes" --arg ih "$INVHASH" \
    --argjson ts "${N_SLOTS:-1}" --arg part "${CFG_PARTITION:-off}" \
    --argjson topo "$(agent_topology_json)" --argjson boot "$bootj" \
    '$specs + {host:$host, capability:$cap, problems:$problems, langs:$langs,
               cage_root:(if $cage=="" then null else $cage end),
               cache_bytes:$cb, inv_hash:$ih,
               total_slots:$ts, partition:$part, topology:$topo, boot:$boot}')"
  if REG_RESP="$(_api /judge/register "$body")"; then
    alog "registrado ($(jq -r 'length' <<<"$problems") problemas, $(jq -r 'length' <<<"$langs") linguagens, inv=$INVHASH)"
  else
    REG_RESP=""; alog "falha ao registrar"
  fi
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
       verdict_canon:"Judge Error",
       score:0,score_max:0,score_kind:"tests",correct:0,total_tests:0,duration_s:0,tl_used:null,tests:[],report_html_b64:null}')" >/dev/null
}

run_job() {  # $1 = job JSON  $2 = cpuset do slot ("" = sem pin)  (bg; faz o próprio POST de result)
  local job="$1" cpuset="${2:-}" id contest problem login lang filename code_b64
  export TMPDIR   # TMPDIR do JOB (setado no claim): scratch isolado por slot, herda p/ tudo
  # pina ESTE subshell ao cpuset do slot: a afinidade herda p/ TUDO que o job forkar
  # (ensure_cached/calibreitor, build-and-test, bwrap, compilador, solução)
  [[ -n "$cpuset" ]] && taskset -pc "$cpuset" $BASHPID >/dev/null 2>&1
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

  local out wb verdict jcap jrc
  # MOJ_PROBLEM_ID: id real do problema p/ o report (o pacote no cache é <id>/pkg) + ativa a
  # coleta do toolchain no build-and-test (só p/ submissão real, não na calibração).
  # TETO DE WALL-CLOCK dinâmico (TL×testes×2 + compile + folga) com kill do GRUPO: um job
  # preso em infra/sandbox morre sozinho e o slot reporta Judge Error — nunca entope o juiz.
  jcap="$(_job_cap "$pkg" "$lang")"
  out="$(MOJ_PROBLEM_ID="$problem" timeout -k 10 "$jcap" bash "$BAT" "$lang" "$src" "$pkg" y 2>/dev/null)"
  jrc=$?
  wb="$(printf '%s\n' "$out" | head -n1)"
  verdict="$(printf '%s\n' "$out" | tail -n1)"
  if (( jrc == 124 || jrc == 137 )); then
    verdict="Judge Error (teto de wall-clock do job: ${jcap}s)"
    alog "job id=$id MORTO no teto de ${jcap}s (problema $problem)"
  fi
  [[ -n "$verdict" ]] || verdict="Judge Error (no verdict)"

  local CORRECT=0 TOTALTESTS=0 TOTALTIME=0 FINALRESP="$verdict" TL_LANG=""
  local VERDICT_CANON="" SCORE="" SCORE_MAX=100 SCORE_KIND=tests SCORE_GROUPS=""
  [[ -f "$wb/report.env" ]] && source "$wb/report.env" 2>/dev/null
  local tests score vcanon smax skind groups
  tests="$(agent_tests_json "$wb" "$TL_LANG")"
  # canônico p/ casar o auto-veredicto (fallback: tira o sufixo ,Np do verdict); score do report.env
  # (corrige subtarefas, onde o regex [0-9]+p$ falhava) com fallback p/ o regex no FINALRESP.
  vcanon="${VERDICT_CANON:-${verdict%%,*}}"
  (( jrc == 124 || jrc == 137 )) && vcanon="Judge Error"   # canônico limpo p/ o daemon segurar
  score="${SCORE:-$(printf '%s' "$FINALRESP" | grep -oE '[0-9]+p$' | tr -d p)}"
  [[ "$score" =~ ^-?[0-9]+$ ]] || score=0
  smax="${SCORE_MAX:-100}"; [[ "$smax" =~ ^[0-9]+$ ]] || smax=100
  skind="${SCORE_KIND:-tests}"
  # grupos estruturados (subtarefas) do report.env; só repassa se for JSON array válido
  groups=null
  [[ -n "$SCORE_GROUPS" ]] && jq -e 'type=="array"' <<<"$SCORE_GROUPS" >/dev/null 2>&1 && groups="$SCORE_GROUPS"

  # corpo num ARQUIVO: o report.html (grande) entra por --rawfile (lido do arquivo) e vira base64
  # dentro do jq — nunca por argv (>128KB estoura MAX_ARG_STRLEN e o result se perdia).
  local bf htmlf; bf="$(mktemp)"; htmlf=/dev/null; [[ -f "$wb/report.html" ]] && htmlf="$wb/report.html"
  jq -cn \
    --arg host "$AGENT_HOST" --arg id "$id" --arg c "$contest" --arg p "$problem" \
    --arg login "$login" --arg lang "$lang" --arg v "$verdict" --arg vcanon "$vcanon" \
    --argjson score "${score:-0}" --argjson smax "${smax:-100}" --arg skind "$skind" \
    --argjson correct "${CORRECT:-0}" \
    --argjson total "${TOTALTESTS:-0}" --argjson dur "${TOTALTIME:-0}" \
    --arg tl "$TL_LANG" --argjson tests "$tests" --argjson groups "$groups" --rawfile html "$htmlf" \
    '{host:$host, id:$id, contest:$c, problem_id:$p, login:$login, lang:$lang,
      verdict:$v, verdict_canon:$vcanon, score:$score, score_max:$smax, score_kind:$skind,
      correct:$correct, total_tests:$total, duration_s:$dur,
      tl_used:($tl|tonumber? // null), tests:$tests,
      report_html_b64:(if ($html|length)==0 then null else ($html|@base64) end)}
     + (if $groups == null then {} else {groups:$groups} end)' > "$bf" 2>/dev/null
  if [[ -s "$bf" ]] && _api_file /judge/result "$bf"; then alog "result enviado id=$id verdict=$verdict"
  else alog "FALHA ao enviar result id=$id"; fi
  rm -f "$bf"; rm -rf "$work" "$wb" 2>/dev/null
}

run_update() {  # $1 = request JSON  $2 = cpuset do slot ("" = sem pin)  (bg; POST de report)
  local upd="$1" cpuset="${2:-}" reqid repo kind target logf rc okj problems pc
  export TMPDIR   # TMPDIR do JOB (setado no claim): scratch isolado por slot
  [[ -n "$cpuset" ]] && taskset -pc "$cpuset" $BASHPID >/dev/null 2>&1   # calibração nas MESMAS condições do julgamento
  reqid="$(jq -r '.reqid // empty' <<<"$upd")"
  repo="$(jq -r '.repo // ""' <<<"$upd")"
  kind="$(jq -r '.kind // "calibrate"' <<<"$upd")"
  target="$(jq -r '.target // ""' <<<"$upd")"
  logf="$(mktemp)"; rc=0
  case "$kind" in
    calibrate)   # Calibrar explícito: roda TODAS as soluções (full=1) e reporta TL + log.
      # requested_at do pedido: duplicata mais velha que a última full do mesmo checksum = skip
      if [[ -n "$target" ]]; then
        local _req; _req="$(jq -r '.requested_at // 0' <<<"$upd" 2>/dev/null)"
        ensure_cached "$target" 1 1 "$_req" >/dev/null 2>"$logf"; rc=$?
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
  # log b64 + corpo em ARQUIVO -> --rawfile + _api_file: log grande estourava o ARG_MAX (no --arg
  # do build E no --data do POST) e o report sumia em silêncio.
  local lb64 urbody; lb64="$(mktemp)"; urbody="$(mktemp)"
  base64 -w0 < "$logf" | tr -d '\n' > "$lb64"
  jq -cn --arg host "$AGENT_HOST" --arg reqid "$reqid" \
    --arg repo "$repo" --arg kind "$kind" --arg target "$target" --argjson ok "$okj" \
    --rawfile log "$lb64" --argjson pc "${pc:-0}" --argjson val null \
    '{host:$host, reqid:$reqid, repo:$repo, kind:$kind, target:$target, ok:$ok,
      log_b64:$log, problems_count:$pc, validation:$val}' > "$urbody"
  _api_file /judge/update-report "$urbody" >/dev/null \
    && alog "report enviado reqid=$reqid kind=$kind ok=$okj" || alog "FALHA report reqid=$reqid"
  rm -f "$logf" "$lb64" "$urbody"
  register   # re-registra o inventário atualizado (e volta a free)
}

# comando por-host vindo do admin (heartbeat). clearcache é EXCLUSIVO (o loop só o executa
# com todos os slots drenados); calibrate roda num slot como um job (pinado).
run_command() {  # $1 = command JSON {cmdid, action, ...}  $2 = cpuset do slot ("" = sem pin)
  local c="$1" cpuset="${2:-}" action; action="$(jq -r '.action // empty' <<<"$c" 2>/dev/null)"
  export TMPDIR   # TMPDIR do JOB (setado no claim): scratch isolado por slot
  [[ -n "$cpuset" ]] && taskset -pc "$cpuset" $BASHPID >/dev/null 2>&1
  case "$action" in
    clearcache)
      alog "comando do admin: limpar cache ($JUDGE_CACHE)"
      pkill -f calibreitor.sh 2>/dev/null
      [[ -n "$JUDGE_CACHE" ]] && rm -rf "${JUDGE_CACHE:?}/"* 2>/dev/null
      register   # inventário agora vazio -> o MOJ vê o cache limpo
      ;;
    calibrate)   # calibração DIRECIONADA a este host (full): baixa/recalibra e reporta
      local target creq; target="$(jq -r '.id // empty' <<<"$c" 2>/dev/null)"
      creq="$(jq -r '.at // 0' <<<"$c" 2>/dev/null)"
      if [[ -n "$target" ]]; then
        alog "comando: calibrar $target (full) neste host${cpuset:+ [cpus $cpuset]}"
        ensure_cached "$target" 1 1 "$creq" >/dev/null 2>&1 && alog "calibrado $target" || alog "calibrate $target falhou"
      else alog "comando calibrate sem id"; fi
      ;;
    *) alog "comando desconhecido: ${action:-<vazio>}" ;;
  esac
}

# ----------------------------------------------------------------- slots (particionamento)
# A máquina pode ser PARTICIONADA em N slots de cpus DISJUNTAS e corrigir N problemas ao
# mesmo tempo, cada job PINADO no seu cpuset (taskset herda p/ bwrap/compilador/solução; o
# nproc dentro da fatia limita sozinho o paralelismo interno de testes; a calibração roda
# pinada nas MESMAS condições). Config por juiz vem do SERVIDOR via heartbeat
# ({config:{partition,reserve,disabled}, cfg_hash}) e vence o fallback local
# AGENT_PARTITION/AGENT_RESERVE do agent.env. partition: off | numa | cpus:<X>.
: "${AGENT_PARTITION:=off}"
: "${AGENT_RESERVE:=0}"
# SLOT_TMP  = TMPDIR do job em voo (removido no reap); SLOT_KIND/SLOT_META = o que roda no slot
# (job|update|command + JSON mínimo SEM code_b64) p/ reportar ao servidor se o job for MORTO.
declare -a SLOT_CPUS=() SLOT_PID=() SLOT_TMP=() SLOT_KIND=() SLOT_META=()
CFG_PARTITION="$AGENT_PARTITION" CFG_RESERVE="$AGENT_RESERVE" CFG_DISABLED=false
AGENT_CFG_HASH=""    # hash da config aplicada (o servidor reenvia quando muda)
PENDING_CFG=""       # config nova aguardando DRENAGEM dos slots p/ aplicar
PENDING_CMD=""       # comando exclusivo (clearcache) aguardando drenagem
REG_RESP=""          # última resposta do /judge/register (boot adota .config dela)

# _save_state / _load_state : persiste a config APLICADA (P6) — restart re-adota o que rodava,
# não o agent.env (que make config regrava; foi a divergência que wedgeou o restart no incidente).
_save_state() {
  local d r tmp="$AGENT_STATE.tmp.$$"
  d=false; [[ "$CFG_DISABLED" == true ]] && d=true
  r="$CFG_RESERVE"; [[ "$r" =~ ^[0-9]+$ ]] || r=0
  jq -cn --arg p "$CFG_PARTITION" --argjson r "$r" --argjson d "$d" \
     --arg h "$AGENT_CFG_HASH" --argjson now "$EPOCHSECONDS" \
     '{partition:$p, reserve:$r, disabled:$d, cfg_hash:$h, at:$now}' > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$AGENT_STATE"
}
_load_state() {
  [[ -f "$AGENT_STATE" ]] || return 1
  CFG_PARTITION="$(jq -r '.partition // "off"' "$AGENT_STATE" 2>/dev/null)"
  CFG_RESERVE="$(jq -r '.reserve // 0' "$AGENT_STATE" 2>/dev/null)"
  CFG_DISABLED="$(jq -r '.disabled // false' "$AGENT_STATE" 2>/dev/null)"
  AGENT_CFG_HASH="$(jq -r '.cfg_hash // ""' "$AGENT_STATE" 2>/dev/null)"
  [[ -n "$CFG_PARTITION" ]] || CFG_PARTITION=off
  alog "config persistida adotada: partition=$CFG_PARTITION reserve=$CFG_RESERVE disabled=$CFG_DISABLED"
}

_cpus_expand() {  # "0-3,8,10-11" -> "0 1 2 3 8 10 11"
  local part a b i out=() _parts
  IFS=',' read -ra _parts <<<"$1"
  for part in "${_parts[@]}"; do
    if [[ "$part" == *-* ]]; then a="${part%-*}"; b="${part#*-}"; for ((i=a; i<=b; i++)); do out+=("$i"); done
    else out+=("$part"); fi
  done
  printf '%s ' "${out[@]}"
}

# build_slots <partition> <reserve> -> popula SLOT_CPUS/SLOT_PID. off = 1 slot sem pin.
build_slots() {
  local mode="${1:-off}" reserve="${2:-0}"
  [[ "$reserve" =~ ^[0-9]+$ ]] || reserve=0
  SLOT_CPUS=(); SLOT_PID=(); SLOT_TMP=(); SLOT_KIND=(); SLOT_META=()
  case "$mode" in
    numa)
      local n cl cpus
      for n in /sys/devices/system/node/node[0-9]*; do
        [[ -f "$n/cpulist" ]] || continue
        # reserve tira as N primeiras cpus DO HOST (só afeta o node que as contém)
        read -ra cpus <<<"$(_cpus_expand "$(<"$n/cpulist")")"
        local kept=() c
        for c in "${cpus[@]}"; do (( c >= reserve )) && kept+=("$c"); done
        (( ${#kept[@]} > 0 )) && { SLOT_CPUS+=("$(IFS=,; echo "${kept[*]}")"); SLOT_PID+=(0); }
      done
      ;;
    cpus:*)
      local X="${mode#cpus:}" all=() c i=0 chunk=()
      [[ "$X" =~ ^[0-9]+$ && "$X" -ge 1 ]] || { alog "partition '$mode' inválida — usando off"; X=0; }
      if (( X >= 1 )); then
        read -ra all <<<"$(_cpus_expand "$(</sys/devices/system/cpu/online)")"
        for c in "${all[@]}"; do
          (( c < reserve )) && continue
          chunk+=("$c")
          if (( ${#chunk[@]} == X )); then SLOT_CPUS+=("$(IFS=,; echo "${chunk[*]}")"); SLOT_PID+=(0); chunk=(); fi
        done
        # resto (< X cpus) fica FORA dos slots (fatias uniformes p/ timing consistente)
      fi
      ;;
  esac
  if (( ${#SLOT_CPUS[@]} == 0 )); then SLOT_CPUS=(""); SLOT_PID=(0); fi   # off/fallback: 1 slot, sem pin
  # modo ROOT é single-slot only: cset/cgroup do cage-run são estado GLOBAL da máquina
  # (ver mojtools/SANDBOX.md) — multi-slot como root compartilharia shield/limites entre jobs.
  if (( EUID == 0 )) && (( ${#SLOT_CPUS[@]} > 1 )); then
    alog "ATENÇÃO: agente como ROOT com ${#SLOT_CPUS[@]} slots — modo root é single-slot only; FORÇANDO 1 slot"
    SLOT_CPUS=(""); SLOT_PID=(0); SLOT_TMP=(); SLOT_KIND=(); SLOT_META=()
  fi
  N_SLOTS=${#SLOT_CPUS[@]}
  alog "slots: $N_SLOTS (partition=$mode reserve=$reserve)$( ((N_SLOTS>1)) && printf ' cpusets: %s' "${SLOT_CPUS[*]}" )"
}

# aplica a config pendente (chamar SÓ com todos os slots livres)
apply_config() {
  local cfg="$1"
  CFG_PARTITION="$(jq -r '.partition // "off"' <<<"$cfg" 2>/dev/null)"
  CFG_RESERVE="$(jq -r '.reserve // 0' <<<"$cfg" 2>/dev/null)"
  CFG_DISABLED="$(jq -r '.disabled // false' <<<"$cfg" 2>/dev/null)"
  AGENT_CFG_HASH="$(jq -r '.cfg_hash // ""' <<<"$cfg" 2>/dev/null)"
  build_slots "$CFG_PARTITION" "$CFG_RESERVE"
  _save_state   # P6: a config APLICADA é a fonte da verdade do próximo boot
  [[ "$CFG_DISABLED" == true ]] && alog "config: juiz DESABILITADO pelo admin (drenado; segue batendo heartbeat)"
  register
}

# _report_slot_killed <slot> <motivo> : fecha NO SERVIDOR o trabalho de um slot morto —
# job vira Judge Error na hora (q_done imediato) e calibração fecha o pending via
# update-report ok=false (nada espera ASSIGN_TTL/UPD_TTL).
_report_slot_killed() {
  local i="$1" why="$2" kind="${SLOT_KIND[i]:-}" meta="${SLOT_META[i]:-}"
  [[ -n "$meta" ]] || { SLOT_KIND[i]=""; return 0; }
  case "$kind" in
    job)
      _post_judge_error "$(jq -r '.id // ""' <<<"$meta")" "$(jq -r '.contest // ""' <<<"$meta")" \
        "$(jq -r '.problem_id // ""' <<<"$meta")" "$(jq -r '.login // ""' <<<"$meta")" \
        "$(jq -r '.lang // ""' <<<"$meta")" "Judge Error ($why)" ;;
    update)
      _api /judge/update-report "$(jq -cn --arg host "$AGENT_HOST" --argjson m "$meta" --arg w "$why" \
        '{host:$host, reqid:($m.reqid // ""), repo:($m.repo // ""), kind:($m.kind // "calibrate"),
          target:($m.target // ""), ok:false, log_b64:($w|@base64), problems_count:0, validation:null}')" >/dev/null ;;
  esac
  SLOT_KIND[i]=""; SLOT_META[i]=""
}

# agent_slots_kill <motivo> : SIGKILL no GRUPO de processos de cada slot ocupado (job inteiro:
# build-and-test+bwrap+solução), reporta ao servidor e limpa o TMPDIR do job. É a ferramenta
# de recuperação do `moj judges reset` — o que faltou no incidente 2026-07-15.
agent_slots_kill() {
  local why="${1:-morto pelo agente}" i pid n=0
  for i in "${!SLOT_PID[@]}"; do
    pid="${SLOT_PID[i]:-0}"; (( pid != 0 )) || continue
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    _report_slot_killed "$i" "$why"
    SLOT_PID[i]=0
    [[ -n "${SLOT_TMP[i]:-}" ]] && rm -rf "${SLOT_TMP[i]}" 2>/dev/null; SLOT_TMP[i]=""
    n=$((n+1))
  done
  (( n > 0 )) && alog "$n slot(s) morto(s): $why"
  return 0
}

# ----------------------------------------------------------------- loop principal
# _free_slot -> ecoa o índice do primeiro slot livre (rc 1 se nenhum)
_free_slot() { local i; for i in "${!SLOT_PID[@]}"; do (( SLOT_PID[i] == 0 )) && { echo "$i"; return 0; }; done; return 1; }

moj_agent_main() {
# instância ÚNICA por host: um flock evita agentes DUPLICADOS (brigam por jobs e gastam forks).
exec 8>"${AGENT_LOCK:-/tmp/moj-agent.$AGENT_HOST.lock}"
flock -n 8 || { alog "já há um agente rodando em $AGENT_HOST (lock ${AGENT_LOCK:-/tmp/moj-agent.$AGENT_HOST.lock}) — saindo"; exit 0; }   # ${:-}: sob set -u, $AGENT_LOCK cru CRASHAVA a instância duplicada em vez de sair limpo
# host desabilitado (ex.: nproc baixo demais p/ a jaula): não vira juiz. `touch ~/.moj-agent-disabled`
[[ -f "${AGENT_DISABLED:-$HOME/.moj-agent-disabled}" ]] && { alog "agente DESABILITADO neste host (${AGENT_DISABLED:-$HOME/.moj-agent-disabled}) — saindo"; exit 0; }
ulimit -u "$(ulimit -Hu)" 2>/dev/null || true   # folga de processos: N slots × (bwrap+time+timeout+compilador)
alog "subindo: host=$AGENT_HOST cap=$CAPABILITY api=$MOJ_API cache=$JUDGE_CACHE hb=${HEARTBEAT_SECS}s ulimit-u=$(ulimit -u)"
# JOB CONTROL: cada `run_* &` vira seu PRÓPRIO grupo de processos (pgid=pid) — é o que permite
# matar um job INTEIRO (subshell+build-and-test+bwrap+solução) com kill -- -pid, sem órfãos.
set -m
# TERM/INT: mata os grupos dos slots antes de sair — restart nunca deixa netos rodando (que
# além de gastar cpu SEGURAVAM o flock de instância herdado e travavam o agente novo).
trap 'agent_slots_kill "agente encerrando (TERM/INT)"; exit 143' TERM INT
ensure_rootfs        # jaula no rootfs reprodutível (não no host)
# TMPDIR por job: zera a base no boot (nenhum job sobrevive a restart; lixo não acumula)
rm -rf "$AGENT_WORK" 2>/dev/null; mkdir -p "$AGENT_WORK" 2>/dev/null
# ordem de precedência da config no BOOT (P5/P6): 1) config do SERVIDOR (resposta do register
# boot:true); 2) estado PERSISTIDO da última aplicada (agent-state.json); 3) agent.env.
_load_state || true
build_slots "$CFG_PARTITION" "$CFG_RESERVE"
register 1   # boot:true => servidor re-enfileira o que estava atribuído a este host + manda config
local bootcfg bch
bootcfg="$(jq -c '.config // empty' <<<"${REG_RESP:-}" 2>/dev/null)"
if [[ -n "$bootcfg" && "$bootcfg" != null ]]; then
  bch="$(jq -r '.cfg_hash // ""' <<<"$bootcfg" 2>/dev/null)"
  if [[ -n "$bch" && "$bch" != "$AGENT_CFG_HASH" ]]; then
    alog "config do servidor difere da persistida — adotando no boot (tudo livre)"
    apply_config "$bootcfg"
  fi
fi
# relançamento: reenvia os TLs já calibrados (sem recalibrar) — em BACKGROUND: com um cache
# grande (centenas de problemas) isso leva minutos e segurava o loop (juiz cego p/ jobs/config)
report_cached_tls 8>&- &
local free i n state hstatus resp cfg cmd upd jobs job jt uact
while true; do
  # reap por slot + contagem de livres (+ limpeza do TMPDIR do job que terminou)
  free=0
  for i in "${!SLOT_PID[@]}"; do
    if (( SLOT_PID[i] != 0 )) && ! kill -0 "${SLOT_PID[i]}" 2>/dev/null; then
      SLOT_PID[i]=0; SLOT_KIND[i]=""; SLOT_META[i]=""
      [[ -n "${SLOT_TMP[i]:-}" ]] && rm -rf "${SLOT_TMP[i]}" 2>/dev/null; SLOT_TMP[i]=""
    fi
    (( SLOT_PID[i] == 0 )) && free=$((free+1))
  done

  # DRENADO (todos livres): aplica config pendente, executa comando exclusivo, roda o GC
  if (( free == N_SLOTS )); then
    if [[ -n "$PENDING_CMD" ]]; then run_command "$PENDING_CMD"; PENDING_CMD=""; fi
    if [[ -n "$PENDING_CFG" ]]; then apply_config "$PENDING_CFG"; PENDING_CFG=""
      free=$N_SLOTS   # slots recém-reconstruídos, todos livres
    fi
    [[ -z "$PENDING_CMD" && -z "$PENDING_CFG" ]] && gc_cache
  fi

  # enquanto drena (config/comando pendente) ou desabilitado: não reivindica (free_slots=0)
  local claimable=$free
  { [[ -n "$PENDING_CFG" || -n "$PENDING_CMD" || "$CFG_DISABLED" == true ]]; } && claimable=0
  state=busy; (( claimable > 0 )) && state=free
  # status HONESTO: o servidor/UI distinguem "drenando/desabilitado" de "rodando job" —
  # antes ambos eram só state=busy e viravam o "unknown_busy" indecifrável do incidente.
  hstatus=ok
  [[ -n "$PENDING_CFG" || -n "$PENDING_CMD" ]] && hstatus=draining
  [[ "$CFG_DISABLED" == true ]] && hstatus=disabled

  resp="$(_api /judge/heartbeat \
    "$(jq -cn --arg h "$AGENT_HOST" --arg s "$state" --arg ih "$INVHASH" --arg ch "$AGENT_CFG_HASH" \
       --argjson fs "$claimable" --argjson ts "$N_SLOTS" --arg st "$hstatus" \
       '{host:$h, state:$s, inv_hash:$ih, cfg_hash:$ch, free_slots:$fs, total_slots:$ts, status:$st}')")"
  if [[ -n "$resp" ]]; then
    [[ "$(jq -r '.reregister // false' <<<"$resp" 2>/dev/null)" == true ]] && register
    cmd="$(jq -c '.command // empty' <<<"$resp" 2>/dev/null)"
    # comando URGENTE (kill/restart): o servidor o entrega MESMO ocupado/drenando — é a
    # recuperação sem SSH (`moj judges reset/restart`) que faltou no incidente 2026-07-15.
    if [[ -n "$cmd" && "$cmd" != null ]]; then
      uact="$(jq -r '.action // ""' <<<"$cmd" 2>/dev/null)"
      case "$uact" in
        kill)
          alog "comando URGENTE do admin: kill (reset) — matando todos os slots"
          agent_slots_kill "morto por 'moj judges reset' (admin)"
          free=$N_SLOTS
          if [[ -n "$PENDING_CFG" ]]; then apply_config "$PENDING_CFG"; PENDING_CFG=""; fi
          PENDING_CMD=""; register; cmd=""
          ;;
        restart)
          alog "comando URGENTE do admin: restart — matando slots e re-executando o agente"
          agent_slots_kill "morto por 'moj judges restart' (admin)"
          rm -f "$AUTH_CFG"
          exec bash "$SELF/moj-agent.sh"
          ;;
      esac
    fi
    # config nova do admin: agenda e DRENA (aplica quando todos os slots esvaziarem; com o teto
    # dinâmico + kill, a drenagem SEMPRE converge — não existe mais drain eterno)
    cfg="$(jq -c '.config // empty' <<<"$resp" 2>/dev/null)"
    if [[ -n "$cfg" && "$cfg" != null ]]; then
      PENDING_CFG="$cfg"
      alog "config nova do servidor ($(jq -c 'del(.cfg_hash)' <<<"$cfg" 2>/dev/null)) — drenando slots p/ aplicar"
    fi
    if (( claimable > 0 )) && [[ -z "$PENDING_CFG" ]]; then
      upd="$(jq -c '.update // empty' <<<"$resp" 2>/dev/null)"
      if [[ -n "$cmd" && "$cmd" != null ]]; then
        if [[ "$(jq -r '.action // ""' <<<"$cmd")" == clearcache ]]; then
          PENDING_CMD="$cmd"; alog "clearcache agendado — drenando slots p/ executar"
        else
          i="$(_free_slot)" && { jt="$AGENT_WORK/s$i.$EPOCHSECONDS.$RANDOM"; mkdir -p "$jt"
            TMPDIR="$jt" run_command "$cmd" "${SLOT_CPUS[i]}" 8>&- & SLOT_PID[i]=$!
            SLOT_TMP[i]="$jt"; SLOT_KIND[i]=command; SLOT_META[i]=""
            alog "comando reivindicado $(jq -r '.action // .cmdid' <<<"$cmd" 2>/dev/null) -> slot $i pid ${SLOT_PID[i]}"; }
        fi
      elif [[ -n "$upd" && "$upd" != null ]]; then
        i="$(_free_slot)" && { jt="$AGENT_WORK/s$i.$EPOCHSECONDS.$RANDOM"; mkdir -p "$jt"
          TMPDIR="$jt" run_update "$upd" "${SLOT_CPUS[i]}" 8>&- & SLOT_PID[i]=$!
          SLOT_TMP[i]="$jt"; SLOT_KIND[i]=update
          SLOT_META[i]="$(jq -c '{reqid,repo,kind,target}' <<<"$upd" 2>/dev/null)"
          alog "update reivindicado reqid=$(jq -r '.reqid' <<<"$upd" 2>/dev/null) -> slot $i pid ${SLOT_PID[i]}"; }
      else
        # LOTE: o servidor devolve assigned como array (até free_slots) ou escalar (legado)
        jobs="$(jq -c '(.assigned // empty) | if type=="array" then .[] else . end' <<<"$resp" 2>/dev/null)"
        while IFS= read -r job; do
          [[ -n "$job" && "$job" != null ]] || continue
          i="$(_free_slot)" || break
          jt="$AGENT_WORK/s$i.$EPOCHSECONDS.$RANDOM"; mkdir -p "$jt"
          TMPDIR="$jt" run_job "$job" "${SLOT_CPUS[i]}" 8>&- & SLOT_PID[i]=$!
          SLOT_TMP[i]="$jt"; SLOT_KIND[i]=job
          SLOT_META[i]="$(jq -c '{id,contest,problem_id,login,lang}' <<<"$job" 2>/dev/null)"
          alog "job reivindicado id=$(jq -r '.id' <<<"$job" 2>/dev/null) -> slot $i${SLOT_CPUS[i]:+ [cpus ${SLOT_CPUS[i]}]} pid ${SLOT_PID[i]}"
        done <<<"$jobs"
      fi
    fi
  fi
  sleep "$HEARTBEAT_SECS"
done
}

# executado direto -> roda o loop; "sourced" (testes) -> só expõe as funções.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && moj_agent_main
