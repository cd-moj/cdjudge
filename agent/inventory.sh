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

# topologia NUMA por /sys (sem numactl): [{node:0, cpus:"0-15,32-47"}, …]. Vazio se /sys
# não expõe nodes (VM mínima) — o particionador cai p/ "cpus:X" sobre as cpus online.
agent_topology_json() {
  local n out='[]' cl
  for n in /sys/devices/system/node/node[0-9]*; do
    [[ -d "$n" && -f "$n/cpulist" ]] || continue
    cl="$(<"$n/cpulist")"
    out="$(jq -c --argjson i "${n##*node}" --arg c "$cl" '. + [{node:$i, cpus:$c}]' <<<"$out" 2>/dev/null)" || out='[]'
  done
  printf '%s' "$out"
}

# linguagens que ESTE host consegue julgar = lang-dirs cujo binário principal existe.
# O servidor (escalonador in-daemon) usa isso p/ só entregar a um juiz um job cujo toolchain
# ele tem (route by language). Valores são alternativas (basta UMA existir). 'sh' é sempre suportado.
declare -A _LANGBIN=(
  [c]="gcc" [cpp]="g++" [java]="javac" [py]="pypy3 python3"
  [go]="gccgo go" [rs]="rustc" [hs]="ghc" [cs]="mcs mono-csc csc" [pas]="fpc"
  [pl]="swipl prolog pl" [js]="node nodejs" [ml]="ocamlopt ocaml" [spim]="spim"
  [apl]="dyalogscript dyalog mapl apl" [riscv]="java" [sh]="bash" [kt]="kotlinc"
)

# Existe e é executável DENTRO do rootfs? Não dá p/ usar `-x "$root/usr/bin/$b"` direto: o binário
# da distro quase sempre é SYMLINK p/ caminho ABSOLUTO (/usr/bin/javac -> /etc/alternatives/javac
# -> /usr/lib/jvm/…), que, visto do HOST, aponta p/ FORA do rootfs — o teste dá FALSO-NEGATIVO e a
# linguagem some do inventário. Consequência real: o servidor faz route-by-language e simplesmente
# NUNCA manda submissão de java/kt/pas/apl/riscv p/ este juiz (elas ficam eternamente na fila).
# Aqui a cadeia de symlinks é resolvida DENTRO do rootfs.
_rootfs_exec() {  # <root> <caminho absoluto dentro do rootfs>
  local root="$1" p="$2" t n=0
  while [[ -L "$root$p" ]]; do
    (( ++n > 10 )) && return 1                      # laço de symlink
    t="$(readlink "$root$p")"
    case "$t" in /*) p="$t";; *) p="$(dirname "$p")/$t";; esac
  done
  [[ -x "$root$p" ]]
}

agent_langs_json() {
  local l b d ok first=1 out='[' root="${CAGE_ROOT:-}"
  for l in "${!_LANGBIN[@]}"; do
    ok=0
    for b in ${_LANGBIN[$l]}; do
      if [[ -n "$root" ]]; then   # com CAGE_ROOT, o toolchain vem do ROOTFS (não do host)
        for d in /usr/local/bin /usr/bin /bin; do
          _rootfs_exec "$root" "$d/$b" && { ok=1; break; }
        done
        (( ok )) && break
      else
        command -v "$b" >/dev/null 2>&1 && { ok=1; break; }
      fi
    done
    (( ok )) || continue
    [[ $first -eq 1 ]] || out+=','; first=0; out+="\"$l\""
  done
  out+=']'; printf '%s' "$out" | jq -c 'sort'
}

# VERSÃO do compilador/interpretador de cada linguagem, MEDIDA DENTRO DA JAULA — com
# CAGE_ROOT o que vale é o rootfs, não o host. É o dado que a "info sheet" da prova publica
# (cdmoj: aba 📄 Documentos), então tem de ser o que o aluno enfrenta de verdade.
# Mesmo mapa de comandos do `collect_toolchain` do mojtools/build-and-test.sh.
declare -A _VERCMD=(
  [c]="gcc --version" [cpp]="g++ --version" [java]="javac -version" [py]="python3 --version"
  [go]="gccgo --version" [rs]="rustc --version" [hs]="ghc --version" [cs]="mcs --version"
  [pas]="fpc -iV" [pl]="swipl --version" [js]="node --version" [ml]="ocamlopt -version"
  [spim]="spim -version" [sh]="bash --version" [kt]="kotlinc -version"
)

# agent_toolchain_json <langs-json> -> {"c":"gcc (Ubuntu …) 13.3.0", "java":"javac 21.0.8", …}
# Custa UMA jaula por linguagem, então o resultado é CACHEADO em disco e só refeito quando a
# raiz da jaula, a lista de linguagens ou o mojtools mudam. Falha numa linguagem é ignorada
# (a linguagem some do mapa) — inventário nunca pode derrubar o registro do juiz.
agent_toolchain_json() {
  local langs="${1:-[]}" root="${CAGE_ROOT:-}" cache="${JUDGE_CACHE%/problems}/toolchain.json"
  local cr="$MOJTOOLS_DIR/cage-run.sh" key stamp
  [[ -f "$cr" ]] || { echo '{}'; return; }
  stamp="$(stat -c %Y "$cr" 2>/dev/null)$(stat -c %Y "${root:-/}/usr/bin" 2>/dev/null)"
  key="$(printf '%s|%s|%s' "$root" "$langs" "$stamp" | sha256sum | cut -c1-16)"
  if [[ -s "$cache" ]] && [[ "$(jq -r '.key // ""' "$cache" 2>/dev/null)" == "$key" ]]; then
    jq -c '.toolchain // {}' "$cache" 2>/dev/null && return
  fi
  local w out='{}' l vc ver
  w="$(mktemp -d)" || { echo '{}'; return; }
  while IFS= read -r l; do
    vc="${_VERCMD[$l]:-}"; [[ -n "$vc" ]] || continue
    printf '#!/bin/bash\n%s 2>&1 | head -2\n' "$vc" > "$w/.ver.sh"; chmod +x "$w/.ver.sh"
    ver="$(bash "$cr" ${root:+-R "$root"} -w "$w" -r "$w/.ver.sh" \
             -s "$w/.s" -t "$w/.t" -T 20 -B "$w/.b" 2>/dev/null \
           | grep -m1 -v '^[[:space:]]*$')"
    ver="${ver//$'\t'/ }"; ver="${ver:0:200}"
    [[ -n "$ver" ]] || continue
    out="$(jq -c --arg k "$l" --arg v "$ver" '.[$k]=$v' <<<"$out" 2>/dev/null)" || out='{}'
  done < <(jq -r '.[]?' <<<"$langs" 2>/dev/null)
  rm -rf "$w"
  mkdir -p "$(dirname "$cache")" 2>/dev/null
  jq -cn --arg k "$key" --argjson t "$out" '{key:$k, toolchain:$t}' > "$cache.tmp" 2>/dev/null \
    && mv -f "$cache.tmp" "$cache"
  printf '%s' "$out"
}

# objeto {id: checksum} dos problemas em CACHE local já calibrados. O id real e o
# checksum (arquivos que afetam o TL) ficam no .moj-cache.json de cada pacote. Serve p/
# o servidor preferir juízes "quentes" e p/ detectar mudança de versão (recalibrar).
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
