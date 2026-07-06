#!/bin/bash
# judge/agent/inventory.sh — coleta specs (CPU/mem/GPU) e inventário de problemas
# do host para o moj-agent. Sourced pelo agent.

: "${JUDGE_CACHE:=$HOME/.cache/moj/problems}"   # cache local de pacotes (modelo cache)

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

# linguagens que ESTE host consegue julgar = lang-dirs cujo binário principal existe.
# O escalonador usa isso p/ rotear cada submissão a um juiz com o toolchain dela (route
# by language). Valores são alternativas (basta UMA existir). 'sh' é sempre suportado.
declare -A _LANGBIN=(
  [c]="gcc" [cpp]="g++" [java]="javac" [py3]="python3" [py2]="python python2"
  [go]="gccgo go" [rs]="rustc" [hs]="ghc" [cs]="mcs mono-csc csc" [pas]="fpc"
  [pl]="swipl prolog pl" [js]="node nodejs" [ml]="ocamlopt ocaml" [spim]="spim"
  [apl]="dyalog mapl apl" [riscv]="java" [sh]="bash" [kt]="kotlinc"
)
agent_langs_json() {
  local l b ok first=1 out='[' root="${CAGE_ROOT:-}"
  for l in "${!_LANGBIN[@]}"; do
    ok=0
    for b in ${_LANGBIN[$l]}; do
      if [[ -n "$root" ]]; then   # com CAGE_ROOT, o toolchain vem do ROOTFS (não do host)
        [[ -x "$root/usr/local/bin/$b" || -x "$root/usr/bin/$b" || -x "$root/bin/$b" ]] && { ok=1; break; }
      else
        command -v "$b" >/dev/null 2>&1 && { ok=1; break; }
      fi
    done
    (( ok )) || continue
    [[ $first -eq 1 ]] || out+=','; first=0; out+="\"$l\""
  done
  out+=']'; printf '%s' "$out" | jq -c 'sort'
}

# objeto {id: checksum} dos problemas em CACHE local já calibrados. O id real e o
# checksum (arquivos que afetam o TL) ficam no .moj-cache.json de cada pacote. Serve p/
# o escalonador preferir juízes "quentes" e p/ detectar mudança de versão (recalibrar).
agent_problems_json() {
  [[ -d "$JUDGE_CACHE" ]] || { echo '{}'; return; }
  { while IFS= read -r d; do
      [[ -f "$d/.moj-cache.json" ]] || continue
      jq -c 'select(.id and .tl_reported) | {(.id): (.checksum // "")}' "$d/.moj-cache.json" 2>/dev/null
    done < <(find "$JUDGE_CACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null); } \
    | jq -s -c 'add // {}'
}

agent_inv_hash() {  # $1 = problems-json
  printf '%s' "$1" | jq -S -c '.' 2>/dev/null | sha256sum | cut -c1-16
}
