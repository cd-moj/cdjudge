#!/bin/bash
# judge/agent/inventory.sh — coleta specs (CPU/mem/GPU) e inventário de problemas
# do host para o moj-agent. Sourced pelo agent.

: "${PROBLEMSDIR:=/home/prof/judge/problems}"

_detect_gpu() {  # ecoa um JSON {vendor,names} ou null
  if command -v nvidia-smi >/dev/null 2>&1; then
    local n; n="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd';' -)"
    [[ -n "$n" ]] && { jq -cn --arg n "$n" '{vendor:"nvidia", names:$n}'; return; }
  fi
  if command -v lspci >/dev/null 2>&1; then
    local v; v="$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display' | cut -d: -f3- | paste -sd';' - | sed 's/^ //')"
    [[ -n "$v" ]] && { jq -cn --arg n "$v" '{vendor:"other", names:$n}'; return; }
  fi
  echo null
}

agent_specs_json() {
  local cpu mem
  cpu="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //')"
  mem="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  jq -cn --arg arch "$(uname -m)" --arg cpu "$cpu" \
     --argjson mem "${mem:-0}" --argjson gpu "$(_detect_gpu)" \
     --argjson ncpu "$(nproc 2>/dev/null || echo 1)" \
     '{arch:$arch, cpu:$cpu, ncpu:$ncpu, mem_kb:$mem, gpu:$gpu}'
}

# objeto {problemid: mtime}; problemid = caminho relativo a PROBLEMSDIR sem "/tl".
agent_problems_json() {
  [[ -d "$PROBLEMSDIR" ]] || { echo '{}'; return; }
  find "$PROBLEMSDIR" -mindepth 1 -name tl -printf '%P %T@\n' 2>/dev/null \
    | sed 's:/tl : :' \
    | jq -R -s -c '
        split("\n")
        | map(select(length>0) | (split(" ") | {(.[0]): (.[1]|tonumber|floor)}))
        | add // {}'
}

agent_inv_hash() {  # $1 = problems-json
  printf '%s' "$1" | jq -S -c '.' 2>/dev/null | sha256sum | cut -c1-16
}
