#!/bin/bash
# judge/agent/inventory.sh — coleta specs (CPU/mem/GPU) e inventário de problemas
# do host para o moj-agent. Sourced pelo agent.

: "${JUDGE_CACHE:=$HOME/.cache/moj/problems}"   # cache local de pacotes (modelo cache)

_detect_gpu() {  # ecoa {vendor,names} SÓ com GPU de COMPUTE comprovada; senão null.
  # Regra: só nvidia-smi/rocm-smi RESPONDENDO (exit 0 + saída válida) contam — driver
  # carregado e stack de computação acessível. Nada de lspci: adaptador de display
  # (Virtio/Matrox/…) não é GPU de compute, e nvidia-smi com driver quebrado ecoa a
  # MENSAGEM DE ERRO (que já virou "gpu nvidia" no registro).
  local n rc
  if command -v nvidia-smi >/dev/null 2>&1; then
    # com capacidade de computação explícita (compute_cap; drivers novos)
    n="$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2>/dev/null)"; rc=$?
    if (( rc == 0 )); then
      n="$(printf '%s\n' "$n" | awk -F', *' 'NF>=2 && $2 ~ /^[0-9]/ {printf "%s%s (cc %s)", (o?";":""), $1, $2; o=1}')"
      [[ -n "$n" ]] && { jq -cn --arg n "$n" '{vendor:"nvidia", names:$n}'; return; }
    fi
    # driver antigo sem o campo compute_cap: nvidia-smi ok (exit 0) já comprova acesso CUDA
    n="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null)"; rc=$?
    if (( rc == 0 )); then
      n="$(printf '%s\n' "$n" | grep -v '^[[:space:]]*$' | paste -sd';' -)"
      [[ -n "$n" ]] && { jq -cn --arg n "$n" '{vendor:"nvidia", names:$n}'; return; }
    fi
  fi
  if command -v rocm-smi >/dev/null 2>&1; then
    # rocm-smi listando placa(s) = stack ROCm de compute acessível
    n="$(rocm-smi --showproductname --json 2>/dev/null \
         | jq -r '[.[] | objects | (."Card series" // ."Card model" // ."GFX Version" // empty)]
                  | select(length>0) | join(";")' 2>/dev/null)"
    [[ -n "$n" ]] && { jq -cn --arg n "$n" '{vendor:"amd", names:$n}'; return; }
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
  [c]="gcc" [cpp]="g++" [java]="javac" [py]="pypy3 python3"
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
