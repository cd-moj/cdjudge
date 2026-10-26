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
# e reruns de TLE. QUEM IMPÕE é o laço principal (`_reap_slots`): o subshell do slot grava o
# epoch-limite da fase corrente em `$TMPDIR/.deadline` (`_slot_deadline`) e o laço mata a ÁRVORE
# inteira (`_kill_tree`) e reporta Judge Error/calib-fail quando passa. Antes era um `timeout`
# em volta do build-and-test/calibreitor — e o `timeout` abre um GRUPO de processos próprio, que
# o `kill -- -pgid` do reset/restart NÃO alcançava: o job "morto" seguia rodando nas CPUs que o
# slot seguinte recebia (24/09/2026). Fallback fixo só quando o pacote não dá p/ estimar.
# AGENT_LOCK_WAIT limita a espera no flock por-problema (fila atrás de calibração).
: "${AGENT_HARD_TL_FALLBACK:=1800}"
: "${AGENT_LOCK_WAIT:=3600}"
# RAIAS DA CALIBRAÇÃO (26/10/2026): o servidor dá à calibração `par_max` grupos de CPU quando há slot livre e fila
# vazia, e o calibreitor roda as soluções do mesmo tipo em paralelo, uma por grupo. 0 = desliga aqui (a calibração
# volta a 1 grupo; o calibreitor também recebe MOJ_CALIB_LANES=0, inclusive a disparada por um job).
: "${AGENT_CALIB_LANES:=1}"
# REPORTS DA CALIBRAÇÃO (26/10/2026): o report.html de CADA solução vai ao servidor até AGENT_REPORTS_MAX_BYTES no
# total (6 MB = o pior caso do teto antigo, 12 × 500 KB) e AGENT_REPORT_MAX_BYTES por arquivo; o que fica de fora
# sai no log. O teto era 12 POR CONTAGEM: o olamundo (15 soluções de 8,5 KB) perdia os 3 últimos em ordem
# alfabética (a .pas, a .rs e a slow) e o editor ficava sem o link do report deles.
: "${AGENT_REPORT_MAX_BYTES:=500000}"
: "${AGENT_REPORTS_MAX_BYTES:=6000000}"
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

# _api_ex <timeout> <path> <args do corpo p/ o curl…> : POST que LÊ o código HTTP — corpo em _API_BODY, código em
# _API_CODE (000 = sem resposta); rc 0 só em 2xx. Re-tenta (3×, 2 s entre elas) só o que pode passar na próxima:
# sem resposta, 408, 409 (`busy`: o lock do servidor não veio a tempo), 429 e 5xx. Outro 4xx é a resposta
# definitiva — antes todo erro era repetido, e o 404 `problem_gone` de cada problema apagado do cache custava 4 s
# no re-report do boot (26/10/2026). Chame FORA de `$(…)` p/ ler _API_CODE/_API_BODY.
_api_ex() {
  local i out
  for i in 1 2 3; do
    out="$(curl -sS -m "$1" "${_HH[@]}" "${_AUTH[@]}" -H 'Content-Type: application/json' "${@:3}" \
      -w '\n%{http_code}' "$MOJ_API$2" 2>/dev/null)"
    _API_CODE="${out##*$'\n'}"; _API_BODY="${out%$'\n'*}"
    [[ "$_API_CODE" =~ ^[0-9]{3}$ ]] || { _API_CODE=000; _API_BODY=""; }
    [[ "$_API_CODE" == 2?? ]] && return 0
    [[ "$_API_CODE" =~ ^(000|408|409|429|5[0-9][0-9])$ ]] || return 1
    (( i < 3 )) && sleep 2
  done
  return 1
}
# _api_gone : o último _api_ex foi o 404 `problem_gone` (o pacote não existe mais no servidor: apagado/movido)?
_api_gone() {
  [[ "$_API_CODE" == 404 && "$(jq -r '.error.code // empty' <<<"$_API_BODY" 2>/dev/null)" == problem_gone ]]
}
_api() {  # _api <path> <json-body> -> resposta no stdout; resiliente (re-tenta um POST que falhou; ver _api_ex)
  _api_ex 30 "$1" --data "$2" && printf '%s' "$_API_BODY"
}
_api_get() {  # _api_get <path> -> corpo no stdout
  curl -fsS -m 30 "${_HH[@]}" "${_AUTH[@]}" "$MOJ_API$1" 2>/dev/null
}
_api_file() {  # _api_file <path> <bodyfile> : POST com o corpo vindo de ARQUIVO. Obrigatório p/
  # payloads grandes (report.html em base64): um ÚNICO arg >128KB estoura MAX_ARG_STRLEN
  # ("Argument list too long") e o POST se perdia em silêncio. Re-tenta como o _api.
  _api_ex 60 "$1" --data-binary "@$2"
}
_api_get_file() {  # _api_get_file <path> <outfile> -> baixa (rc!=0 em erro)
  curl -fsS -m 180 "${_HH[@]}" "${_AUTH[@]}" -o "$2" "$MOJ_API$1" 2>/dev/null
}
_uri() { jq -rn --arg s "$1" '$s|@uri'; }   # url-encode (id tem '#')

# ----------------------------------------------------------------- cache de pacotes
cache_id_dir() { printf '%s/%s' "$JUDGE_CACHE" "$(printf '%s' "$1" | tr '#/' '__')"; }

# _cache_mark_gone <id> : o servidor disse que o problema não existe mais (404 `problem_gone` num report, ou
# `exists:false` no package-meta) — marca a entrada do cache com `.gone` (o epoch): o re-report do boot e o
# inventário a pulam e o GC apaga o diretório. Um arquivo e não um campo do meta: marcar não disputa o meta com
# o ensure_cached, e ler é um `-e` sem fork. Volta a valer sozinho se o package-meta disser que existe de novo.
_cache_mark_gone() {
  local d; d="$(cache_id_dir "$1")"
  [[ -d "$d" ]] || return 0
  [[ -e "$d/.gone" ]] || alog "problema $1 não existe mais no servidor — entrada do cache marcada (o GC a apaga)"
  printf '%s\n' "$EPOCHSECONDS" > "$d/.gone" 2>/dev/null
  return 0
}

# tl_to_json <tlfile> [TL|TLKATTIS] -> {lang:val} de um array da tabela. A tabela leva as DUAS metades dos
# métodos de TL (mojtools tl-methods.sh, 26/10/2026): TL[] = MOJ, TLKATTIS[] = Kattis por linguagem. O
# `declare -A TLKATTIS` vem DENTRO do arquivo; o daqui cobre a tabela antiga (sem a metade Kattis = {}).
tl_to_json() {
  local arr="${2:-TL}"
  [[ "$arr" == TLKATTIS ]] || arr=TL
  ( declare -A TL TLMOD TLKATTIS; source "$1" 2>/dev/null
    declare -n _tla="$arr"
    for k in "${!_tla[@]}"; do printf '%s\t%s\n' "$k" "${_tla[$k]}"; done ) \
  | jq -R -s -c 'split("\n")|map(select(length>0)|split("\t")|{(.[0]):.[1]})|add // {}'
}

# _tl_has_method <tlfile> <moj|kattis|""> : a tabela serve o método pedido? Só o kattis exige a metade nova
# (TLKATTIS[]); se o mojtools local ainda não sabe calibrar o Kattis, não exige (recalibrar não a criaria).
_tl_has_method() {
  [[ "${2:-}" == kattis && -f "$MOJTOOLS_DIR/tl-methods.sh" ]] || return 0
  grep -q '^TLKATTIS\[' "$1" 2>/dev/null
}

