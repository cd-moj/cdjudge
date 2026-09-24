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

echo; echo "RESULT: $pass passed, $fail failed"
(( fail == 0 ))
