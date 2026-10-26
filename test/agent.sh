#!/bin/bash
# test/agent.sh — o AGENTE por dentro (funções sourced; nada de rede, nada de jaula).
#
# Os cinco consertos de 24/09/2026 que a contagem de slots por CPU passou a depender:
#   (a) `_kill_tree` mata a ÁRVORE do slot atravessando grupos de processos — o `kill -- -pgid`
#       de antes não alcançava o que rodava sob `timeout` (pgroup próprio): job "morto" pelo
#       reset seguia nas CPUs do slot seguinte;
#   (b) o lote reivindicado no MESMO beat em que chega `config` é DESPACHADO (era descartado e
#       ficava em assigned/ até o ASSIGN_TTL de 900 s);
#   (c) nenhum slot pinado chama `register` (ncpu = tamanho do slot): deixa um flag e o laço registra;
#   (d) config igual à aplicada com hash novo é adotada SEM drenar (o servidor passou a hashear só
#       partition/reserve/disabled);
#   (e) `cpus:X` fatia POR NÓ NUMA: slot nunca cruza nós.
#   + o teto de wall-clock agora é imposto pelo laço (`.deadline` do slot ⇒ _kill_tree + report).
#
#   bash judge/test/agent.sh
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; JD="$(cd "$HERE/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"; kill $(jobs -p) 2>/dev/null' EXIT
pass=0; fail=0
ck(){ if eval "$2"; then echo "  ok: $1"; ((pass++)); else echo "  FAIL: $1 :: ${DBG:-}"; ((fail++)); fi; }

