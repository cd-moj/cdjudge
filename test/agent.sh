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

echo; echo "RESULT: $pass passed, $fail failed"
(( fail == 0 ))