# _tl_job_file <pkgdir> <cachedir> <tl_class-json> <saída> : a tabela do JOB com o TL da CLASSE DE HARDWARE
# (26/10/2026). Juízes idênticos calibram TLs um pouco diferentes, e o veredicto de quem está no limite dependia de
# qual juiz pegava o envio. O servidor manda no job `tl_class` = o máx, por linguagem, entre os juízes da classe
# deste (cdmoj judge-gw/sched-lib.sh `_TLCLASS_DEF`). Vale só com o MESMO tl_checksum do pacote em cache (o
# `.tl_checksum` que o ensure_cached grava do package-meta): aí a saída = a tabela local + uma linha por chave em
# que a classe é MAIOR (o `source` do build-and-test fica com a última) — nunca abaixo da medição deste juiz; py
# shim, TLMOD, TLOVERRIDE e drift seguem no build-and-test, uma vez só. O 3º arg é SÓ o `tl_class` (o job inteiro
# leva o código em base64 e estouraria os 128 KiB de um argumento do jq). Chave/valor fora do formato não entram
# (o arquivo é `source`ado). Ecoa a saída, ou nada (sem classe, servidor antigo, checksum diferente ou nada a
# subir: o job usa a tabela local, como antes).
_tl_job_file() {
  local pkg="$1" cdir="$2" tlc="$3" out="$4" loc tcks lines
  [[ -n "$tlc" && "$tlc" != null ]] || return 0
  loc="$pkg/tl.$AGENT_HOST"; [[ -f "$loc" ]] || loc="$pkg/tl"
  [[ -f "$loc" && -f "$cdir/.tl_checksum" ]] || return 0
  tcks="$(<"$cdir/.tl_checksum")"; [[ -n "$tcks" ]] || return 0
  lines="$( ( declare -A TL TLMOD TLKATTIS; source "$loc" 2>/dev/null
              for k in "${!TL[@]}"; do printf 'TL\t%s\t%s\n' "$k" "${TL[$k]}"; done
              for k in "${!TLKATTIS[@]}"; do printf 'TLKATTIS\t%s\t%s\n' "$k" "${TLKATTIS[$k]}"; done ) \
    | jq -R -r -s --arg c "$tcks" --argjson tc "$tlc" '
        def num: if test("^([0-9]+\\.?[0-9]*|\\.[0-9]+)$") then (if startswith(".") then "0" + . else . end | tonumber) else null end;
        (split("\n") | map(select(length > 0) | split("\t") | select(length == 3))
         | reduce .[] as $l ({TL: {}, TLKATTIS: {}}; .[$l[0]][$l[1]] = $l[2])) as $loc
        | if ($tc | type) != "object" or ($tc.checksum // "") != $c then empty
          else [ [["TL", "tl"], ["TLKATTIS", "tl_kattis"]][] as [$arr, $f]
                 | ($loc[$arr]) as $lm
                 | ($tc[$f] // {}) | to_entries[]
                 | select((.key | test("^[A-Za-z0-9]{1,16}$")) and ((.value | tostring | num) != null))
                 | (.value | tostring) as $v
                 | ($lm[.key] // (if .key == "py" then ($lm.py3 // $lm.py2) else null end)) as $lv
                 | select($lv == null or ($lv | num) == null or ($v | num) > ($lv | num))
                 | "\($arr)[\(.key)]=\($v)" ] as $L
            | if ($L | length) == 0 then empty
              else "# TL da classe de hardware (o máx entre os juízes idênticos: "
                     + (($tc.hosts // []) | map(tostring | gsub("[^A-Za-z0-9._-]"; "")) | join(" ")) + ") — maior que a medição local",
                   (if any($L[]; startswith("TLKATTIS[")) then "declare -A TLKATTIS" else empty end),
                   $L[]
              end
          end' 2>/dev/null)"
  [[ -n "$lines" ]] || return 0
  { cat "$loc"; printf '\n%s\n' "$lines"; } > "$out" 2>/dev/null || return 0
  printf '%s' "$out"
}

# report_tl <id> <checksum> <pkgdir> : reporta ao MOJ o TL calibrado (tl.$AGENT_HOST) — as duas metades.
# rc 0 = gravado; 3 = o problema não existe mais no servidor (404 `problem_gone`; a entrada do cache fica
# marcada, ver _cache_mark_gone); 1 = falhou (sem resposta, 5xx depois das tentativas, outro 4xx).
report_tl() {
  local id="$1" cks="$2" pkg="$3" tlf="$3/tl.$AGENT_HOST" tlj tlk
  [[ -f "$tlf" ]] || tlf="$pkg/tl"
  [[ -f "$tlf" ]] || { alog "report_tl: sem tl p/ $id"; return 1; }
  tlj="$(tl_to_json "$tlf")"; tlk="$(tl_to_json "$tlf" TLKATTIS)"
  [[ -n "$tlj" ]] || tlj='{}'; [[ -n "$tlk" ]] || tlk='{}'
  _api_ex 30 /judge/tl-report --data "$(jq -cn --arg h "$AGENT_HOST" --arg id "$id" --arg c "$cks" \
        --argjson tl "$tlj" --argjson tlk "$tlk" '{host:$h, id:$id, checksum:$c, tl:$tl, tl_kattis:$tlk}')" && return 0
  _api_gone && { _cache_mark_gone "$id"; return 3; }
  return 1
}

# report_calib_log <id> <checksum> <logfile> [pkgdir] : envia ao MOJ o LOG de calibração
# (limitado) + o report.html POR SOLUÇÃO (pkg/.calib-reports/*) + o vetor ESTRUTURADO `sols`
# (pkg/.calib-sols.json do calibreitor: por solução, {file,lang,category,verdict,tests}), p/ o
# autor ver no editor e processar com ferramentas externas. Falha não atrapalha o julgamento.
# Os reports vão TODOS até os tetos de bytes (AGENT_REPORT_MAX_BYTES, AGENT_REPORTS_MAX_BYTES); o que não
# coube é pulado (os seguintes ainda entram) e sai no log. Uma linha JSON por report num arquivo: montar o
# array no shell refazia o parse do acumulado a cada report.
# rc como o do report_tl (0 gravado; 3 = 404 `problem_gone`, entrada marcada; 1 falhou).
report_calib_log() {
  local id="$1" cks="$2" lf="$3" pkg="${4:-}" log="" rtmp
  [[ -f "$lf" ]] && log="$(tail -c 60000 "$lf" 2>/dev/null)"
  rtmp="$(mktemp)"
  if [[ -d "$pkg/.calib-reports" ]]; then
    local rf sz rn tot=0 skip=()
    for rf in "$pkg/.calib-reports/"*.html; do
      [[ -f "$rf" ]] || continue
      sz="$(stat -c%s "$rf" 2>/dev/null || echo 0)"; (( sz > 0 )) || continue
      rn="$(basename "$rf" .html)"
      if (( sz > AGENT_REPORT_MAX_BYTES || tot + sz > AGENT_REPORTS_MAX_BYTES )); then
        skip+=("$rn ($(( (sz + 1023) / 1024 )) KB)"); continue
      fi
      jq -cn --arg n "$rn" --rawfile h "$rf" '{name:$n, html_b64:($h|@base64)}' >> "$rtmp" 2>/dev/null && tot=$((tot + sz))
    done
    (( ${#skip[@]} )) && alog "calib-report de $id: ${#skip[@]} report(s) fora do envio (teto de $((AGENT_REPORT_MAX_BYTES / 1024)) KB por report, $((AGENT_REPORTS_MAX_BYTES / 1024)) KB no total): ${skip[*]}"
  fi
  # sols: a cópia no dir do CACHE ($cdir, ao lado do .calib.log) sobrevive ao GC do pkg e
  # alimenta o re-envio de boot. pkg presente SEM o arquivo = calibração sem sols (abortada/
  # mojtools velho): remove a cópia — nunca re-enviar dado velho com cara de novo.
  local cdir solsf=""; cdir="$(dirname "$lf")"
  if [[ -n "$pkg" ]]; then
    if [[ -s "$pkg/.calib-sols.json" ]]; then cp -f "$pkg/.calib-sols.json" "$cdir/.calib-sols.json" 2>/dev/null
    else rm -f "$cdir/.calib-sols.json" 2>/dev/null; fi
  fi
  if [[ -s "$cdir/.calib-sols.json" ]] \
     && (( $(stat -c%s "$cdir/.calib-sols.json" 2>/dev/null || echo 0) <= 300000 )) \
     && jq -e 'type=="array"' "$cdir/.calib-sols.json" >/dev/null 2>&1; then
    solsf="$cdir/.calib-sols.json"
  fi
  # monta o corpo num ARQUIVO: reports e sols por --slurpfile — grandes NUNCA por argv.
  local bf; bf="$(mktemp)"
  if [[ -n "$solsf" ]]; then
    jq -cn --arg h "$AGENT_HOST" --arg id "$id" --arg c "$cks" --arg log "$log" \
          --slurpfile r "$rtmp" --slurpfile s "$solsf" \
          '{host:$h, id:$id, checksum:$c, log:$log, reports:$r, sols:($s[0] // [])}' > "$bf" 2>/dev/null
  else
    jq -cn --arg h "$AGENT_HOST" --arg id "$id" --arg c "$cks" --arg log "$log" --slurpfile r "$rtmp" \
          '{host:$h, id:$id, checksum:$c, log:$log, reports:$r}' > "$bf" 2>/dev/null
  fi
  local rc=1
  if [[ -s "$bf" ]]; then
    _api_file /judge/calib-report "$bf"; rc=$?
    (( rc != 0 )) && _api_gone && rc=3
  fi
  rm -f "$bf" "$rtmp"
  (( rc == 3 )) && _cache_mark_gone "$id"
  return "$rc"
}

# ---- tetos DINÂMICOS de wall-clock (por job/por calibração) -------------------------
# _job_cap <pkgdir> <lang> [método] [tabela] -> segundos p/ UM julgamento: (TL+2.2)s/teste ×2 (rerun de TLE)
# + compile-tl + folga. Piso 300s; fallback fixo se o pacote não dá p/ ler. `tabela` = a do job (o tl.job do
# _tl_job_file, com o TL da classe de hardware); ausente = a local, tl.$AGENT_HOST.
_job_cap() {
  local pkg="$1" lang="$2" meth="${3:-}" tlf="${4:-$1/tl.$AGENT_HOST}" n tl compl cap
  n="$(find "$pkg/tests/input" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] || { printf '%s' "$AGENT_HARD_TL_FALLBACK"; return; }
  # TLOVERRIDE do conf (o autor manda no TL) tem de entrar no TETO: com override de 10s e
  # calibrado de 0.03s, um cap calculado do calibrado mataria o job legítimo no wall-clock.
  # O MÉTODO do TL (o do job › TLMETHOD do conf) escolhe a metade da tabela: o TL Kattis costuma ser
  # bem maior que o MOJ (arredonda p/ cima a 1 s), e um teto do MOJ mataria o job Kattis legítimo.
  # TLMOD sum/mult (que o build-and-test aplica) entram também.
  # a tabela do JOB (4º arg: o tl.job com o TL da classe de hardware, _tl_job_file) ou a local
  tl="$( ( declare -A TL TLMOD ULIMITS TLOVERRIDE TLKATTIS; source "$tlf" 2>/dev/null
           source "$pkg/conf" 2>/dev/null
           m="${meth:-${TLMETHOD:-moj}}"; b=""
           if [[ "$m" == kattis && ${#TLKATTIS[@]} -gt 0 ]]; then b="${TLKATTIS[$lang]:-${TLKATTIS[default]:-}}"
           else b="${TL[$lang]:-${TL[default]:-}}"; fi
           [[ "$b" =~ ^[0-9]*[.]?[0-9]+$ ]] || b=5
           [[ "${TLMOD[$lang.sum]:-}" =~ ^[0-9]*[.]?[0-9]+$ ]] && b="$(echo "$b + ${TLMOD[$lang.sum]}" | bc -l)"
           [[ "${TLMOD[$lang.mult]:-}" =~ ^[0-9]*[.]?[0-9]+$ ]] && b="$(echo "$b * ${TLMOD[$lang.mult]}" | bc -l)"
           printf '%s' "${TLOVERRIDE[$lang]:-${TLOVERRIDE[default]:-$b}}" ) )"
  [[ "$tl" =~ ^\. ]] && tl="0$tl"
  [[ "$tl" =~ ^[0-9]+([.][0-9]+)?$ ]] || tl=5
  compl="$(cat "$pkg/scripts/$lang/compile-tl" "$MOJTOOLS_DIR/lang/$lang/compile-tl" 2>/dev/null | head -n1)"
  [[ "$compl" =~ ^[0-9]+$ ]] || compl=30
  cap="$(echo "($tl + 2.2) * $n * 2 + $compl + 60" | bc -l 2>/dev/null)"; cap="${cap%%.*}"
  [[ "$cap" =~ ^[0-9]+$ ]] || cap="$AGENT_HARD_TL_FALLBACK"
  (( cap < 300 )) && cap=300
  printf '%s' "$cap"
}
# _calib_cap <pkgdir> <full> -> segundos p/ a calibração: (CALIBRATIONTL+2.2)s/teste × nº de
# soluções (full = todas; senão só good) ×2 + compilações + folga. Piso 300s. Na full, pass/slow/wrong rodam
# até o PISO dos dois métodos (mojtools build-and-test, MOJ_CALIB_ALT: b × o TL Kattis, teto 30 s) — o
# orçamento por teste sobe junto: max(CALIBRATIONTL + 2,2; min(30; b × ⌈a × CALIBRATIONTL ÷ r⌉ × r + 0,5)).
_calib_cap() {
  local pkg="$1" full="${2:-0}" n s caltl cap per
  n="$(find "$pkg/tests/input" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  if [[ "$full" == 1 ]]; then s="$(find "$pkg/sols" -mindepth 2 -maxdepth 2 -type f 2>/dev/null | wc -l)"
  else s="$(find "$pkg/sols/good" -maxdepth 1 -type f 2>/dev/null | wc -l)"; fi
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$s" =~ ^[0-9]+$ && "$s" -ge 1 ]] \
    || { printf '%s' "$AGENT_HARD_TL_FALLBACK"; return; }
  caltl="$( ( declare -A ULIMITS TLMOD TLOVERRIDE; CALIBRATIONTL=""; source "$pkg/conf" 2>/dev/null
              printf '%s' "${CALIBRATIONTL:-5}" ) )"
  [[ "$caltl" =~ ^[0-9]+([.][0-9]+)?$ ]] || caltl=5
  per="$(echo "$caltl + 2.2" | bc -l)"
  if [[ "$full" == 1 ]]; then
    local ka kb kr
    read -r ka kb kr < <( ( declare -A ULIMITS TLMOD TLOVERRIDE; source "$pkg/conf" 2>/dev/null
        a="${KATTIS_AC_TO_TIME_LIMIT:-2.0}"; b="${KATTIS_TIME_LIMIT_TO_TLE:-1.5}"; r="${KATTIS_TIME_RESOLUTION:-1.0}"
        [[ "$a" =~ ^[0-9]*[.]?[0-9]+$ ]] || a=2.0; [[ "$b" =~ ^[0-9]*[.]?[0-9]+$ ]] || b=1.5
        [[ "$r" =~ ^[0-9]*[.]?[0-9]+$ ]] && [[ "$(echo "$r > 0" | bc -l)" == 1 ]] || r=1.0
        printf '%s %s %s\n' "$a" "$b" "$r" ) )
    per="$(echo "x = $ka * $caltl / $kr; scale = 0; k = x / 1; if (k < x) k = k + 1; scale = 20;
                 f = $kb * k * $kr + 0.5; if (f > 30) f = 30; if (f < $per) f = $per; f" | bc -l 2>/dev/null)"
    [[ "$per" =~ ^[0-9]*[.]?[0-9]+$ ]] || per="$(echo "$caltl + 2.2" | bc -l)"
  fi
  cap="$(echo "$per * $n * $s * 2 + $s * 30 + 120" | bc -l 2>/dev/null)"; cap="${cap%%.*}"
  [[ "$cap" =~ ^[0-9]+$ ]] || cap="$AGENT_HARD_TL_FALLBACK"
  (( cap < 300 )) && cap=300
  printf '%s' "$cap"
}

# ensure_cached <id> [force_report] [full] [req_epoch] : garante o pacote no cache p/ a versão
# ATUAL e que o TL esteja calibrado+reportado. Baixa+calibra na 1ª vez ou se o checksum mudou.
# ⚠ O `checksum` do /judge/package-meta é OPACO p/ o agente e quem o define é o SERVIDOR: desde
# 2026-09-20 ele é a VERSÃO do pacote (`tl-checksum.sh --all-sols`: o conjunto que afeta o TL MAIS
# o `sols/` inteiro), e não o `tl_checksum` estreito. Antes, salvar uma solução `pass|slow|wrong`
# não mudava o valor e o `full` abaixo ("reaproveita o pacote do cache") recalibrava o `sols/`
# VELHO — o autor via o juiz rodar solução que ele apagou e ignorar a que acabou de escrever.
# Nunca calcule o checksum aqui: ele é o que o servidor disser.
# full=1 força recalibração rodando TODAS as soluções (Calibrar explícito). req_epoch = quando o
# PEDIDO foi feito (requested_at do update / at do comando): full de um pedido MAIS VELHO que a
# última calibração full do MESMO checksum é duplicata satisfeita — skip (checksum novo SEMPRE
# recalibra). `meth` (5º arg, o tl_method do job): com `kattis`, uma tabela SEM a metade Kattis (calibrada por um
# mojtools anterior a 26/10/2026) não serve — recalibra (rápido) antes de julgar; nunca julga pela tabela errada.
# Ecoa o diretório do pacote.
ensure_cached() {
  local id="$1" force="${2:-0}" full="${3:-0}" req_epoch="${4:-0}" meth="${5:-}" cdir meta mj ex sc tck local_cks
  [[ "$req_epoch" =~ ^[0-9]+$ ]] || req_epoch=0
  cdir="$(cache_id_dir "$id")"; meta="$cdir/.moj-cache.json"
  mkdir -p "$cdir" 2>/dev/null
  mj="$(_api_get "/judge/package-meta?id=$(_uri "$id")")"
  ex=""; sc=""; tck=""
  { read -r ex; read -r sc; read -r tck; } < <(jq -r '(.exists | tostring), (.checksum // ""), (.tl_checksum // "")' <<<"$mj" 2>/dev/null)
  if [[ "$ex" != true ]]; then
    # só a resposta VÁLIDA `exists:false` marca a entrada (servidor fora do ar/resposta ruim não é "apagado")
    [[ "$ex" == false ]] && _cache_mark_gone "$id"
    alog "pkg inexistente: $id"; return 1
  fi
  # voltou a existir (movido de volta, recriado com o mesmo id): a marca sai e o TL é re-reportado
  [[ -e "$cdir/.gone" ]] && { rm -f "$cdir/.gone"; force=1; }
  [[ -n "$sc" ]] || { alog "sem checksum p/ $id"; return 1; }
  # o tl_checksum ESTREITO (o carimbo do TL) do pacote AGORA: o job só usa o TL da classe de hardware que o
  # servidor mandou (`tl_class`, _tl_job_file) com o mesmo carimbo. Grava só quando muda (troca atômica).
  if [[ "$tck" =~ ^[a-f0-9]{6,64}$ ]] && ! { [[ -f "$cdir/.tl_checksum" ]] && [[ "$(<"$cdir/.tl_checksum")" == "$tck" ]]; }; then
    printf '%s' "$tck" > "$cdir/.tl_checksum.$BASHPID" 2>/dev/null && mv -f "$cdir/.tl_checksum.$BASHPID" "$cdir/.tl_checksum" 2>/dev/null
  fi
  local_cks="$(jq -r '.checksum // empty' "$meta" 2>/dev/null)"

  # cache válido (mesma versão) + já calibrado: opcionalmente re-reporta e sai (full=1 recalibra)
  if [[ "$full" != 1 && -d "$cdir/pkg" && "$local_cks" == "$sc" && -f "$cdir/pkg/tl.$AGENT_HOST" ]] \
     && _tl_has_method "$cdir/pkg/tl.$AGENT_HOST" "$meth"; then
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
    if [[ "$full" != 1 && -d "$cdir/pkg" && "$lc" == "$sc" && -f "$cdir/pkg/tl.$AGENT_HOST" ]] \
       && _tl_has_method "$cdir/pkg/tl.$AGENT_HOST" "$meth"; then exit 0; fi  # outro já fez
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
    if [[ "$full" != 1 && ! -f "$cdir/pkg/tl.$AGENT_HOST" && -f "$cdir/tl.$AGENT_HOST" && "$lc" == "$sc" ]] \
       && _tl_has_method "$cdir/tl.$AGENT_HOST" "$meth"; then
      cp -f "$cdir/tl.$AGENT_HOST" "$cdir/pkg/tl.$AGENT_HOST" 2>/dev/null
      rm -f "$cdir/tl.$AGENT_HOST"
      local _rt; report_tl "$id" "$sc" "$cdir/pkg"; _rt=$?
      (( _rt == 0 )) || alog "report_tl falhou $id (rc $_rt)"
      local calat; calat="$(jq -r '.calibrated_at // empty' "$meta" 2>/dev/null)"; [[ "$calat" =~ ^[0-9]+$ ]] || calat="$EPOCHSECONDS"
      jq -cn --arg id "$id" --arg c "$sc" --argjson cal "$calat" --argjson now "$EPOCHSECONDS" --argjson rt "$_rt" \
         '{id:$id, checksum:$c, tl_reported:($rt == 0), calibrated_at:$cal, reported_at:(if $rt == 0 then $now else null end)}' > "$meta"
      alog "tl restaurado do stub p/ $id (cks=${sc:0:8}; sem recalibrar)"
    else
      # calibra (gera tl.$AGENT_HOST) e reporta. full=1 (Calibrar explícito) roda TODAS as soluções
      # (good/pass/slow/wrong) p/ o log mostrar o comportamento de cada uma; senão só as good
      # (rápido, sob demanda). Robusto a toolchain ausente (pula a linguagem, não aborta).
      # TETO DE WALL-CLOCK dinâmico: o laço principal mata a ÁRVORE (calibreitor+build-and-test+
      # bwrap+solução) quando o `.deadline` do slot passa — calibração presa nunca mais segura um
      # slot p/ sempre (incidente 2026-07-15). Sem `timeout`: ele abria um pgroup próprio que o
      # reset não alcançava (ver o cabeçalho).
      local _ccap _crc
      _ccap="$(_calib_cap "$cdir/pkg" "$full")"
      _slot_deadline "$_ccap"
      # sem o MOJ_RELEASE_FILE (26/10/2026): a calibração disparada por um JOB herdava o arquivo de liberação
      # dele, e os build-and-test da calibração anotavam os grupos ≥ 1 como livres — o laço principal os
      # devolvia ao escalonador enquanto o job ainda ia julgar neles (CPU disputada, TLE espúrio no 1º envio
      # depois de recalibrar). O calibreitor novo também tira a variável; aqui vale p/ o mojtools antigo.
      # MOJ_CALIB_LANES: o interruptor das raias do calibreitor (os grupos do MOJ_CPU_GROUPS viram raias; a
      # calibração disparada por um job usa os grupos dele) — AGENT_CALIB_LANES=0 desliga também aqui
      if [[ "$full" == 1 ]]; then
        env -u MOJ_RELEASE_FILE MOJ_PROBLEM_ID="$id" MOJ_CALIB_LANES="${AGENT_CALIB_LANES:-1}" \
          bash "$MOJTOOLS_DIR/calibreitor.sh" "$cdir/pkg" >"$cdir/.calib.log" 2>&1
      else
        env -u MOJ_RELEASE_FILE MOJ_PROBLEM_ID="$id" MOJ_CALIB_LANES="${AGENT_CALIB_LANES:-1}" CALIBRATE_ONLY_GOOD=1 \
          bash "$MOJTOOLS_DIR/calibreitor.sh" "$cdir/pkg" >"$cdir/.calib.log" 2>&1
      fi
      _crc=$?
      _slot_deadline_clear
      (( _crc == 137 )) && {
        echo "### calibração MORTA por sinal (rc=137) — job preso/infra ou teto de wall-clock (${_ccap}s)" >> "$cdir/.calib.log"
        alog "calibração de $id morta por sinal (teto ${_ccap}s)"; }
      [[ -f "$cdir/pkg/tl.$AGENT_HOST" ]] || { alog "calibração não gerou tl p/ $id (ver $cdir/.calib.log)"; exit 2; }
      rm -f "$cdir/tl.$AGENT_HOST"   # stub de checksum antigo (se havia) não vale mais
      # `tl_reported` = o resultado REAL (até 26/10/2026 era true sempre): o inventário do register só lista o
      # problema com o TL entregue, e o re-report do boot completa o que falhou aqui (report_cached_tls)
      local _rt; report_tl "$id" "$sc" "$cdir/pkg"; _rt=$?
      (( _rt == 0 )) || alog "report_tl falhou $id (rc $_rt)"
      (( _rt == 3 )) || report_calib_log "$id" "$sc" "$cdir/.calib.log" "$cdir/pkg"
      jq -cn --arg id "$id" --arg c "$sc" --argjson now "$EPOCHSECONDS" --argjson rt "$_rt" \
         --argjson fl "$( [[ "$full" == 1 ]] && echo true || echo false )" \
         '{id:$id, checksum:$c, tl_reported:($rt == 0), calibrated_at:$now, reported_at:(if $rt == 0 then $now else null end), full:$fl}' > "$meta"
      alog "cacheado+calibrado $id (cks=${sc:0:8}; teto ${_ccap}s)"
    fi
  ) 9>"$cdir.lock"

  [[ -d "$cdir/pkg" && -f "$cdir/pkg/tl.$AGENT_HOST" ]] || return 1
  echo "$EPOCHSECONDS" > "$cdir/.last-used" 2>/dev/null   # carimbo de USO (o GC decide por ele)
  printf '%s' "$cdir/pkg"
}

# report_cached_tls : ao subir/relançar, re-reporta o TL de todos os problemas do cache
# já calibrados (o MOJ repovoa o TL por host sem recalibrar) — inclusive STUBS do GC
# (pkg/ removido, tl.$AGENT_HOST preservado ao lado do meta). Pula a entrada marcada `.gone` (o
# servidor já disse que o problema não existe mais) e marca a que leva o 404 `problem_gone` agora;
# a de `tl_reported:false` (o report da calibração falhou) que passa aqui vira true. Mudou o
# inventário (marcou ou completou alguma)? pede re-registro — quem registra é o laço.
report_cached_tls() {
  local d id cks rep rt tldir n=0 ng=0 nh=0
  [[ -d "$JUDGE_CACHE" ]] || return 0
  while IFS= read -r d; do
    [[ -f "$d/.moj-cache.json" && ! -e "$d/.gone" ]] || continue
    id=""; cks=""; rep=""
    { read -r id; read -r cks; read -r rep; } < <(jq -r '(.id // ""), (.checksum // ""), (.tl_reported // false)' \
                                                      "$d/.moj-cache.json" 2>/dev/null)
    [[ -n "$id" && -n "$cks" ]] || continue
    if [[ -d "$d/pkg" && -f "$d/pkg/tl.$AGENT_HOST" ]]; then tldir="$d/pkg"
    elif [[ -f "$d/tl.$AGENT_HOST" ]]; then tldir="$d"        # stub do GC
    else continue; fi
    report_tl "$id" "$cks" "$tldir"; rt=$?
    (( rt == 3 )) && { ng=$((ng+1)); continue; }
    if (( rt == 0 )); then
      n=$((n+1))
      if [[ "$rep" != true ]]; then   # sob o lock do problema; ocupado = o ensure_cached grava o meta dele
        ( flock -n 9 || exit 1
          jq -c --arg c "$cks" --argjson now "$EPOCHSECONDS" \
             'if .checksum == $c then .tl_reported = true | .reported_at = $now else . end' \
             "$d/.moj-cache.json" > "$d/.moj-cache.json.t" 2>/dev/null && mv -f "$d/.moj-cache.json.t" "$d/.moj-cache.json"
        ) 9>"$d.lock" && nh=$((nh+1))
      fi
    fi
    # re-envia também o LOG da calibração (sem o pkgdir -> sem os report.html, fica leve;
    # o vetor `sols` VAI junto — a cópia .calib-sols.json mora aqui no dir do cache) p/ a
    # interface não perder o "ver log" de cada juiz depois que o agente reinicia.
    if [[ -f "$d/.calib.log" ]]; then
      report_calib_log "$id" "$cks" "$d/.calib.log"; (( $? == 3 )) && ng=$((ng+1))
    fi
  done < <(find "$JUDGE_CACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  (( n > 0 )) && alog "re-reportei TL+log de $n problema(s) do cache"
  (( ng > 0 )) && alog "$ng problema(s) do cache não existem mais no servidor (marcados; o GC apaga)"
  (( ng + nh > 0 )) && _request_register
  return 0
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
  local d used cut n=0 ng=0
  # 0) problema que o servidor disse não existir mais (`.gone`, ver _cache_mark_gone): sai INTEIRO — pkg, stub,
  #    meta, logs e o lock. Sob o lock do problema (ocupado = fica p/ a próxima varredura).
  while IFS= read -r d; do
    [[ -e "$d/.gone" ]] || continue
    ( flock -n 9 || exit 1; rm -rf "$d"; rm -f "$d.lock" ) 9>"$d.lock" \
      && { alog "[gc] ${d##*/}: o problema não existe mais no servidor — entrada removida"; ng=$((ng+1)); }
  done < <(find "$JUDGE_CACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
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
  (( n > 0 )) && alog "[gc] $n pacote(s) viraram stub"
  (( n + ng > 0 )) && register
  return 0
}

INVHASH=""
register() {  # [boot=1] — boot:true faz o servidor RE-ENFILEIRAR o que estava atribuído a este
  # host (restart devolve o trabalho em voo NA HORA, sem esperar TTL) e devolver a config vigente
  # (adotada antes do 1º heartbeat). REG_RESP guarda a resposta p/ o boot ler.
  local boot="${1:-0}" specs problems langs body
  # specs (ncpu/mem/gpu) medidas UMA vez no processo principal (AGENT_SPECS, no boot): um register
  # disparado de dentro de um slot PINADO via `nproc` ⇒ `ncpu` = tamanho do slot (bug (c)) —
  # hoje nenhum subshell registra (ver _request_register), e o cache fecha a porta de vez.
  specs="${AGENT_SPECS:-$(agent_specs_json)}"; problems="$(agent_problems_json)"; langs="$(agent_langs_json)"
  # versões do toolchain medidas DENTRO da jaula (cacheadas; ver inventory.sh) — o servidor
  # publica isso na "info sheet" da prova
  local toolchain; toolchain="$(agent_toolchain_json "$langs")"; [[ -n "$toolchain" ]] || toolchain='{}'
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
    --argjson toolchain "$toolchain" --arg os "$(agent_os_pretty)" \
    --arg cage "${CAGE_ROOT:-}" --argjson cb "$cbytes" --arg ih "$INVHASH" \
    --argjson ts "${N_SLOTS:-1}" --arg part "${CFG_PARTITION:-off}" \
    --argjson topo "$(agent_topology_json)" --argjson boot "$bootj" \
    --argjson sc "${SLOT_CPUS_MIN:-1}" --argjson sbn "${SLOTS_BY_NODE_JSON:-{\}}" --argjson smt "${SMT_ON:-false}" \
    '$specs + {host:$host, capability:$cap, problems:$problems, langs:$langs, toolchain:$toolchain, os:$os,
               cage_root:(if $cage=="" then null else $cage end),
               cache_bytes:$cb, inv_hash:$ih,
               total_slots:$ts, partition:$part, topology:$topo, boot:$boot,
               slot_cpus:$sc, slots_by_node:$sbn, smt:$smt}')"
  # VALIDAR O CORPO, não só o transporte: um proxy/landing errado responde 200 com HTML e o
  # agente "se registrava" de mentira — sem register real não há requeue boot:true e o claim
  # do agente anterior vira FANTASMA imortal (o keepalive do heartbeat renova o mtime p/
  # sempre). Caso real: cut-over 2026-07-17, fso-butters-modulo preso em "calibrando".
  if REG_RESP="$(_api /judge/register "$body")" \
     && jq -e '.success == true' <<<"$REG_RESP" >/dev/null 2>&1; then
    alog "registrado ($(jq -r 'length' <<<"$problems") problemas, $(jq -r 'length' <<<"$langs") linguagens, inv=$INVHASH)"
  else
    REG_RESP=""; alog "falha ao registrar (sem resposta válida do servidor)"; return 1
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

  # MÉTODO DO TL (mojtools tl-methods.sh): o servidor o tira do conf ATUAL ao entregar o job (o TLMETHOD fica
  # fora dos carimbos do pacote, então o conf do cache pode estar velho). Vai ao build-and-test (MOJ_TL_METHOD),
  # ao teto do job e ao ensure_cached (job kattis com tabela sem a metade Kattis recalibra antes de julgar).
  # Servidor antigo (sem o campo): vazio — o build-and-test usa o TLMETHOD do conf, como sempre.
  # `tl_class` (26/10/2026) = o TL da classe de hardware deste juiz (o máx entre os idênticos; _tl_job_file).
  local tlm="" tlc=""
  { read -r tlm; read -r tlc; } < <(jq -r '(.tl_method // ""), (.tl_class // null | if . == null then "" else tojson end)' <<<"$job" 2>/dev/null)
  [[ "$tlm" == moj || "$tlm" == kattis ]] || tlm=""

  # garante o pacote no cache (baixa + calibra na 1ª vez / se mudou)
  local pkg; pkg="$(ensure_cached "$problem" 0 0 0 "$tlm")" || {
    _post_judge_error "$id" "$contest" "$problem" "$login" "$lang" "Judge Error (pacote indisponível)"
    alog "FALHA preparar pacote id=$id problem=$problem"; return; }

  local work src; work="$(mktemp -d)"; src="$work/$filename"
  printf '%s' "$code_b64" | base64 -d > "$src" 2>/dev/null

  # JUÍZES IDÊNTICOS, MESMO TL: com o `tl_class` do servidor (e o mesmo tl_checksum), a tabela do job é a local
  # com o TL da classe onde ele é maior (_tl_job_file) — vai ao build-and-test (MOJ_TLFILE vence a seleção
  # tl.<host>/tl) e ao teto do job. Vazio = a tabela local, como antes.
  local tljob; tljob="$(_tl_job_file "$pkg" "$(cache_id_dir "$problem")" "$tlc" "$work/tl.job")"
  [[ -n "$tljob" ]] && alog "id=$id: TL da classe de hardware ($(grep -c '^TL' "$tljob" 2>/dev/null) linha(s) acima da medição local)"

  local out wb verdict jcap jrc
  # MOJ_PROBLEM_ID: id real do problema p/ o report (o pacote no cache é <id>/pkg) + ativa a
  # coleta do toolchain no build-and-test (só p/ submissão real, não na calibração).
  # TETO DE WALL-CLOCK dinâmico (TL×testes×2 + compile + folga): o laço principal mata a árvore
  # e reporta Judge Error quando o `.deadline` passa — um job preso em infra/sandbox morre
  # sozinho e nunca entope o juiz (e o reset alcança tudo: sem `timeout`, sem pgroup à parte).
  jcap="$(_job_cap "$pkg" "$lang" "$tlm" "$tljob")"
  _slot_deadline "$jcap"
  # stderr do b-a-t em ARQUIVO (era /dev/null): quando ele morre por sinal, a única pista do
  # motivo é essa — a Maratona 29/08 custou uma manhã de forense por causa do descarte.
  out="$(MOJ_PROBLEM_ID="$problem" MOJ_TL_METHOD="$tlm" MOJ_TLFILE="$tljob" bash "$BAT" "$lang" "$src" "$pkg" y 2>"$work/bat.stderr")"
  jrc=$?
  _slot_deadline_clear
  wb="$(printf '%s\n' "$out" | head -n1)"
  verdict="$(printf '%s\n' "$out" | tail -n1)"
  local batdead=0
  # b-a-t morto NO MEIO (Maratona 29/08: stderr de 79 MB/teste do time entrava inteiro no
  # run-trace.log via LOG "$(<f)" e o ulimit -f matava o próprio harness com SIGXFSZ): a
  # saída para na 1ª linha e o tail -n1 devolvia o CAMINHO DO WORKDIR como "veredicto" — o
  # servidor segurava lixo p/ revisão, sem report, e o juiz decidia às cegas. Workdir como
  # veredicto nunca é legítimo.
  if [[ "$verdict" == "$wb" || -d "$verdict" ]]; then
    batdead=1
    alog "b-a-t morreu SEM veredicto id=$id rc=$jrc stderr: $(tail -c 300 "$work/bat.stderr" 2>/dev/null | tr '\n' ' ')"
    verdict="Judge Error (build-and-test morreu sem veredicto; rc=$jrc)"
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
  (( jrc == 137 || batdead )) && vcanon="Judge Error"   # canônico limpo p/ o daemon segurar
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
  _request_register   # inventário mudou: o LAÇO PRINCIPAL re-registra (nunca daqui, pinado — bug (c))
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
# (job|update|command + JSON mínimo SEM code_b64) p/ reportar ao servidor se o job for MORTO;
# SLOT_NODE = nó NUMA do slot ("" = sem topologia/sem pin).
# SLOT_ALLOC/SLOT_RELEASED (só no PRIMÁRIO de um job largo) = slots por grupo e grupos já liberados.
declare -a SLOT_CPUS=() SLOT_PID=() SLOT_TMP=() SLOT_KIND=() SLOT_META=() SLOT_NODE=() SLOT_ALLOC=() SLOT_RELEASED=()
: "${AGENT_SYSFS:=/sys}"   # raiz do sysfs (o teste do agente aponta p/ uma árvore FALSA)
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

# _node_cpulists -> "nó<TAB>cpulist" por nó NUMA (ordem numérica); vazio se o sysfs não expõe nós.
_node_cpulists() {
  local n
  for n in "$AGENT_SYSFS"/devices/system/node/node[0-9]*; do
    [[ -f "$n/cpulist" ]] || continue
    printf '%s\t%s\n' "${n##*node}" "$(<"$n/cpulist")"
  done | sort -t$'\t' -k1,1n
}

# build_slots <partition> <reserve> -> popula SLOT_CPUS/SLOT_NODE/SLOT_PID. off = 1 slot sem pin.
# `cpus:X` fatia POR NÓ NUMA (bug (e), 24/09/2026): a fatia antiga seguia a ordem numérica das
# CPUs, e com uma topologia `0-13,28-41 | 14-27,42-55` um slot de 4 cruzava nós (memória remota
# num slot, local no vizinho: TL diferente p/ o mesmo código). O resto (< X cpus) de CADA nó
# fica fora dos slots — fatias uniformes p/ timing consistente.
build_slots() {
  local mode="${1:-off}" reserve="${2:-0}"
  [[ "$reserve" =~ ^[0-9]+$ ]] || reserve=0
  SLOT_CPUS=(); SLOT_NODE=(); SLOT_PID=(); SLOT_TMP=(); SLOT_KIND=(); SLOT_META=()
  case "$mode" in
    numa)
      local node cl cpus
      while IFS=$'\t' read -r node cl; do
        [[ -n "$cl" ]] || continue
        # reserve tira as N primeiras cpus DO HOST (só afeta o node que as contém)
        read -ra cpus <<<"$(_cpus_expand "$cl")"
        local kept=() c
        for c in "${cpus[@]}"; do (( c >= reserve )) && kept+=("$c"); done
        (( ${#kept[@]} > 0 )) && { SLOT_CPUS+=("$(IFS=,; echo "${kept[*]}")"); SLOT_NODE+=("$node"); SLOT_PID+=(0); }
      done < <(_node_cpulists)
      ;;
    cpus:*)
      local X="${mode#cpus:}" c node cl nodes
      [[ "$X" =~ ^[0-9]+$ && "$X" -ge 1 ]] || { alog "partition '$mode' inválida — usando off"; X=0; }
      if (( X >= 1 )); then
        local -A ON=()
        for c in $(_cpus_expand "$(<"$AGENT_SYSFS/devices/system/cpu/online")"); do ON[$c]=1; done
        nodes="$(_node_cpulists)"
        # sem topologia (VM mínima): um pseudo-nó "-" (vira "") com todas as cpus online
        [[ -n "$nodes" ]] || nodes="$(printf -- '-\t%s' "$(<"$AGENT_SYSFS/devices/system/cpu/online")")"
        while IFS=$'\t' read -r node cl; do
          [[ "$node" == - ]] && node=""
          local chunk=()
          for c in $(_cpus_expand "$cl"); do
            [[ -n "${ON[$c]:-}" ]] || continue     # cpu offline não entra em slot
            (( c < reserve )) && continue
            chunk+=("$c")
            if (( ${#chunk[@]} == X )); then
              SLOT_CPUS+=("$(IFS=,; echo "${chunk[*]}")"); SLOT_NODE+=("$node"); SLOT_PID+=(0); chunk=()
            fi
          done
        done <<<"$nodes"
      fi
      ;;
  esac
  if (( ${#SLOT_CPUS[@]} == 0 )); then SLOT_CPUS=(""); SLOT_NODE=(""); SLOT_PID=(0); fi   # off/fallback: 1 slot, sem pin
  # modo ROOT é single-slot only: cset/cgroup do cage-run são estado GLOBAL da máquina
  # (ver mojtools/SANDBOX.md) — multi-slot como root compartilharia shield/limites entre jobs.
  if (( EUID == 0 )) && (( ${#SLOT_CPUS[@]} > 1 )); then
    alog "ATENÇÃO: agente como ROOT com ${#SLOT_CPUS[@]} slots — modo root é single-slot only; FORÇANDO 1 slot"
    SLOT_CPUS=(""); SLOT_NODE=(""); SLOT_PID=(0); SLOT_TMP=(); SLOT_KIND=(); SLOT_META=()
  fi
  N_SLOTS=${#SLOT_CPUS[@]}
  SLOT_ALLOC=(); SLOT_RELEASED=()
  _slots_topology
  alog "slots: $N_SLOTS (partition=$mode reserve=$reserve; menor slot ${SLOT_CPUS_MIN} cpu(s); smt=$SMT_ON; por nó $SLOTS_BY_NODE_JSON)$( ((N_SLOTS>1)) && printf ' cpusets: %s' "${SLOT_CPUS[*]}" )"
}

# ---- topologia dos slots: irmãos SMT, menor slot, slots por nó (calculada em build_slots) -----
# CPU_SIB[cpu] = o irmão de hyperthreading (thread_siblings_list; vazio = sem SMT). SLOT_CPUS_MIN =
# cpus do MENOR slot (1 em produção; = ncpu com partition off) — é o `slot_cpus` do protocolo.
# SLOTS_BY_NODE_JSON = {"<nó>": n} — o servidor confere `SAMENUMA` por ele.
declare -A CPU_SIB=()
SMT_ON=false; SLOT_CPUS_MIN=1; SLOTS_BY_NODE_JSON='{}'
_slots_topology() {
  local i c cnt min=0 sib s f n
  local -A bn=()
  CPU_SIB=(); SMT_ON=false
  for i in "${!SLOT_CPUS[@]}"; do
    if [[ -z "${SLOT_CPUS[i]}" ]]; then
      cnt="$(jq -r '.ncpu // 1' <<<"${AGENT_SPECS:-{\}}" 2>/dev/null)"; [[ "$cnt" =~ ^[0-9]+$ && "$cnt" -ge 1 ]] || cnt=1
    else
      cnt=0
      for c in $(_cpus_expand "${SLOT_CPUS[i]}"); do
        cnt=$((cnt+1))
        f="$AGENT_SYSFS/devices/system/cpu/cpu$c/topology/thread_siblings_list"
        [[ -f "$f" ]] || continue
        sib="$(<"$f")"
        for s in $(_cpus_expand "$sib"); do
          (( s != c )) && { CPU_SIB[$c]="$s"; SMT_ON=true; break; }
        done
      done
    fi
    (( min == 0 || cnt < min )) && min=$cnt
    n="${SLOT_NODE[i]:--}"; bn[$n]=$(( ${bn[$n]:-0} + 1 ))   # "-" = sem nó (chave vazia é erro no assoc)
  done
  SLOT_CPUS_MIN=$min
  SLOTS_BY_NODE_JSON="$(for n in "${!bn[@]}"; do printf '%s\t%s\n' "$n" "${bn[$n]}"; done \
    | jq -RnSc '[inputs | split("\t") | {(.[0]): (.[1]|tonumber)}] | add // {}' 2>/dev/null)"
  [[ -n "$SLOTS_BY_NODE_JSON" ]] || SLOTS_BY_NODE_JSON='{}'
}

# _max_free_group -> maior nº de slots LIVRES dentro de UM nó (o `max_free_group` do heartbeat;
# com ele o servidor sabe se um job SAMENUMA cabe aqui sem tentar).
_max_free_group() {
  local i n max=0
  local -A fn=()
  for i in "${!SLOT_PID[@]}"; do
    (( SLOT_PID[i] == 0 )) || continue
    n="${SLOT_NODE[i]:--}"; fn[$n]=$(( ${fn[$n]:-0} + 1 ))
    (( fn[$n] > max )) && max=${fn[$n]}
  done
  printf '%s' "$max"
}

# ---- alocação de CPUs p/ um job: alloc_slots <k> <P> <same_numa y|n> [cap] -------------------
# Escolhe até P GRUPOS de k CPUs entre os slots LIVRES e deixa em ALLOC_GROUPS (cpulist por grupo,
# "" = sem pin) e ALLOC_SLOTS (índices dos slots consumidos; o 1º é o PRIMÁRIO). Regras:
#   · um grupo fica DENTRO de um nó (sempre preferido; obrigatório com same_numa=y);
#   · com SMT e k ≥ 2 o grupo é feito de NÚCLEOS INTEIROS (os dois irmãos) — a mesma forma na
#     calibração e no julgamento; cpu sem o irmão livre não entra num grupo de k ≥ 2;
#   · P limita os grupos que consomem slot NOVO; cpus SOBRANDO num slot já consumido (partition
#     numa/off: slot maior que k) formam grupos extras de graça, até `cap` (MAXPARALLELTESTS);
#   · nós com mais cpus livres primeiro; sem same_numa, sobras de nós diferentes ainda podem
#     compor um grupo no fim.
# Devolve 1 sem NENHUM grupo (⇒ o chamador recusa o trabalho: /judge/decline). Função pura
# sobre SLOT_* (testável).
declare -a ALLOC_GROUPS=() ALLOC_SLOTS=()
alloc_slots() {
  local k="$1" P="$2" numa="${3:-n}" cap="${4:-}" i c n node rest=""
  ALLOC_GROUPS=(); ALLOC_SLOTS=(); ALLOC_USED=" "; ALLOC_NEW=0
  [[ "$k" =~ ^[0-9]+$ && "$k" -ge 1 ]] || k=1
  [[ "$P" =~ ^[0-9]+$ && "$P" -ge 1 ]] || P=1
  [[ "$cap" =~ ^[0-9]+$ && "$cap" -ge 1 ]] || cap=$P
  (( cap < P )) && cap=$P
  local -A NC=() NN=()
  for i in "${!SLOT_PID[@]}"; do
    (( SLOT_PID[i] == 0 )) || continue
    n="${SLOT_NODE[i]:--}"
    if [[ -z "${SLOT_CPUS[i]}" ]]; then   # slot sem pin (partition off): a máquina inteira
      local ncpu; ncpu="$(jq -r '.ncpu // 1' <<<"${AGENT_SPECS:-{\}}" 2>/dev/null)"; [[ "$ncpu" =~ ^[0-9]+$ ]] || ncpu=1
      local g=$(( ncpu / k )); (( g < 1 )) && g=1; (( g > cap )) && g=$cap
      ALLOC_SLOTS=("$i"); for (( c=0; c<g; c++ )); do ALLOC_GROUPS+=(""); done
      return 0
    fi
    for c in $(_cpus_expand "${SLOT_CPUS[i]}"); do NC[$n]+="$c:$i "; NN[$n]=$(( ${NN[$n]:-0} + 1 )); done
  done
  (( ${#NN[@]} > 0 )) || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    _alloc_from_list "${NC[$node]}" "$k" "$P" "$cap"
    rest+="$ALLOC_REST"
  done < <(for n in "${!NN[@]}"; do printf '%s\t%s\n' "${NN[$n]}" "$n"; done | sort -rn -k1,1 | cut -f2)
  [[ "$numa" != y && -n "$rest" ]] && _alloc_from_list "$rest" "$k" "$P" "$cap"
  (( ${#ALLOC_GROUPS[@]} > 0 )) || return 1
  return 0
}
# _alloc_from_list "<cpu:slot …>" k P cap : corta a lista em grupos de k cpus (núcleos inteiros com
# SMT e k ≥ 2), respeitando P (slots novos) e cap (total); ALLOC_REST = o que não entrou.
_alloc_from_list() {
  local list="$1" k="$2" P="$3" cap="$4" e c s take=() rest=() paired=() single=() cpus slots isnew
  local -A seen=()
  ALLOC_REST=""
  if [[ "$SMT_ON" == true ]] && (( k >= 2 )); then
    # reordena: pares (cpu, irmão) ambos na lista vão na frente, juntos; sem par = sobra
    local -A pos=()
    for e in $list; do pos[${e%%:*}]="$e"; done
    for e in $list; do
      c="${e%%:*}"; [[ -n "${seen[$c]:-}" ]] && continue
      s="${CPU_SIB[$c]:-}"
      if [[ -n "$s" && -n "${pos[$s]:-}" && -z "${seen[$s]:-}" ]]; then
        paired+=("$e" "${pos[$s]}"); seen[$c]=1; seen[$s]=1
      else single+=("$e"); seen[$c]=1; fi
    done
    list="${paired[*]}"; rest=("${single[@]}")
    k=$(( ((k + 1) / 2) * 2 ))   # núcleos inteiros
  fi
  set -- $list
  while (( $# >= k )); do
    (( ${#ALLOC_GROUPS[@]} >= cap )) && break
    take=("${@:1:k}")
    isnew=0; for e in "${take[@]}"; do [[ "$ALLOC_USED" == *" ${e#*:} "* ]] || isnew=1; done
    if (( isnew )) && (( ALLOC_NEW >= P )); then break; fi
    cpus=""; for e in "${take[@]}"; do cpus+="${cpus:+,}${e%%:*}"; done
    ALLOC_GROUPS+=("$cpus")
    (( isnew )) && ALLOC_NEW=$((ALLOC_NEW+1))
    for e in "${take[@]}"; do s="${e#*:}"
      [[ "$ALLOC_USED" == *" $s "* ]] || { ALLOC_USED+="$s "; ALLOC_SLOTS+=("$s"); }
    done
    shift "$k"
  done
  rest+=("$@")
  ALLOC_REST="${rest[*]}${rest[*]:+ }"
}

# _alloc_env : monta, a partir de ALLOC_GROUPS, o que vai p/ o build-and-test: ALLOC_UNION
# (cpulist da união = pin do subshell) e ALLOC_GROUPS_STR ("g0|g1|…", vazio = sem pin).
_alloc_env() {
  local g u="" any=0
  ALLOC_GROUPS_STR=""; ALLOC_UNION=""
  for g in "${ALLOC_GROUPS[@]}"; do
    [[ -n "$g" ]] && { any=1; u+="${u:+,}$g"; }
    ALLOC_GROUPS_STR+="${ALLOC_GROUPS_STR:+|}$g"
  done
  (( any )) || ALLOC_GROUPS_STR=""
  ALLOC_UNION="$u"
}

# _slot_take <pid> <kind> <meta> <tmp> : registra o job em TODOS os slots de ALLOC_SLOTS — o 1º é o
# PRIMÁRIO (guarda pid/tmp/kind/meta e a alocação por grupo); os demais são MEMBROS (mesmo pid,
# kind=member, meta = índice do primário, sem tmp). Deixa o índice do primário em TAKEN_PRIMARY
# (nunca chame por $(…): as mudanças em SLOT_* morreriam no subshell).
_slot_take() {
  local pid="$1" kind="$2" meta="$3" tmp="$4" p="${ALLOC_SLOTS[0]}" s g alloc="" first=1
  SLOT_PID[p]=$pid; SLOT_KIND[p]="$kind"; SLOT_META[p]="$meta"; SLOT_TMP[p]="$tmp"; SLOT_RELEASED[p]=" "
  for s in "${ALLOC_SLOTS[@]:1}"; do SLOT_PID[s]=$pid; SLOT_KIND[s]=member; SLOT_META[s]="$p"; SLOT_TMP[s]=""; done
  # alocação por grupo ("slots do g0|slots do g1|…"), p/ a liberação de cauda
  for g in "${!ALLOC_GROUPS[@]}"; do
    local e cpus="${ALLOC_GROUPS[g]}" gs=""
    for s in "${ALLOC_SLOTS[@]}"; do
      [[ -z "$cpus" ]] && { gs="$s"; break; }
      for e in $(_cpus_expand "$cpus"); do
        [[ " $(_cpus_expand "${SLOT_CPUS[s]}") " == *" $e "* ]] && { gs+="${gs:+ }$s"; break; }
      done
    done
    alloc+="${first:+}${alloc:+|}$gs"; first=""
  done
  SLOT_ALLOC[p]="$alloc"
  TAKEN_PRIMARY="$p"
}

# _release_tail <primário> : lê $TMPDIR/released do job (índices de grupo que o build-and-test
# anotou: ficaram sem teste) e devolve os slots que SÓ esses grupos usavam. Idempotente (o arquivo
# é append-only, o mesmo índice pode repetir); o grupo 0 nunca é liberado (é o do rerun/primário).
_release_tail() {
  # (dois `local`: numa declaração só o bash expande TODAS as palavras antes de atribuir — o `p` do índice
  # ainda não existiria e, sob `set -u`, o agente morria a cada volta com job rodando; 28/09/2026)
  local p="$1"; local f="${SLOT_TMP[p]:-}/released" g s gs other ok
  [[ -n "${SLOT_TMP[p]:-}" && -s "$f" && -n "${SLOT_ALLOC[p]:-}" ]] || return 0
  local -a GS; IFS='|' read -ra GS <<<"${SLOT_ALLOC[p]}"
  while IFS= read -r g; do
    [[ "$g" =~ ^[0-9]+$ ]] && (( g >= 1 && g < ${#GS[@]} )) || continue
    [[ "${SLOT_RELEASED[p]}" == *" $g "* ]] && continue
    SLOT_RELEASED[p]+="$g "
    for s in ${GS[g]}; do
      (( s == p )) && continue
      ok=1   # só solta o slot se nenhum grupo AINDA VIVO o usa (partition numa: slot > k)
      for other in "${!GS[@]}"; do
        (( other == g )) && continue
        [[ "${SLOT_RELEASED[p]}" == *" $other "* ]] && continue
        [[ " ${GS[other]} " == *" $s "* ]] && { ok=0; break; }
      done
      (( ok )) || continue
      SLOT_PID[s]=0; SLOT_KIND[s]=""; SLOT_META[s]=""; SLOT_TMP[s]=""
      alog "cauda: grupo $g do job no slot $p liberou o slot $s"
    done
  done < "$f"
  return 0
}

# _decline <kind job|update|command> <json> <motivo> : devolve ao servidor um trabalho que não
# coube (corrida entre o claim e a alocação): o servidor reenfileira. Servidor antigo (sem a rota)
# ignora — o job volta pelo ASSIGN_TTL como sempre.
_decline() {
  local kind="$1" j="$2" why="$3" body
  case "$kind" in
    job)     body="$(jq -cn --arg h "$AGENT_HOST" --arg w "$why" --arg id "$(jq -r '.id // ""' <<<"$j")" '{host:$h, reason:$w, id:$id}')" ;;
    update)  body="$(jq -cn --arg h "$AGENT_HOST" --arg w "$why" --arg r "$(jq -r '.reqid // ""' <<<"$j")" '{host:$h, reason:$w, reqid:$r}')" ;;
    command) body="$(jq -cn --arg h "$AGENT_HOST" --arg w "$why" --argjson c "$j" '{host:$h, reason:$w, command:$c}')" ;;
    *) return 0 ;;
  esac
  alog "recusando $kind ($why)"
  _api /judge/decline "$body" >/dev/null || alog "decline não aceito pelo servidor (antigo?)"
  return 0
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
  local i="$1" why="$2"; local kind="${SLOT_KIND[i]:-}" meta="${SLOT_META[i]:-}"   # (ver _release_tail)
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

# _tree_pids <pid> : ecoa <pid> + TODOS os descendentes (uma linha), atravessando grupos de
# processos e sessões — por parentesco (pgrep -P), não por pgid.
_tree_pids() {
  local all=" $1 " frontier="$1" next p k
  while [[ -n "$frontier" ]]; do
    next=""
    for p in $frontier; do
      for k in $(pgrep -P "$p" 2>/dev/null || ps -o pid= --ppid "$p" 2>/dev/null); do
        [[ "$all" == *" $k "* ]] || { all+="$k "; next+="$k "; }
      done
    done
    frontier="$next"
  done
  printf '%s' "${all# }"
}
# _kill_tree <pid> : mata a ÁRVORE sob <pid> (ele incluso). ÚNICO matador do agente — usado pelo
# reset/restart, pelo TERM/INT e pelo teto de wall-clock. O `kill -- -pgid` de antes não alcançava
# o que rodava sob `timeout` (ele abre um pgroup próprio p/ poder matar o comando junto): um job
# "morto" pelo reset seguia com build-and-test+bwrap+solução vivos nas CPUs que o slot seguinte
# recebia (bug (a), 24/09/2026). Receita: colhe a árvore, SIGSTOP em todos (ninguém forka no meio),
# colhe DE NOVO (filho nascido entre a colheita e o STOP), STOP neles, SIGKILL em tudo; o pgroup
# do slot leva KILL também (cinto e suspensório). A jaula (bwrap --die-with-parent + pid
# namespace) vai junto com o bwrap.
_kill_tree() {
  local root="$1" pids
  pids="$(_tree_pids "$root")"
  # shellcheck disable=SC2086
  kill -STOP $pids 2>/dev/null
  pids="$(_tree_pids "$root")"
  # shellcheck disable=SC2086
  kill -STOP $pids 2>/dev/null
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  kill -KILL -- "-$root" 2>/dev/null
  return 0
}

# agent_slots_kill <motivo> : mata a árvore de cada slot ocupado (job inteiro: build-and-test+
# bwrap+solução), reporta ao servidor e limpa o TMPDIR do job. É a ferramenta de recuperação do
# `moj judges reset` — o que faltou no incidente 2026-07-15.
agent_slots_kill() {
  local why="${1:-morto pelo agente}" i pid n=0
  for i in "${!SLOT_PID[@]}"; do
    pid="${SLOT_PID[i]:-0}"; (( pid != 0 )) || continue
    _kill_tree "$pid"
    _report_slot_killed "$i" "$why"
    SLOT_PID[i]=0
    [[ -n "${SLOT_TMP[i]:-}" ]] && rm -rf "${SLOT_TMP[i]}" 2>/dev/null; SLOT_TMP[i]=""
    n=$((n+1))
  done
  (( n > 0 )) && alog "$n slot(s) morto(s): $why"
  return 0
}

# ---- teto de wall-clock: o canal entre o subshell do slot e o laço principal ----------------
# _slot_deadline <secs> : grava em $TMPDIR/.deadline "<epoch-limite> <cap>" p/ a fase que começa
# agora (chamado DENTRO do slot, antes do build-and-test e antes do calibreitor);
# _slot_deadline_clear : a fase acabou. Sem TMPDIR (rodando fora de um slot) não faz nada.
_slot_deadline() {
  [[ -n "${TMPDIR:-}" && -d "${TMPDIR:-}" && "$1" =~ ^[0-9]+$ ]] || return 0
  printf '%s %s\n' "$(( EPOCHSECONDS + $1 ))" "$1" > "$TMPDIR/.deadline.tmp" 2>/dev/null \
    && mv -f "$TMPDIR/.deadline.tmp" "$TMPDIR/.deadline" 2>/dev/null
  return 0
}
_slot_deadline_clear() { [[ -n "${TMPDIR:-}" ]] && rm -f "$TMPDIR/.deadline" 2>/dev/null; return 0; }

# ---- re-registro pedido por um slot (nunca registrar de DENTRO do slot: bug (c)) ------------
# O subshell pinado que chamava `register` media `nproc` = tamanho do slot (ncpu errado no
# registry) e atualizava INVHASH só na cópia dele — o laço seguia mandando o hash velho e o
# servidor pedia reregister a cada beat. Agora o slot deixa um FLAG e o laço principal registra.
_request_register() { : > "$AGENT_WORK/.reregister" 2>/dev/null; return 0; }
_pending_register() {
  [[ -e "$AGENT_WORK/.reregister" ]] || return 0
  rm -f "$AGENT_WORK/.reregister" 2>/dev/null
  register
}

# ----------------------------------------------------------------- loop principal
# _free_slot -> ecoa o índice do primeiro slot livre (rc 1 se nenhum)
_free_slot() { local i; for i in "${!SLOT_PID[@]}"; do (( SLOT_PID[i] == 0 )) && { echo "$i"; return 0; }; done; return 1; }

# _reap_slots : colhe os slots que terminaram (+ limpeza do TMPDIR) e IMPÕE o teto de wall-clock
# (`$TMPDIR/.deadline` vencido ⇒ _kill_tree + report ao servidor). Deixa em FREE o nº de livres.
_reap_slots() {
  local i pid dl cap
  FREE=0
  for i in "${!SLOT_PID[@]}"; do
    pid="${SLOT_PID[i]:-0}"
    if (( pid != 0 )) && ! kill -0 "$pid" 2>/dev/null; then
      # membro (mesmo pid do primário) cai aqui junto: sem TMP, nada a apagar
      SLOT_PID[i]=0; SLOT_KIND[i]=""; SLOT_META[i]=""; SLOT_ALLOC[i]=""; SLOT_RELEASED[i]=""
      [[ -n "${SLOT_TMP[i]:-}" ]] && rm -rf "${SLOT_TMP[i]}" 2>/dev/null; SLOT_TMP[i]=""
    elif (( pid != 0 )); then
      # liberação de cauda: o build-and-test anotou grupos que ficaram sem teste
      [[ "${SLOT_KIND[i]:-}" == job && -n "${SLOT_ALLOC[i]:-}" ]] && _release_tail "$i"
      if [[ -n "${SLOT_TMP[i]:-}" && -s "${SLOT_TMP[i]}/.deadline" ]]; then
        dl=""; cap=""; read -r dl cap < "${SLOT_TMP[i]}/.deadline" 2>/dev/null || :   # sem \n final o read dá rc 1 mas ATRIBUI
        if [[ "$dl" =~ ^[0-9]+$ ]] && (( EPOCHSECONDS > dl )); then
          alog "slot $i MORTO no teto de wall-clock (${cap:-?}s): $(jq -r '.id // .reqid // .target // "?"' <<<"${SLOT_META[i]:-null}" 2>/dev/null)"
          _kill_tree "$pid"
          _report_slot_killed "$i" "teto de wall-clock: ${cap:-?}s"
          SLOT_PID[i]=0; SLOT_ALLOC[i]=""; SLOT_RELEASED[i]=""
          rm -rf "${SLOT_TMP[i]}" 2>/dev/null; SLOT_TMP[i]=""
        fi
      fi
    fi
    (( SLOT_PID[i] == 0 )) && FREE=$((FREE+1))
  done
  return 0
}

# _config_adopt <config-json> : config nova do servidor. Se ela é a MESMA que já está aplicada
# (partition/reserve/disabled iguais; só o hash mudou — ex.: o servidor passou a hashear só os
# três campos, ou o admin salvou a entrada sem mudar nada), adota o hash NA HORA, sem drenar.
# Diferente ⇒ agenda (PENDING_CFG) e drena, como sempre.
_config_adopt() {
  local cfg="$1" p r d h
  IFS=$'\x01' read -r p r d h < <(jq -j '[(.partition // "off"), ((.reserve // 0)|tostring),
      ((.disabled // false)|tostring), (.cfg_hash // "")] | join("\u0001")' <<<"$cfg" 2>/dev/null)
  local cur_d=false; [[ "$CFG_DISABLED" == true ]] && cur_d=true
  if [[ "$p" == "$CFG_PARTITION" && "$r" == "${CFG_RESERVE:-0}" && "$d" == "$cur_d" ]]; then
    AGENT_CFG_HASH="$h"; _save_state
    alog "config do servidor igual à aplicada (hash $h) — adotada sem drenar"
    return 0
  fi
  PENDING_CFG="$cfg"
  alog "config nova do servidor ($(jq -c 'del(.cfg_hash)' <<<"$cfg" 2>/dev/null)) — drenando slots p/ aplicar"
}

# _beat_dispatch <resp> : trata a resposta de UM heartbeat (comando urgente, config, comando,
# update, lote de jobs). CLAIMABLE (global, calculado ANTES do beat) diz quantos slots o servidor
# pôde preencher — e o que ele reivindicou É DESPACHADO mesmo que o beat tenha trazido `config`
# (bug (b), 24/09/2026: o `[[ -z $PENDING_CFG ]]` de antes descartava o lote; os jobs ficavam em
# assigned/ até o ASSIGN_TTL de 900 s). A drenagem começa no beat SEGUINTE (CLAIMABLE=0).
_beat_dispatch() {
  local resp="$1" cmd cfg upd jobs job i jt uact
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
        FREE=$N_SLOTS
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
  # config nova do admin: igual à aplicada ⇒ só o hash; diferente ⇒ agenda e DRENA (aplica
  # quando todos os slots esvaziarem; com o teto dinâmico + kill, a drenagem SEMPRE converge)
  cfg="$(jq -c '.config // empty' <<<"$resp" 2>/dev/null)"
  [[ -n "$cfg" && "$cfg" != null ]] && _config_adopt "$cfg"
  (( CLAIMABLE > 0 )) || return 0
  upd="$(jq -c '.update // empty' <<<"$resp" 2>/dev/null)"
  if [[ -n "$cmd" && "$cmd" != null ]]; then
    if [[ "$(jq -r '.action // ""' <<<"$cmd")" == clearcache ]]; then
      PENDING_CMD="$cmd"; alog "clearcache agendado — drenando slots p/ executar"
    else
      _dispatch_wide command "$cmd"
    fi
  elif [[ -n "$upd" && "$upd" != null ]]; then
    _dispatch_wide update "$upd"
  else
    # LOTE: o servidor devolve assigned como array (até free_slots) ou escalar (legado)
    jobs="$(jq -c '(.assigned // empty) | if type=="array" then .[] else . end' <<<"$resp" 2>/dev/null)"
    while IFS= read -r job; do
      [[ -n "$job" && "$job" != null ]] || continue
      _dispatch_wide job "$job" || break
    done <<<"$jobs"
  fi
  return 0
}

# _dispatch_wide <job|update|command> <json> : põe o trabalho em slot(s). Com `test_cpus` no JSON
# (servidor novo) aloca a LARGURA k (alloc_slots: job = até par_max grupos; calibração = 1 grupo)
# e entrega o paralelismo ao build-and-test pelo ambiente (MOJ_TEST_CPUS/MOJ_PARALLEL/
# MOJ_CPU_GROUPS/MOJ_RELEASE_FILE); sem `test_cpus` (servidor antigo) é o caminho de sempre: 1
# slot, sem env. Não coube ⇒ /judge/decline (rc 1: o lote para — o próximo também não cabe).
_dispatch_wide() {
  local kind="$1" j="$2" i jt tc numa par cap p pid union gs P label
  IFS=$'\x01' read -r tc numa par cap label < <(jq -j '[((.test_cpus // "")|tostring), ((.same_numa // false)|tostring),
      ((.par_max // 1)|tostring), ((.par_cap // .par_max // 1)|tostring),
      (.id // .reqid // .action // .cmdid // "?")] | join("\u0001")' <<<"$j" 2>/dev/null)
  if [[ -z "$tc" ]]; then   # LEGADO: 1 slot, sem env de paralelismo
    i="$(_free_slot)" || return 1
    jt="$AGENT_WORK/s$i.$EPOCHSECONDS.$RANDOM"; mkdir -p "$jt"
    case "$kind" in
      job)     TMPDIR="$jt" run_job "$j" "${SLOT_CPUS[i]}" 8>&- & SLOT_PID[i]=$!
               SLOT_KIND[i]=job; SLOT_META[i]="$(jq -c '{id,contest,problem_id,login,lang}' <<<"$j" 2>/dev/null)" ;;
      update)  TMPDIR="$jt" run_update "$j" "${SLOT_CPUS[i]}" 8>&- & SLOT_PID[i]=$!
               SLOT_KIND[i]=update; SLOT_META[i]="$(jq -c '{reqid,repo,kind,target}' <<<"$j" 2>/dev/null)" ;;
      command) TMPDIR="$jt" run_command "$j" "${SLOT_CPUS[i]}" 8>&- & SLOT_PID[i]=$!
               SLOT_KIND[i]=command; SLOT_META[i]="" ;;
    esac
    SLOT_TMP[i]="$jt"; SLOT_ALLOC[i]=""; SLOT_RELEASED[i]=""
    alog "$kind reivindicado $label -> slot $i${SLOT_CPUS[i]:+ [cpus ${SLOT_CPUS[i]}]} pid ${SLOT_PID[i]}"
    return 0
  fi
  local ny=n; [[ "$numa" == true ]] && ny=y
  # calibração: um teste por vez em k CPUs; os `par_max` grupos que o servidor der viram RAIAS (soluções em
  # paralelo) — só com o calibreitor que as tem (o nome MOJ_CALIB_LANES no arquivo) e AGENT_CALIB_LANES≠0
  [[ "$kind" == job ]] || { _calib_lanes_ok || par=1; cap=$par; }
  if ! alloc_slots "$tc" "$par" "$ny" "$cap"; then
    _decline "$kind" "$j" "sem $tc cpu(s) livres$([[ "$ny" == y ]] && printf ' num nó NUMA')"
    return 1
  fi
  _alloc_env; P=${#ALLOC_GROUPS[@]}; union="$ALLOC_UNION"; gs="$ALLOC_GROUPS_STR"
  p="${ALLOC_SLOTS[0]}"
  jt="$AGENT_WORK/s$p.$EPOCHSECONDS.$RANDOM"; mkdir -p "$jt"
  case "$kind" in
    job)     MOJ_TEST_CPUS="$tc" MOJ_PARALLEL="$P" MOJ_CPU_GROUPS="$gs" MOJ_RELEASE_FILE="$jt/released" \
               TMPDIR="$jt" run_job "$j" "$union" 8>&- & pid=$!
             _slot_take "$pid" job "$(jq -c '{id,contest,problem_id,login,lang}' <<<"$j" 2>/dev/null)" "$jt" ;;
    update)  MOJ_TEST_CPUS="$tc" MOJ_PARALLEL=1 MOJ_CPU_GROUPS="$gs" \
               TMPDIR="$jt" run_update "$j" "$union" 8>&- & pid=$!
             _slot_take "$pid" update "$(jq -c '{reqid,repo,kind,target}' <<<"$j" 2>/dev/null)" "$jt" ;;
    command) MOJ_TEST_CPUS="$tc" MOJ_PARALLEL=1 MOJ_CPU_GROUPS="$gs" \
               TMPDIR="$jt" run_command "$j" "$union" 8>&- & pid=$!
             _slot_take "$pid" command "" "$jt" ;;
  esac
  alog "$kind reivindicado $label -> slots ${ALLOC_SLOTS[*]} (k=$tc, $P grupo(s)${gs:+: $gs}) pid $pid"
  return 0
}

# _calib_lanes_ok : esta calibração pode usar raias? (o calibreitor local as tem e o operador não desligou)
_calib_lanes_ok() {
  [[ "${AGENT_CALIB_LANES:-1}" != 0 ]] && grep -q MOJ_CALIB_LANES "$MOJTOOLS_DIR/calibreitor.sh" 2>/dev/null
}

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
# specs da máquina medidas UMA vez, aqui (processo principal, nunca pinado) — ver register.
AGENT_SPECS="$(agent_specs_json)"
# ordem de precedência da config no BOOT (P5/P6): 1) config do SERVIDOR (resposta do register
# boot:true); 2) estado PERSISTIDO da última aplicada (agent-state.json); 3) agent.env.
_load_state || true
build_slots "$CFG_PARTITION" "$CFG_RESERVE"
# boot:true => servidor re-enfileira o que estava atribuído a este host + manda config.
# INSISTIR até registrar DE VERDADE (resposta validada): operar sem register real deixa os
# claims do agente anterior fantasmas (sem requeue) — e o heartbeat os manteria vivos p/ sempre.
until register 1; do alog "register de boot falhou — nova tentativa em 30s"; sleep 30; done
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
local state hstatus resp
while true; do
  # reap por slot + teto de wall-clock + contagem de livres (FREE)
  _reap_slots
  _pending_register   # um slot pediu re-registro (inventário mudou) — quem registra é o laço

  # DRENADO (todos livres): aplica config pendente, executa comando exclusivo, roda o GC
  if (( FREE == N_SLOTS )); then
    if [[ -n "$PENDING_CMD" ]]; then run_command "$PENDING_CMD"; PENDING_CMD=""; fi
    if [[ -n "$PENDING_CFG" ]]; then apply_config "$PENDING_CFG"; PENDING_CFG=""
      FREE=$N_SLOTS   # slots recém-reconstruídos, todos livres
    fi
    [[ -z "$PENDING_CMD" && -z "$PENDING_CFG" ]] && gc_cache
  fi

  # enquanto drena (config/comando pendente) ou desabilitado: não reivindica (free_slots=0)
  CLAIMABLE=$FREE
  { [[ -n "$PENDING_CFG" || -n "$PENDING_CMD" || "$CFG_DISABLED" == true ]]; } && CLAIMABLE=0
  state=busy; (( CLAIMABLE > 0 )) && state=free
  # status HONESTO: o servidor/UI distinguem "drenando/desabilitado" de "rodando job" —
  # antes ambos eram só state=busy e viravam o "unknown_busy" indecifrável do incidente.
  hstatus=ok
  [[ -n "$PENDING_CFG" || -n "$PENDING_CMD" ]] && hstatus=draining
  [[ "$CFG_DISABLED" == true ]] && hstatus=disabled

  resp="$(_api /judge/heartbeat \
    "$(jq -cn --arg h "$AGENT_HOST" --arg s "$state" --arg ih "$INVHASH" --arg ch "$AGENT_CFG_HASH" \
       --argjson fs "$CLAIMABLE" --argjson ts "$N_SLOTS" --arg st "$hstatus" \
       --argjson sc "${SLOT_CPUS_MIN:-1}" --argjson mfg "$( (( CLAIMABLE > 0 )) && _max_free_group || echo 0 )" \
       '{host:$h, state:$s, inv_hash:$ih, cfg_hash:$ch, free_slots:$fs, total_slots:$ts, status:$st,
         slot_cpus:$sc, max_free_group:$mfg}')")"
  [[ -n "$resp" ]] && _beat_dispatch "$resp"
  sleep "$HEARTBEAT_SECS"
done
}

# executado direto -> roda o loop; "sourced" (testes) -> só expõe as funções.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && moj_agent_main