# ---- sysfs FALSO: 2 nós NUMA, 16 cpus, 12-15 offline em nenhum caso (todas online) ------------
mk_sysfs(){ # <online> <node0-cpulist> [<node1-cpulist>]
  rm -rf "$W/sys"; mkdir -p "$W/sys/devices/system/cpu" "$W/sys/devices/system/node/node0"
  printf '%s\n' "$1" > "$W/sys/devices/system/cpu/online"
  printf '%s\n' "$2" > "$W/sys/devices/system/node/node0/cpulist"
  [[ $# -ge 3 ]] && { mkdir -p "$W/sys/devices/system/node/node1"; printf '%s\n' "$3" > "$W/sys/devices/system/node/node1/cpulist"; }
  return 0
}
mk_sysfs "0-15" "0-3,8-11" "4-7,12-15"

printf 'mojw_teste' > "$W/token"
export WORKER_TOKEN_FILE="$W/token" JUDGE_CACHE="$W/cache" AGENT_WORK="$W/work" AGENT_HOST=t1 \
       MOJ_API=http://127.0.0.1:9/api/v1 AGENT_SYSFS="$W/sys" AGENT_STATE="$W/state.json" \
       MOJTOOLS_DIR="$W/mt" XDG_RUNTIME_DIR="$W" HEARTBEAT_SECS=1
mkdir -p "$AGENT_WORK" "$JUDGE_CACHE"
source "$JD/agent/moj-agent.sh"
alog(){ :; }                       # silêncio (o teste fala pelo ck)
_api(){ :; }; _api_file(){ :; }    # nenhuma rede
_api_ex(){ _API_CODE=200; _API_BODY='{}'; }   # (o report_tl fala direto com ele)
LOG="$W/calls"; : > "$LOG"
register(){ echo "register" >> "$LOG"; }
_post_judge_error(){ echo "judge-error $1 $6" >> "$LOG"; }

echo "== (e) build_slots cpus:X fatia POR NÓ (slot nunca cruza nós) =="
build_slots cpus:4 0
DBG="${SLOT_CPUS[*]}"
ck "4 slots de 4"                              '[[ "$N_SLOTS" == 4 ]]'
ck "nó 0 = 0,1,2,3 e 8,9,10,11"                '[[ "${SLOT_CPUS[0]}" == "0,1,2,3" && "${SLOT_CPUS[1]}" == "8,9,10,11" ]]'
ck "nó 1 = 4,5,6,7 e 12,13,14,15"              '[[ "${SLOT_CPUS[2]}" == "4,5,6,7" && "${SLOT_CPUS[3]}" == "12,13,14,15" ]]'
ck "SLOT_NODE acompanha"                       '[[ "${SLOT_NODE[*]}" == "0 0 1 1" ]]'
build_slots cpus:3 0
DBG="${SLOT_CPUS[*]}"
ck "cpus:3: o resto de CADA nó fica fora (2+2 slots, 2 cpus sobram por nó)" '[[ "$N_SLOTS" == 4 && "${SLOT_CPUS[1]}" == "3,8,9" && "${SLOT_CPUS[3]}" == "7,12,13" ]]'
ck "…e nenhum slot mistura nós"                '[[ "${SLOT_NODE[*]}" == "0 0 1 1" ]]'
build_slots cpus:1 2
ck "reserve=2 tira as cpus 0 e 1"              '[[ "$N_SLOTS" == 14 && "${SLOT_CPUS[0]}" == 2 ]]'
mk_sysfs "0-15" "0-3,8-11" "4-7,12-15"; printf '0-11\n' > "$W/sys/devices/system/cpu/online"
build_slots cpus:2 0
DBG="${SLOT_CPUS[*]}"
ck "cpu offline não entra em slot"             '[[ "${SLOT_CPUS[*]}" != *"12"* && "$N_SLOTS" == 6 ]]'
mk_sysfs "0-15" "0-3,8-11" "4-7,12-15"
build_slots numa 0
ck "numa: 1 slot por nó, com o nó"             '[[ "$N_SLOTS" == 2 && "${SLOT_CPUS[0]}" == "0,1,2,3,8,9,10,11" && "${SLOT_NODE[1]}" == 1 ]]'
build_slots off 0
ck "off: 1 slot sem pin"                       '[[ "$N_SLOTS" == 1 && -z "${SLOT_CPUS[0]}" ]]'
rm -rf "$W/sys/devices/system/node"; build_slots cpus:8 0; DBG="${SLOT_CPUS[*]}"
ck "sem topologia: pseudo-nó com tudo"         '[[ "$N_SLOTS" == 2 && "${SLOT_CPUS[1]}" == "8,9,10,11,12,13,14,15" ]]'
mk_sysfs "0-15" "0-3,8-11" "4-7,12-15"

echo "== (a) _kill_tree atravessa o pgroup do timeout =="
set -m   # como no agente: cada job em background é seu próprio grupo de processos
bash -c 'timeout 300 bash -c "sleep 300 & sleep 300; wait"; exit 0' >/dev/null 2>&1 &
P=$!; sleep 0.6
T="$(_tree_pids "$P")"
DBG="$T"
ck "a árvore tem o timeout e os dois sleeps"   '[[ "$(wc -w <<<"$T")" -ge 5 ]]'
kill -KILL -- "-$P" 2>/dev/null; sleep 0.3      # o matador ANTIGO
alive=0; for p in $T; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done
DBG="vivos=$alive"
ck "kill -- -pgid deixa a subárvore do timeout VIVA (o bug)" '(( alive >= 2 ))'
for p in $T; do kill -KILL "$p" 2>/dev/null; done   # limpa
bash -c 'timeout 300 bash -c "sleep 300 & sleep 300; wait"; exit 0' >/dev/null 2>&1 &
P=$!; sleep 0.6
T="$(_tree_pids "$P")"
_kill_tree "$P"; sleep 0.3
alive=0; for p in $T; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done
DBG="vivos=$alive"
ck "_kill_tree: ninguém sobrevive"             '(( alive == 0 ))'
set +m

echo "== teto de wall-clock: o LAÇO mata e reporta =="
build_slots cpus:1 0
jt="$AGENT_WORK/s0.x"; mkdir -p "$jt"
( TMPDIR="$jt" _slot_deadline 300 )
ck "_slot_deadline grava epoch-limite + cap"   '[[ "$(cut -d" " -f2 "$jt/.deadline")" == 300 && "$(cut -d" " -f1 "$jt/.deadline")" -gt "$EPOCHSECONDS" ]]'
sleep 300 & SLOT_PID[0]=$!; SLOT_TMP[0]="$jt"; SLOT_KIND[0]=job
SLOT_META[0]='{"id":"j9","contest":"c","problem_id":"o#p","login":"l","lang":"c"}'
_reap_slots
ck "prazo no futuro: o slot segue vivo"        '[[ "${SLOT_PID[0]}" != 0 ]] && kill -0 "${SLOT_PID[0]}" 2>/dev/null && [[ "$FREE" == $((N_SLOTS-1)) ]]'
printf '%s 300' "$((EPOCHSECONDS-1))" > "$jt/.deadline"
pid="${SLOT_PID[0]}"; _reap_slots; sleep 0.2
ck "prazo vencido: morto, slot livre"          '! kill -0 "$pid" 2>/dev/null && [[ "${SLOT_PID[0]}" == 0 && "$FREE" == "$N_SLOTS" ]]'
ck "…reportado como Judge Error com o teto"    'grep -q "judge-error j9 Judge Error (teto de wall-clock: 300s)" "$LOG"'
ck "…TMPDIR do job removido"                   '[[ ! -d "$jt" ]]'
( TMPDIR="$W/nada" _slot_deadline 10 )
ck "sem TMPDIR válido não grava nada"          '[[ ! -e "$W/nada/.deadline" ]]'

echo "== (b) config + assigned no MESMO beat: o lote é despachado =="
: > "$LOG"; build_slots cpus:1 0
run_job(){ echo "run_job $(jq -r .id <<<"$1")" >> "$LOG"; sleep 30; }
CFG_PARTITION=cpus:1; CFG_RESERVE=0; CFG_DISABLED=false; AGENT_CFG_HASH=old; PENDING_CFG=""; PENDING_CMD=""
CLAIMABLE=$N_SLOTS
_beat_dispatch '{"assigned":[{"id":"j1","problem_id":"o#p","lang":"c"},{"id":"j2","problem_id":"o#p","lang":"c"}],
                 "config":{"partition":"cpus:2","reserve":0,"disabled":false,"cfg_hash":"new"}}'
sleep 0.3
DBG="$(cat "$LOG")"
ck "os 2 jobs rodam (antes: descartados)"      '[[ "${SLOT_PID[0]}" != 0 && "${SLOT_PID[1]}" != 0 ]] && grep -q "run_job j1" "$LOG" && grep -q "run_job j2" "$LOG"'
ck "a config ficou pendente (drena depois)"    '[[ "$(jq -r .partition <<<"$PENDING_CFG")" == cpus:2 ]]'
ck "o hash NÃO foi adotado antes de aplicar"   '[[ "$AGENT_CFG_HASH" == old ]]'
agent_slots_kill teste >/dev/null; PENDING_CFG=""

echo "== (d) config IGUAL à aplicada, hash novo: adota sem drenar =="
_beat_dispatch '{"config":{"partition":"cpus:1","reserve":0,"disabled":false,"cfg_hash":"h2"}}'
ck "hash adotado na hora"                      '[[ "$AGENT_CFG_HASH" == h2 && -z "$PENDING_CFG" ]]'
ck "…e persistido no estado"                   '[[ "$(jq -r .cfg_hash "$AGENT_STATE")" == h2 ]]'
_beat_dispatch '{"config":{"partition":"cpus:1","reserve":0,"disabled":true,"cfg_hash":"h3"}}'
ck "disabled diferente ⇒ pendente (drena)"     '[[ -n "$PENDING_CFG" && "$AGENT_CFG_HASH" == h2 ]]'
PENDING_CFG=""

echo "== (c) slot pede re-registro; o laço registra UMA vez =="
: > "$LOG"
( _request_register )   # como um subshell de slot faria
ck "flag deixado"                              '[[ -e "$AGENT_WORK/.reregister" ]]'
_pending_register; _pending_register
ck "register chamado 1× pelo laço"             '[[ "$(grep -c register "$LOG")" == 1 && ! -e "$AGENT_WORK/.reregister" ]]'
ck "run_update não chama register direto"      '! grep -q "^  register   # re-registra" "$JD/agent/moj-agent.sh" && grep -q "_request_register" "$JD/agent/moj-agent.sh"'
ck "specs medidas UMA vez (AGENT_SPECS) no boot" 'grep -q "AGENT_SPECS=\"\$(agent_specs_json)\"" "$JD/agent/moj-agent.sh" && grep -q "AGENT_SPECS:-" "$JD/agent/moj-agent.sh"'
ck "nenhum timeout(1) em volta de b-a-t/calibreitor" '! grep -qE "timeout -k" "$JD/agent/moj-agent.sh"'


# =============================== fase 3: largura k, grupos, membros, cauda, decline ==============
mk_smt(){ # irmãos SMT: c <-> c+8 (0-7 | 8-15) — como um socket de 8 núcleos com HT
  local c s; for c in $(seq 0 15); do s=$(( c < 8 ? c+8 : c-8 )); mkdir -p "$W/sys/devices/system/cpu/cpu$c/topology"
    printf '%s,%s\n' "$(( c<s ? c : s ))" "$(( c<s ? s : c ))" > "$W/sys/devices/system/cpu/cpu$c/topology/thread_siblings_list"; done; }
mk_sysfs "0-15" "0-3,8-11" "4-7,12-15"
AGENT_SPECS='{"ncpu":16}'
node_of(){ local c; for c in $(_cpus_expand "$1"); do (( c <= 3 || (c >= 8 && c <= 11) )) && printf 0 || printf 1; done; }
same_node(){ [[ "$(node_of "$1")" =~ ^(0+|1+)$ ]]; }

echo "== topologia dos slots (protocolo: slot_cpus, slots_by_node, smt) =="
build_slots cpus:1 0
ck "slot_cpus=1, 8 slots por nó, sem SMT"     '[[ "$SLOT_CPUS_MIN" == 1 && "$(jq -c . <<<"$SLOTS_BY_NODE_JSON")" == "{\"0\":8,\"1\":8}" && "$SMT_ON" == false ]]'
build_slots numa 0
ck "numa: slot_cpus=8, 1 por nó"              '[[ "$SLOT_CPUS_MIN" == 8 && "$(jq -c . <<<"$SLOTS_BY_NODE_JSON")" == "{\"0\":1,\"1\":1}" ]]'
build_slots off 0
ck "off: slot_cpus = ncpu (16), 1 slot"       '[[ "$SLOT_CPUS_MIN" == 16 && "$(jq -c . <<<"$SLOTS_BY_NODE_JSON")" == "{\"-\":1}" ]]'
ck "register manda slot_cpus/slots_by_node/smt" 'grep -q "slot_cpus:\$sc, slots_by_node:\$sbn, smt:\$smt" "$JD/agent/moj-agent.sh"'
ck "heartbeat manda slot_cpus/max_free_group" 'grep -q "slot_cpus:\$sc, max_free_group:\$mfg" "$JD/agent/moj-agent.sh"'

echo "== alloc_slots: slots de 1 cpu, 2 nós =="
build_slots cpus:1 0
alloc_slots 2 2 n; DBG="${ALLOC_GROUPS[*]} / ${ALLOC_SLOTS[*]}"
ck "k=2 P=2: 2 grupos de 2, 4 slots"          '[[ "${#ALLOC_GROUPS[@]}" == 2 && "${#ALLOC_SLOTS[@]}" == 4 ]]'
ck "cada grupo dentro de um nó"               'same_node "${ALLOC_GROUPS[0]}" && same_node "${ALLOC_GROUPS[1]}"'
alloc_slots 4 1 y; DBG="${ALLOC_GROUPS[*]}"
ck "k=4 numa: 1 grupo de 4 num nó"            '[[ "${#ALLOC_GROUPS[@]}" == 1 && "$(_cpus_expand "${ALLOC_GROUPS[0]}" | wc -w)" == 4 ]] && same_node "${ALLOC_GROUPS[0]}"'
ck "k=9 numa=y: não cabe em nó nenhum ⇒ rc 1" '! alloc_slots 9 1 y'
alloc_slots 9 1 n; DBG="${ALLOC_GROUPS[*]}"
ck "k=9 sem numa: sobras de 2 nós compõem"    '[[ "${#ALLOC_GROUPS[@]}" == 1 && "$(_cpus_expand "${ALLOC_GROUPS[0]}" | wc -w)" == 9 && "${#ALLOC_SLOTS[@]}" == 9 ]]'
alloc_slots 1 2 n 4; DBG="${ALLOC_GROUPS[*]}"
ck "P limita grupos de slot NOVO (k=1 P=2 cap=4 ⇒ 2)" '[[ "${#ALLOC_GROUPS[@]}" == 2 ]]'
for i in 0 1 2 3 4 5 6 7; do SLOT_PID[i]=99; done   # nó 0 inteiro ocupado (slots 0-7 = cpus 0-3,8-11)
alloc_slots 2 4 y; DBG="${ALLOC_GROUPS[*]}"
ck "slot ocupado não entra: tudo no nó 1"     '[[ "${#ALLOC_GROUPS[@]}" == 4 ]] && [[ "$(node_of "${ALLOC_GROUPS[*]// /,}")" =~ ^1+$ ]]'
ck "_max_free_group = 8 (nó 1 livre)"         '[[ "$(_max_free_group)" == 8 ]]'
ck "k=16: só 8 livres ⇒ rc 1"                 '! alloc_slots 16 1 n'
for i in 0 1 2 3 4 5 6 7; do SLOT_PID[i]=0; done

echo "== alloc_slots: partition numa (slot > k): sobra do slot vira grupo de graça =="
build_slots numa 0
alloc_slots 4 1 n 4; DBG="${ALLOC_GROUPS[*]} / ${ALLOC_SLOTS[*]}"
ck "1 slot consumido, 2 grupos de 4 (8 cpus)" '[[ "${#ALLOC_SLOTS[@]}" == 1 && "${#ALLOC_GROUPS[@]}" == 2 ]]'
alloc_slots 4 1 n 1
ck "cap=1 corta em 1 grupo"                   '[[ "${#ALLOC_GROUPS[@]}" == 1 ]]'
alloc_slots 1 2 n 4; DBG="${ALLOC_GROUPS[*]} / ${ALLOC_SLOTS[*]}"
ck "k=1 P=2 cap=4: 4 grupos de 1 no MESMO slot (P só conta slot novo)" '[[ "${#ALLOC_GROUPS[@]}" == 4 && "${#ALLOC_SLOTS[@]}" == 1 ]]'
build_slots off 0
alloc_slots 2 1 n 4; DBG="${ALLOC_GROUPS[*]} / ${ALLOC_SLOTS[*]}"
ck "off: sem pin, min(cap, ncpu/k)=4 grupos vazios" '[[ "${#ALLOC_GROUPS[@]}" == 4 && -z "${ALLOC_GROUPS[0]}" && "${ALLOC_SLOTS[*]}" == 0 ]]'
_alloc_env
ck "off: MOJ_CPU_GROUPS vazio, união vazia"   '[[ -z "$ALLOC_GROUPS_STR" && -z "$ALLOC_UNION" ]]'

echo "== alloc_slots com SMT: k ≥ 2 = núcleos inteiros =="
mk_smt; build_slots cpus:1 0
ck "SMT detectado"                            '[[ "$SMT_ON" == true && "${CPU_SIB[0]}" == 8 && "${CPU_SIB[12]}" == 4 ]]'
alloc_slots 2 1 n; DBG="${ALLOC_GROUPS[*]}"
ck "k=2: o grupo é um núcleo (c, c+8)"        '[[ "${#ALLOC_GROUPS[@]}" == 1 ]] && { read -r a b < <(_cpus_expand "${ALLOC_GROUPS[0]}"); (( b == a + 8 )); }'
alloc_slots 3 1 n; DBG="${ALLOC_GROUPS[*]}"
ck "k=3: 2 núcleos inteiros = 4 cpus, 4 slots" '[[ "$(_cpus_expand "${ALLOC_GROUPS[0]}" | wc -w)" == 4 && "${#ALLOC_SLOTS[@]}" == 4 ]]'
SLOT_PID[4]=99   # slot 4 = cpu 8, o irmão da cpu 0, ocupado
alloc_slots 2 4 y; DBG="${ALLOC_GROUPS[*]}"
ck "cpu sem irmão livre fica de fora"         '! grep -qw 0 <<<"${ALLOC_GROUPS[*]//,/ }" && [[ "${#ALLOC_GROUPS[@]}" == 4 ]]'
alloc_slots 1 4 n; DBG="${ALLOC_GROUPS[*]}"
ck "k=1: sem pareamento (4 grupos de 1)"       '[[ "${#ALLOC_GROUPS[@]}" == 4 && "$(_cpus_expand "${ALLOC_GROUPS[0]}" | wc -w)" == 1 ]]'
SLOT_PID[4]=0
rm -rf "$W/sys/devices/system/cpu/cpu"*; mk_sysfs "0-15" "0-3,8-11" "4-7,12-15"

echo "== primário/membros, liberação de cauda =="
build_slots cpus:1 0
alloc_slots 2 2 n; _alloc_env
jt="$AGENT_WORK/s9.t"; mkdir -p "$jt"; sleep 300 & tp=$!
_slot_take "$tp" job '{"id":"jw"}' "$jt"; p="$TAKEN_PRIMARY"
DBG="p=$p alloc=${SLOT_ALLOC[p]} slots=${ALLOC_SLOTS[*]}"
ck "primário = 1º slot alocado, com pid/tmp/kind"  '[[ "$p" == "${ALLOC_SLOTS[0]}" && "${SLOT_PID[p]}" == "$tp" && "${SLOT_TMP[p]}" == "$jt" && "${SLOT_KIND[p]}" == job ]]'
m="${ALLOC_SLOTS[1]}"
ck "membro: mesmo pid, kind=member, meta=primário, sem tmp" '[[ "${SLOT_PID[m]}" == "$tp" && "${SLOT_KIND[m]}" == member && "${SLOT_META[m]}" == "$p" && -z "${SLOT_TMP[m]}" ]]'
ck "SLOT_ALLOC = 2 slots por grupo, 2 grupos"  '[[ "$(tr "|" "\n" <<<"${SLOT_ALLOC[p]}" | wc -l)" == 2 && "$(cut -d"|" -f1 <<<"${SLOT_ALLOC[p]}" | wc -w)" == 2 ]]'
_reap_slots
ck "reap: 4 ocupados"                          '[[ "$FREE" == $((N_SLOTS-4)) ]]'
g1="$(cut -d"|" -f2 <<<"${SLOT_ALLOC[p]}")"
printf '1\n1\n0\n7\n' > "$jt/released"
_reap_slots
DBG="g1=$g1 free=$FREE"
ck "cauda: grupo 1 liberou seus 2 slots; grupo 0 (e 7, inexistente) não" '[[ "$FREE" == $((N_SLOTS-2)) ]] && for s in $g1; do [[ "${SLOT_PID[s]}" == 0 ]] || exit 1; done && [[ "${SLOT_PID[p]}" == "$tp" ]]'
_reap_slots
ck "idempotente"                               '[[ "$FREE" == $((N_SLOTS-2)) ]]'
kill "$tp" 2>/dev/null; sleep 0.2; _reap_slots
ck "job morre ⇒ primário e membros livres"    '[[ "$FREE" == "$N_SLOTS" && ! -d "$jt" ]]'

echo "== partition numa: cauda só solta o slot quando nenhum grupo vivo o usa =="
build_slots numa 0
alloc_slots 4 1 n 4; _alloc_env; jt="$AGENT_WORK/s0.n"; mkdir -p "$jt"; sleep 300 & tp=$!
_slot_take "$tp" job '{"id":"jn"}' "$jt"; p="$TAKEN_PRIMARY"
printf '1\n' > "$jt/released"; _reap_slots
ck "grupos 0 e 1 no mesmo slot: liberar o 1 NÃO solta o slot" '[[ "${SLOT_PID[p]}" == "$tp" && "$FREE" == 1 ]]'
kill "$tp" 2>/dev/null; sleep 0.2; _reap_slots

echo "== _dispatch_wide: env p/ o build-and-test, pin na união, decline, legado =="
build_slots cpus:1 0
run_job(){ echo "run_job id=$(jq -r .id <<<"$1") pin=$2 k=${MOJ_TEST_CPUS:-unset} P=${MOJ_PARALLEL:-unset} groups=${MOJ_CPU_GROUPS:-unset} rel=${MOJ_RELEASE_FILE:-unset}" >> "$LOG"; sleep 30; }
run_update(){ echo "run_update reqid=$(jq -r .reqid <<<"$1") pin=$2 k=${MOJ_TEST_CPUS:-unset} P=${MOJ_PARALLEL:-unset} groups=${MOJ_CPU_GROUPS:-unset}" >> "$LOG"; sleep 30; }
_api(){ echo "api $1 $2" >> "$LOG"; }
: > "$LOG"
_dispatch_wide job '{"id":"j5","problem_id":"o#p","lang":"c","test_cpus":2,"same_numa":true,"par_max":2,"par_cap":4}'
sleep 0.3; DBG="$(cat "$LOG")"
ck "job largo: k=2 P=2 grupos e release file"  'grep -Eq "run_job id=j5 pin=[0-9,]+ k=2 P=2 groups=[0-9]+,[0-9]+\|[0-9]+,[0-9]+ rel=$AGENT_WORK/s[0-9]+\.[0-9]+\.[0-9]+/released" "$LOG"'
ck "pin = união das 4 cpus"                    '[[ "$(grep -o "pin=[0-9,]*" "$LOG" | cut -d= -f2 | tr "," "\n" | wc -l)" == 4 ]]'
_reap_slots; ck "4 slots ocupados"             '[[ "$FREE" == $((N_SLOTS-4)) ]]'
_dispatch_wide update '{"reqid":"r1","kind":"calibrate","target":"o#p","test_cpus":3,"same_numa":false}'
sleep 0.3; DBG="$(cat "$LOG")"
ck "calibração larga: k=3, P=1, 1 grupo de 3"  'grep -Eq "run_update reqid=r1 pin=[0-9,]+ k=3 P=1 groups=[0-9]+,[0-9]+,[0-9]+$" "$LOG"'
: > "$LOG"
_dispatch_wide job '{"id":"j6","problem_id":"o#p","lang":"c"}'
sleep 0.3; DBG="$(cat "$LOG")"
ck "job LEGADO (sem test_cpus): 1 slot, sem env" 'grep -Eq "run_job id=j6 pin=[0-9]+ k=unset P=unset groups=unset rel=unset" "$LOG"'
for i in "${!SLOT_PID[@]}"; do (( SLOT_PID[i] == 0 )) && SLOT_PID[i]=77; done   # tudo ocupado
: > "$LOG"
_dispatch_wide job '{"id":"j7","problem_id":"o#p","lang":"c","test_cpus":2,"par_max":1}'; rc=$?
DBG="$(cat "$LOG")"
ck "não coube ⇒ decline com id e rc 1"         '[[ $rc == 1 ]] && grep -q "api /judge/decline" "$LOG" && grep -q "\"id\":\"j7\"" "$LOG" && grep -q "sem 2 cpu(s) livres" "$LOG"'
agent_slots_kill teste >/dev/null; for i in "${!SLOT_PID[@]}"; do SLOT_PID[i]=0; done

echo "== raias da calibração (26/10/2026): o par_max do servidor vira grupos só com o calibreitor que as tem =="
mkdir -p "$W/mt"; printf '# MOJ_CALIB_LANES: raias\n' > "$W/mt/calibreitor.sh"
: > "$LOG"
_dispatch_wide update '{"reqid":"r2","kind":"calibrate","target":"o#p","test_cpus":1,"same_numa":false,"par_max":3,"par_cap":3}'
sleep 0.3; DBG="$(cat "$LOG")"
ck "calibreitor com raias + par_max 3: 3 grupos de 1 CPU, MOJ_PARALLEL 1" 'grep -Eq "run_update reqid=r2 pin=[0-9,]+ k=1 P=1 groups=[0-9]+\|[0-9]+\|[0-9]+$" "$LOG"'
_reap_slots; ck "…e ocupa 3 slots até o fim"   '[[ "$FREE" == $((N_SLOTS-3)) ]]'
agent_slots_kill teste >/dev/null; for i in "${!SLOT_PID[@]}"; do SLOT_PID[i]=0; done
: > "$W/mt/calibreitor.sh"; : > "$LOG"
_dispatch_wide update '{"reqid":"r3","kind":"calibrate","target":"o#p","test_cpus":1,"same_numa":false,"par_max":3,"par_cap":3}'
sleep 0.3; DBG="$(cat "$LOG")"
ck "calibreitor SEM raias (mojtools antigo): 1 grupo" 'grep -Eq "run_update reqid=r3 pin=[0-9]+ k=1 P=1 groups=[0-9]+$" "$LOG"'
agent_slots_kill teste >/dev/null; for i in "${!SLOT_PID[@]}"; do SLOT_PID[i]=0; done
printf '# MOJ_CALIB_LANES: raias\n' > "$W/mt/calibreitor.sh"; : > "$LOG"
AGENT_CALIB_LANES=0 _dispatch_wide update '{"reqid":"r4","kind":"calibrate","target":"o#p","test_cpus":1,"same_numa":false,"par_max":3,"par_cap":3}'
sleep 0.3; DBG="$(cat "$LOG")"
ck "AGENT_CALIB_LANES=0: 1 grupo"               'grep -Eq "run_update reqid=r4 pin=[0-9]+ k=1 P=1 groups=[0-9]+$" "$LOG"'
agent_slots_kill teste >/dev/null; for i in "${!SLOT_PID[@]}"; do SLOT_PID[i]=0; done
rm -f "$W/mt/calibreitor.sh"

echo "== local que usa a variável declarada na MESMA linha (28/09/2026: o agente morria com job rodando) =="
# o bash expande todas as palavras do `local` antes de atribuir: `local p="$1" f="${SLOT_TMP[p]}"` lia um `p`
# inexistente e, sob `set -u`, matava o agente. Aqui as funções rodam num bash LIMPO (sem p/i globais, que o
# restante deste teste deixa definidos e escondiam o bug).
F="$(mktemp)"; sed -n '/^_release_tail() {/,/^}/p; /^_report_slot_killed() {/,/^}/p' "$JD/agent/moj-agent.sh" > "$F"
out="$(bash -c 'set -u; declare -a SLOT_TMP SLOT_ALLOC SLOT_RELEASED SLOT_KIND SLOT_META; SLOT_TMP[3]=/nao/existe; SLOT_ALLOC[3]="3|4"; SLOT_RELEASED[3]=" "; source "$1"; _release_tail 3 && _report_slot_killed 3 teste && echo ok' _ "$F" 2>&1)"; rm -f "$F"
DBG="$out"; ck "_release_tail e _report_slot_killed rodam sob set -u sem p/i globais" '[[ "$out" == ok ]]'

echo "== métodos de TL (26/10/2026): a tabela com as metades MOJ e Kattis, tetos e auto-cura =="
# a tabela nova do calibreitor (mojtools tl-methods.sh) e uma de antes (só TL[])
TN="$W/tlnovo"; printf '#x\nTL[c]=.3035\nTL[default]=.3035\n# Kattis\ndeclare -A TLKATTIS\nTLKATTIS[c]=3\nTLKATTIS[default]=3\n' > "$TN"
TV="$W/tlvelho"; printf 'TL[c]=.3035\nTL[default]=.3035\n' > "$TV"
DBG="$(tl_to_json "$TN") $(tl_to_json "$TN" TLKATTIS)"
ck "tl_to_json: as duas metades da tabela nova"  '[[ "$(tl_to_json "$TN" | jq -c .)" == "{\"c\":\".3035\",\"default\":\".3035\"}" && "$(tl_to_json "$TN" TLKATTIS | jq -c .)" == "{\"c\":\"3\",\"default\":\"3\"}" ]]'
ck "tabela antiga: metade Kattis vazia, sem morrer" '[[ "$(tl_to_json "$TV" TLKATTIS)" == "{}" && "$(tl_to_json "$TV" | jq -r .c)" == ".3035" ]]'
mkdir -p "$W/mt"; : > "$W/mt/tl-methods.sh"
ck "_tl_has_method: kattis exige a metade nova"  '_tl_has_method "$TN" kattis && ! _tl_has_method "$TV" kattis && _tl_has_method "$TV" moj && _tl_has_method "$TV" ""'
rm -f "$W/mt/tl-methods.sh"
ck "…e não exige com mojtools sem tl-methods.sh (recalibrar não a criaria)" '_tl_has_method "$TV" kattis'
: > "$W/mt/tl-methods.sh"
# _job_cap: 100 testes; o Kattis (3 s) dá teto maior que o MOJ (0,3035 s)
PK="$W/pkgcap"; mkdir -p "$PK/tests/input"; for i in $(seq 1 100); do : > "$PK/tests/input/t$i"; done
cp "$TN" "$PK/tl.t1"; : > "$PK/conf"
cm="$(_job_cap "$PK" c)"; ckt="$(_job_cap "$PK" c kattis)"
DBG="moj=$cm kattis=$ckt"
ck "_job_cap: moj = (0,3035+2,2)×100×2+90; kattis = (3+2,2)×100×2+90" '[[ "$cm" == 590 && "$ckt" == 1130 ]]'
printf 'TLMETHOD=kattis\n' > "$PK/conf"
ck "_job_cap: sem método no job, vale o TLMETHOD do conf; o job vence o conf" '[[ "$(_job_cap "$PK" c)" == 1130 && "$(_job_cap "$PK" c moj)" == 590 ]]'
printf 'TLMETHOD=kattis\nTLMOD[c.mult]=2\n' > "$PK/conf"
ck "_job_cap: TLMOD mult entra (Kattis 3 × 2 = 6)" '[[ "$(_job_cap "$PK" c)" == 1730 ]]'
# _calib_cap: 10 testes × 2 soluções; full = piso do Kattis (1,5 × ⌈2 × 5⌉ + 0,5 = 15,5 s por teste)
PC="$W/pkgcal"; mkdir -p "$PC/tests/input" "$PC/sols/good" "$PC/sols/slow"; for i in $(seq 1 10); do : > "$PC/tests/input/t$i"; done
: > "$PC/sols/good/a.c"; : > "$PC/sols/slow/s.c"; : > "$PC/conf"
cq="$(_calib_cap "$PC" 0)"; cf="$(_calib_cap "$PC" 1)"; DBG="rápida=$cq completa=$cf"
ck "_calib_cap: rápida = 7,2 s/teste (só good: 7,2×10×1×2+30+120); completa = 15,5 s/teste" '[[ "$cq" == 300 && "$cf" == 800 ]]'
printf 'KATTIS_TIME_LIMIT_TO_TLE=50\n' > "$PC/conf"
ck "_calib_cap: o piso para em 30 s por teste" '[[ "$(_calib_cap "$PC" 1)" == 1380 ]]'
# auto-cura: job kattis com tabela sem a metade Kattis recalibra (rápido) antes de julgar; moj não
_api_get(){ printf '{"exists":true,"checksum":"cks1"}'; }
cat > "$W/mt/calibreitor.sh" <<'EOC'
echo "calib $*" >> "$CAL_LOG"
printf 'TL[c]=.3035\nTL[default]=.3035\ndeclare -A TLKATTIS\nTLKATTIS[c]=3\nTLKATTIS[default]=3\n' > "$1/tl.$HOSTNAME"
EOC
export CAL_LOG="$W/cal.log"; : > "$CAL_LOG"
CD="$(cache_id_dir "o#kt")"; mkdir -p "$CD/pkg/tests/input"; : > "$CD/pkg/tests/input/t1"; : > "$CD/pkg/conf"
cp "$TV" "$CD/pkg/tl.t1"; printf '{"id":"o#kt","checksum":"cks1"}' > "$CD/.moj-cache.json"
out="$(ensure_cached "o#kt" 0 0 0 moj)"
ck "job moj com tabela antiga: cache válido, sem recalibrar" '[[ "$out" == "$CD/pkg" && ! -s "$CAL_LOG" ]]'
out="$(ensure_cached "o#kt" 0 0 0 kattis)"; DBG="$(cat "$CAL_LOG") | $(cat "$CD/pkg/tl.t1")"
ck "job kattis com tabela antiga: recalibra (rápido) e devolve o pacote" '[[ "$out" == "$CD/pkg" && "$(grep -c calib "$CAL_LOG")" == 1 ]] && grep -q "^TLKATTIS\[c\]=3" "$CD/pkg/tl.t1"'
out="$(ensure_cached "o#kt" 0 0 0 kattis)"
ck "…e o próximo job kattis não recalibra mais" '[[ "$out" == "$CD/pkg" && "$(grep -c calib "$CAL_LOG")" == 1 ]]'

echo "== a calibração disparada por um JOB não herda o MOJ_RELEASE_FILE (26/10/2026) =="
# o job de P grupos traz o arquivo de liberação; a calibração que ele dispara não pode anotar grupos
# como livres (o laço os devolveria ao escalonador com o job ainda julgando neles)
cat > "$W/mt/calibreitor.sh" <<'EOC'
echo "calib rel=${MOJ_RELEASE_FILE:-SEM} lanes=${MOJ_CALIB_LANES:-SEM}" >> "$CAL_LOG"
printf 'TL[c]=.3035\nTL[default]=.3035\n' > "$1/tl.$HOSTNAME"
EOC
: > "$CAL_LOG"
CR="$(cache_id_dir "o#rel")"; mkdir -p "$CR/pkg/tests/input"; : > "$CR/pkg/tests/input/t1"; : > "$CR/pkg/conf"
printf '{"id":"o#rel","checksum":"cks1"}' > "$CR/.moj-cache.json"
out="$(MOJ_RELEASE_FILE="$W/released" ensure_cached "o#rel" 0 0 0 moj)"; DBG="$(cat "$CAL_LOG")"
ck "calibrou sem o MOJ_RELEASE_FILE no ambiente; o interruptor das raias chega ao calibreitor" '[[ "$out" == "$CR/pkg" ]] && grep -qx "calib rel=SEM lanes=1" "$CAL_LOG"'
CR2="$(cache_id_dir "o#rel2")"; mkdir -p "$CR2/pkg/tests/input"; : > "$CR2/pkg/tests/input/t1"; : > "$CR2/pkg/conf"
printf '{"id":"o#rel2","checksum":"cks1"}' > "$CR2/.moj-cache.json"; : > "$CAL_LOG"
out="$(AGENT_CALIB_LANES=0 ensure_cached "o#rel2" 0 0 0 moj)"; DBG="$(cat "$CAL_LOG")"
ck "AGENT_CALIB_LANES=0 chega como MOJ_CALIB_LANES=0 (a calibração disparada por job também)" 'grep -qx "calib rel=SEM lanes=0" "$CAL_LOG"'

echo "== problema apagado: o 404 problem_gone é definitivo — não repete, marca, o boot pula, o GC apaga (26/10/2026) =="
# o servidor responde 404 `problem_gone` ao report de problema que não existe mais; antes o agente repetia TODO
# erro 3× (4 s por problema apagado no boot) e o re-report do boot batia nele a cada restart
mkdir -p "$W/fbin"
cat > "$W/fbin/curl" <<'EOC'
#!/bin/bash
# curl FALSO: a 1ª linha de $FAKE_ROUTES ("regex<TAB>código<TAB>corpo") cujo regex casa com "<caminho> <corpo>"
# responde; nenhuma = sem resposta (000). Cada chamada vai p/ $FAKE_LOG como "curl <caminho> <id do corpo>".
url="" data="" w="" f=0 id=""
while (( $# )); do
  case "$1" in
    -w) w="$2"; shift ;;
    --data) data="$2"; shift ;;
    --data-binary) data="$2"; [[ "$data" == @* ]] && data="$(cat "${data#@}")"; shift ;;
    -m|-H|-K|-o|--resolve) shift ;;
    --*) ;;
    -*) [[ "$1" == *f* ]] && f=1 ;;
    *) url="$1" ;;
  esac; shift
done
path="${url#*/api/v1}"; [[ "$data" =~ \"id\":\"([^\"]*)\" ]] && id="${BASH_REMATCH[1]}"
echo "curl $path $id" >> "$FAKE_LOG"; printf '%s' "$data" > "$FAKE_LOG.body.${path//[^A-Za-z0-9]/_}"
while IFS=$'\t' read -r re code body; do
  [[ -n "$re" && "$path $data" =~ $re ]] || continue
  (( code >= 400 && f )) && exit 22
  printf '%s' "$body"; [[ -n "$w" ]] && printf '\n%s' "$code"
  exit 0
done < "$FAKE_ROUTES"
[[ -n "$w" ]] && printf '\n000'
exit 7
EOC
chmod +x "$W/fbin/curl"
export FAKE_LOG="$W/fake.log" FAKE_ROUTES="$W/fake.routes"; PATH="$W/fbin:$PATH"
source <(sed -n '/^_api_ex() {/,/^}/p; /^_api() {/,/^}/p; /^_api_file() {/,/^}/p' "$JD/agent/moj-agent.sh")
sleep(){ echo "sleep $*" >> "$FAKE_LOG"; }   # as esperas entre tentativas, sem esperar
route(){ printf '%s\t%s\t%s\n' "$@" >> "$FAKE_ROUTES"; }
ncall(){ grep -c "^curl $1" "$FAKE_LOG"; }
: > "$FAKE_ROUTES"
route '^/x ' 404 '{"success":false,"error":{"code":"not_found"}}'; route '^/y ' 503 'fora'
route '^/b ' 409 '{"success":false,"error":{"code":"busy"}}'; route '^/z ' 200 '{"ok":1}'
: > "$FAKE_LOG"; _api_ex 5 /x --data '{}'; rc=$?; DBG="rc=$rc code=$_API_CODE $(cat "$FAKE_LOG")"
ck "_api_ex: 404 = UMA tentativa, rc 1, o código e o corpo lidos" '[[ $rc == 1 && "$_API_CODE" == 404 && "$(jq -r .error.code <<<"$_API_BODY")" == not_found && "$(ncall /x)" == 1 ]]'
: > "$FAKE_LOG"; _api_ex 5 /y --data '{}'; rc=$?; DBG="$(cat "$FAKE_LOG")"
ck "_api_ex: 503 = três tentativas, duas esperas de 2 s" '[[ $rc == 1 && "$(ncall /y)" == 3 && "$(grep -c "^sleep 2$" "$FAKE_LOG")" == 2 ]]'
: > "$FAKE_LOG"; _api_ex 5 /b --data '{}'; DBG="$(cat "$FAKE_LOG")"
ck "_api_ex: 409 busy (lock do servidor) repete" '[[ "$(ncall /b)" == 3 ]]'
: > "$FAKE_LOG"; _api_ex 5 /semrota --data '{}'; rc=$?
ck "_api_ex: sem resposta (000) repete" '[[ $rc == 1 && "$_API_CODE" == 000 && "$(ncall /semrota)" == 3 ]]'
: > "$FAKE_LOG"; out="$(_api /z '{}')"; rc=$?
ck "_api: 200 devolve o corpo (o contrato de sempre)" '[[ $rc == 0 && "$out" == "{\"ok\":1}" && "$(ncall /z)" == 1 ]]'
out="$(_api /x '{}')"; rc=$?
ck "_api: 4xx = rc 1 e nada no stdout" '[[ $rc == 1 && -z "$out" ]]'
printf '{}' > "$W/body.json"; : > "$FAKE_LOG"; _api_file /x "$W/body.json"; rc=$?
ck "_api_file: 404 também não repete" '[[ $rc == 1 && "$(ncall /x)" == 1 ]]'

# o cache: um vivo cujo report da calibração falhou (tl_reported:false), um apagado e um com 404 de OUTRA coisa
: > "$FAKE_ROUTES"
route '^/judge/(tl|calib)-report .*"id":"o#gone"' 404 '{"success":false,"error":{"message":"Problem not found (removed or moved)","code":"problem_gone"}}'
route '^/judge/tl-report .*"id":"o#old404"' 404 '{"success":false,"error":{"code":"not_found"}}'
route '^/judge/' 200 '{"success":true}'
for p in vivo gone old404; do
  C="$(cache_id_dir "o#$p")"; mkdir -p "$C/pkg"; cp "$TV" "$C/pkg/tl.t1"; echo log > "$C/.calib.log"
  jq -cn --arg id "o#$p" --argjson r "$( [[ $p == vivo ]] && echo false || echo true )" '{id:$id, checksum:"cks1", tl_reported:$r}' > "$C/.moj-cache.json"
done
C="$(cache_id_dir "o#old404")"; mv "$C/pkg/tl.t1" "$C/tl.t1"; rm -rf "$C/pkg" "$C/.calib.log"   # stub do GC
rm -f "$AGENT_WORK/.reregister"; : > "$FAKE_LOG"
report_cached_tls; DBG="$(cat "$FAKE_LOG")"
ck "boot: o apagado leva UM tl-report (sem repetir) e nenhum calib-report" '[[ "$(ncall "/judge/tl-report o#gone")" == 1 && "$(ncall "/judge/calib-report o#gone")" == 0 ]]'
ck "…e a entrada ficou marcada (.gone)"         '[[ -s "$JUDGE_CACHE/o_gone/.gone" ]]'
ck "404 sem problem_gone (servidor velho, rota errada) não marca" '[[ ! -e "$JUDGE_CACHE/o_old404/.gone" && "$(ncall "/judge/tl-report o#old404")" == 1 ]]'
ck "o vivo: TL e log re-reportados e o tl_reported:false vira true" '[[ "$(ncall "/judge/tl-report o#vivo")" == 1 && "$(ncall "/judge/calib-report o#vivo")" == 1 && "$(jq -r .tl_reported "$JUDGE_CACHE/o_vivo/.moj-cache.json")" == true ]]'
ck "o inventário mudou ⇒ pede re-registro"     '[[ -e "$AGENT_WORK/.reregister" ]]'
ck "inventário: sem o apagado, com o vivo"      '[[ "$(agent_problems_json | jq -c "[has(\"o#gone\"), has(\"o#vivo\")]")" == "[false,true]" ]]'
rm -f "$AGENT_WORK/.reregister"; : > "$FAKE_LOG"
report_cached_tls; DBG="$(cat "$FAKE_LOG")"
ck "2º boot: o apagado nem é tentado; nada mudou, nada a re-registrar" '! grep -q "o#gone" "$FAKE_LOG" && [[ "$(ncall "/judge/tl-report o#vivo")" == 1 && ! -e "$AGENT_WORK/.reregister" ]]'
GC_STAMP="$W/gc.stamp"; : > "$LOG"
gc_cache
ck "GC: a entrada apagada sai inteira (dir e lock); a viva fica" '[[ ! -e "$JUDGE_CACHE/o_gone" && ! -e "$JUDGE_CACHE/o_gone.lock" && -d "$JUDGE_CACHE/o_vivo/pkg" ]]'
ck "…e re-registra"                             'grep -qx register "$LOG"'

# o package-meta: `exists:false` VÁLIDO marca; sem resposta não; existir de novo tira a marca e re-reporta o TL
_api_get(){ printf '{"id":"o#vivo","exists":false,"checksum":"","tl_checksum":""}'; }
ensure_cached "o#vivo" >/dev/null; rc=$?
ck "package-meta exists:false: rc 1 e a entrada marcada" '[[ $rc == 1 && -e "$JUDGE_CACHE/o_vivo/.gone" ]]'
rm -f "$JUDGE_CACHE/o_vivo/.gone"; _api_get(){ :; }
ensure_cached "o#vivo" >/dev/null
ck "package-meta sem resposta (servidor fora) não marca" '[[ ! -e "$JUDGE_CACHE/o_vivo/.gone" ]]'
: > "$JUDGE_CACHE/o_vivo/.gone"; _api_get(){ printf '{"exists":true,"checksum":"cks1"}'; }; : > "$FAKE_LOG"
out="$(ensure_cached "o#vivo" 0 0 0 moj)"; DBG="$out | $(cat "$FAKE_LOG")"
ck "voltou a existir: a marca sai e o TL é re-reportado" '[[ "$out" == "$JUDGE_CACHE/o_vivo/pkg" && ! -e "$JUDGE_CACHE/o_vivo/.gone" && "$(ncall "/judge/tl-report o#vivo")" == 1 ]]'

# a calibração: tl_reported com o resultado REAL (era true sempre); apagado no meio = marca, sem calib-report
cat > "$W/mt/calibreitor.sh" <<'EOC'
printf 'TL[c]=.3035\nTL[default]=.3035\n' > "$1/tl.$HOSTNAME"
EOC
: > "$FAKE_ROUTES"
route '^/judge/tl-report .*"id":"o#t500"' 500 'erro'
route '^/judge/tl-report .*"id":"o#tgone"' 404 '{"success":false,"error":{"code":"problem_gone"}}'
route '^/judge/' 200 '{"success":true}'
for p in t500 tgone; do C="$(cache_id_dir "o#$p")"; mkdir -p "$C/pkg/tests/input"; : > "$C/pkg/tests/input/t1"; : > "$C/pkg/conf"
  printf '{"id":"o#%s","checksum":"cks2"}' "$p" > "$C/.moj-cache.json"; done   # pacote já baixado, sem tabela: calibra
_api_get(){ printf '{"exists":true,"checksum":"cks2"}'; }
: > "$FAKE_LOG"; ensure_cached "o#t500" 0 0 0 moj >/dev/null; DBG="$(cat "$JUDGE_CACHE/o_t500/.moj-cache.json") | $(cat "$FAKE_LOG")"
ck "tl-report falhou (500 × 3): tl_reported:false, sem reported_at; o log vai assim mesmo" '[[ "$(jq -c "[.tl_reported, .reported_at]" "$JUDGE_CACHE/o_t500/.moj-cache.json")" == "[false,null]" && "$(ncall "/judge/tl-report o#t500")" == 3 && "$(ncall "/judge/calib-report o#t500")" == 1 ]]'
ck "…e fica fora do inventário até o re-report do boot" '[[ "$(agent_problems_json | jq -r "has(\"o#t500\")")" == false ]]'
: > "$FAKE_LOG"; ensure_cached "o#tgone" 0 0 0 moj >/dev/null; DBG="$(cat "$FAKE_LOG")"
ck "apagado durante a calibração: marca, tl_reported:false, nenhum calib-report" '[[ -e "$JUDGE_CACHE/o_tgone/.gone" && "$(jq -r .tl_reported "$JUDGE_CACHE/o_tgone/.moj-cache.json")" == false && "$(ncall "/judge/calib-report o#tgone")" == 0 ]]'

echo "== juízes idênticos, mesmo TL: o tl_class do job vira a tabela do job (tl.job, 26/10/2026) =="
# o servidor manda no job o máx entre os juízes da classe de hardware deste; o agente julga pelo MAIOR entre a
# classe e a própria medição, só com o mesmo tl_checksum, e o arquivo é `source`ado: nada fora do formato entra
CK="$(cache_id_dir "o#cls")"; mkdir -p "$CK/pkg/tests/input"; for i in $(seq 1 100); do : > "$CK/pkg/tests/input/t$i"; done
: > "$CK/pkg/conf"
printf '#x\nTL[c]=.3\nTL[py3]=1.2\nTL[default]=.3\n# Kattis\ndeclare -A TLKATTIS\nTLKATTIS[c]=1\nTLKATTIS[default]=1\n' > "$CK/pkg/tl.t1"
printf 'abcdef12' > "$CK/.tl_checksum"
TC='{"class":"x86_64|Xeon|28|252","checksum":"abcdef12","hosts":["judge","judge-sp1"],"tl":{"c":"0.4","py":"1.1","default":"0.4"},"tl_kattis":{"c":"2","default":"1"}}'
eff(){ ( declare -A TL TLKATTIS; source "$1" 2>/dev/null; printf '%s %s %s %s' "${TL[c]}" "${TL[default]}" "${TL[py]:-${TL[py3]}}" "${TLKATTIS[c]}" ); }
out="$(_tl_job_file "$CK/pkg" "$CK" "$TC" "$W/tl.job")"; DBG="$(cat "$W/tl.job" 2>/dev/null)"
ck "classe maior: sai a tabela do job"          '[[ "$out" == "$W/tl.job" && -s "$W/tl.job" ]]'
ck "o source fica com o MAIOR por chave: c 0,4, default 0,4, py 1,2 (a medição local vence a classe menor), Kattis c 2" '[[ "$(eff "$W/tl.job")" == "0.4 0.4 1.2 2" ]]'
ck "a tabela local fica intocada"               '[[ "$(eff "$CK/pkg/tl.t1")" == ".3 .3 1.2 1" ]]'
ck "_job_cap pela tabela do job (0,4 × 100 testes) > pela local (0,3)" '[[ "$(_job_cap "$CK/pkg" c moj "$W/tl.job")" == 610 && "$(_job_cap "$CK/pkg" c moj)" == 590 ]]'
rm -f "$W/tl.job"; printf 'fedcba98' > "$CK/.tl_checksum"
out="$(_tl_job_file "$CK/pkg" "$CK" "$TC" "$W/tl.job")"
ck "tl_checksum diferente (classe de outra versão): a local" '[[ -z "$out" && ! -e "$W/tl.job" ]]'
printf 'abcdef12' > "$CK/.tl_checksum"
out="$(_tl_job_file "$CK/pkg" "$CK" '{"checksum":"abcdef12","hosts":["judge"],"tl":{"c":".2","default":".1"}}' "$W/tl.job")"
ck "classe menor em tudo: nada a subir, a local" '[[ -z "$out" && ! -e "$W/tl.job" ]]'
out="$(_tl_job_file "$CK/pkg" "$CK" "" "$W/tl.job")"
ck "job sem tl_class (servidor antigo): a local" '[[ -z "$out" ]]'
EVIL='{"checksum":"abcdef12","hosts":["a\nTL[c]=99","b;touch '"$W"'/pwn0"],"tl":{"c]=1;touch '"$W"'/pwn1;#":"5","java":"$(touch '"$W"'/pwn2)","cpp":"7"}}'
out="$(_tl_job_file "$CK/pkg" "$CK" "$EVIL" "$W/tl.job")"; DBG="$(cat "$W/tl.job" 2>/dev/null)"
v="$(eff "$W/tl.job")"; ( declare -A TL TLKATTIS; source "$W/tl.job" 2>/dev/null )
ck "chave/valor/juiz fora do formato não entram; só o cpp=7 válido" '[[ "$(grep -c "^TL\[" "$W/tl.job")" == 4 && "$(grep -c "^TL\[cpp\]=7$" "$W/tl.job")" == 1 && "${v%% *}" == .3 ]]'
ck "…e o source não executou nada"              '[[ ! -e "$W/pwn0" && ! -e "$W/pwn1" && ! -e "$W/pwn2" ]]'
rm -f "$W/tl.job"

# ponta a ponta: o run_job passa a tabela do job ao build-and-test (MOJ_TLFILE) e o tl_used do result é o da classe
# (o run_job de verdade: os testes de despacho, lá em cima, o trocaram por um falso)
source <(sed -n '/^run_job() {/,/^}/p' "$JD/agent/moj-agent.sh")
cat > "$W/mt/build-and-test.sh" <<'EOB'
#!/bin/bash
# build-and-test FALSO: a seleção de tabela do de verdade (MOJ_TLFILE › tl.<host> › tl) e o TL da linguagem
TLFILE="$3/tl"; [[ -e "$3/tl.$HOSTNAME" ]] && TLFILE="$3/tl.$HOSTNAME"
[[ -n "${MOJ_TLFILE:-}" && -e "${MOJ_TLFILE:-}" ]] && TLFILE="$MOJ_TLFILE"
declare -A TL TLKATTIS; source "$TLFILE"
w="$(mktemp -d)"; printf "TL_LANG='%s'\n" "${TL[$1]:-${TL[default]}}" > "$w/report.env"
echo "bat tlfile=$(basename "${MOJ_TLFILE:-SEM}") tl=${TL[$1]:-${TL[default]}}" >> "$CAL_LOG"
echo "$w"; echo "Accepted,100p"
EOB
printf '{"id":"o#cls","checksum":"cks1","tl_reported":true}' > "$CK/.moj-cache.json"
: > "$FAKE_ROUTES"; route '^/judge/result ' 200 '{"success":true}'
_api_get(){ printf '{"exists":true,"checksum":"cks1","tl_checksum":"abcdef12"}'; }
JOBJ="$(jq -cn --argjson tc "$TC" '{id:"jc1", contest:"sp", problem_id:"o#cls", login:"aluno", lang:"c", filename:"a.c", code_b64:"aQ==", tl_method:"moj", tl_class:$tc}')"
: > "$CAL_LOG"; : > "$FAKE_LOG"; mkdir -p "$W/tj"
( TMPDIR="$W/tj"; run_job "$JOBJ" "" ); DBG="$(cat "$CAL_LOG") | $(cat "$FAKE_LOG")"
ck "run_job: o build-and-test julgou pela tabela do job (c = 0,4)" 'grep -qx "bat tlfile=tl.job tl=0.4" "$CAL_LOG"'
ck "…e o result leva tl_used 0,4"               '[[ "$(jq -r .tl_used "$FAKE_LOG.body._judge_result" 2>/dev/null)" == 0.4 ]]'
JOBJ="$(jq -c 'del(.tl_class) | .id = "jc2"' <<<"$JOBJ")"; : > "$CAL_LOG"
( TMPDIR="$W/tj"; run_job "$JOBJ" "" ); DBG="$(cat "$CAL_LOG")"
ck "job sem tl_class: a tabela local, sem MOJ_TLFILE (c = 0,3)" 'grep -qx "bat tlfile=SEM tl=.3" "$CAL_LOG"'

# ---- REPORTS DA CALIBRAÇÃO (26/10/2026): todos os report.html até os tetos de BYTES — o teto era 12 POR CONTAGEM e
# o olamundo (15 soluções de 8,5 KB) perdia os 3 últimos em ordem alfabética (a .pas, a .rs e a slow)
RP="$W/rp"; mkdir -p "$RP/pkg/.calib-reports"; : > "$RP/.calib.log"
for i in $(seq -w 1 15); do { printf '<html>'; head -c 8000 /dev/zero | tr '\0' x; printf '</html>'; } > "$RP/pkg/.calib-reports/good-s$i.c.html"; done
ALOG="$W/alog.txt"; : > "$ALOG"; alog(){ echo "$*" >> "$ALOG"; }
_api_file(){ cp "$2" "$W/rp.body"; return 0; }
report_calib_log "o#rp" "cks1" "$RP/.calib.log" "$RP/pkg"; DBG="$(jq -c '[.reports[].name]' "$W/rp.body" 2>&1 | head -c 300)"
ck "15 reports pequenos: vão os 15 (o teto era 12)" '[[ "$(jq ".reports | length" "$W/rp.body")" == 15 && "$(jq -r ".reports[-1].name" "$W/rp.body")" == good-s15.c ]]'
ck "…com o conteúdo do arquivo"                    '[[ "$(jq -r ".reports[0].html_b64" "$W/rp.body" | base64 -d | head -c 6)" == "<html>" ]]'
ck "…e nada no log de pulados"                     '[[ ! -s "$ALOG" ]]'
# um report acima do teto POR ARQUIVO e o orçamento TOTAL: o que não cabe é pulado, os seguintes ainda entram, o log diz quais
head -c 600000 /dev/zero | tr '\0' y > "$RP/pkg/.calib-reports/good-big.c.html"
head -c 100 /dev/zero | tr '\0' z > "$RP/pkg/.calib-reports/slow-z.c.html"
AGENT_REPORTS_MAX_BYTES=100000 report_calib_log "o#rp" "cks1" "$RP/.calib.log" "$RP/pkg"; DBG="$(jq -c '[.reports[].name]' "$W/rp.body") | $(cat "$ALOG")"
ck "teto por arquivo: o de 586 KB fica de fora"   '! jq -e ".reports[] | select(.name == \"good-big.c\")" "$W/rp.body" >/dev/null'
ck "orçamento de 100 KB: os 12 primeiros pequenos cabem, os 3 seguintes não" '[[ "$(jq -c "[.reports[].name | select(startswith(\"good-s\"))] | [length, .[-1]]" "$W/rp.body")" == "[12,\"good-s12.c\"]" ]]'
ck "…e o que vem depois e cabe ainda entra (pula, não para)" 'jq -e ".reports[-1].name == \"slow-z.c\"" "$W/rp.body" >/dev/null'
ck "o log diz o que ficou de fora e o tamanho"      'grep -q "4 report(s) fora do envio" "$ALOG" && grep -q "good-big.c (586 KB)" "$ALOG" && grep -q "good-s15.c (8 KB)" "$ALOG"'
# re-envio de boot (sem o pkg): reports vazio — o servidor preserva os da mesma versão
report_calib_log "o#rp" "cks1" "$RP/.calib.log"
ck "sem o pkg: reports vazio, corpo válido"         'jq -e "(.reports == []) and (.id == \"o#rp\")" "$W/rp.body" >/dev/null'
ck "nenhum temporário sobra"                        '[[ "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -newer "$RP/.calib.log" -name "tmp.*" -type f 2>/dev/null | wc -l)" == 0 ]]'
alog(){ :; }
unset -f sleep

echo; echo "RESULT: $pass passed, $fail failed"
(( fail == 0 ))
