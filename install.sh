#!/bin/bash
# judge/install.sh — provisiona uma MÁQUINA DE JUIZ do MOJ: detecta e instala deps,
# monta o rootfs da jaula, escreve o etc/agent.env + o token, e instala/sobe o agente.
# Idempotente. Sem root ⇒ imprime o comando de instalação e segue (modo rootfs quase não
# precisa do host). Uma máquina de juiz precisa SÓ de judge/ + mojtools/ (não do cdmoj).
#
#   install.sh [opções]
#     --moj-api URL          base da API (default http://localhost/api/v1)
#     --capability C         pos|gpu|cm|hu (default pos)
#     --token FILE|-         instala o worker-token (mojw_…) 600; '-' lê do stdin
#     --mojtools DIR         default: ../mojtools (irmão deste repo)
#     --cache DIR            JUDGE_CACHE (default $HOME/judge/cache/problems)
#     --partition SPEC       off|numa|cpus:N (default: não fixa; a config do servidor vence)
#     --reserve N            tira as N primeiras cpus dos slots
#     --sysroot MODE         pull|tar|build|host (default pull)
#     --sysroot-image REF    (pull) default ghcr.io/cd-moj/moj-sysroot:latest
#     --sysroot-tar FILE     (tar)  tarball do rootfs (produzido por mojtools `make sysroot-tar`)
#     --sysroot-dir DIR      raiz da jaula (default $HOME/moj-sysroot)
#     --apl FILE.deb         (build) instala o Dyalog APL (.deb proprietário) na rootfs
#     --systemd MODE         user|system|none (default user; none ⇒ use run-agent.sh)
#     --check                só roda o doctor e sai (não escreve nada)
#     --yes                  não pergunta
#
# LINGER: com --systemd user, rode `sudo loginctl enable-linger $USER`. Sem linger o agente
# morre no logout E o limite de memória da jaula degrada (o cgroup v2 vem do user manager).
set -euo pipefail

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"   # .../judge

MOJ_API="http://localhost/api/v1"; CAPABILITY="pos"; TOKEN_SRC=""
MOJTOOLS_DIR="$SELF/../mojtools"; JUDGE_CACHE="$HOME/judge/cache/problems"
PARTITION=""; RESERVE=""
SYSROOT_MODE="pull"; SYSROOT_IMAGE="ghcr.io/cd-moj/moj-sysroot:latest"
SYSROOT_TAR=""; SYSROOT_DIR="$HOME/moj-sysroot"; SYSROOT_APL=""
SYSTEMD_MODE="user"; CHECK_ONLY=0; ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --moj-api) MOJ_API="$2"; shift 2;;
    --capability) CAPABILITY="$2"; shift 2;;
    --token) TOKEN_SRC="$2"; shift 2;;
    --mojtools) MOJTOOLS_DIR="$2"; shift 2;;
    --cache) JUDGE_CACHE="$2"; shift 2;;
    --partition) PARTITION="$2"; shift 2;;
    --reserve) RESERVE="$2"; shift 2;;
    --sysroot) SYSROOT_MODE="$2"; shift 2;;
    --sysroot-image) SYSROOT_IMAGE="$2"; shift 2;;
    --sysroot-tar) SYSROOT_TAR="$2"; shift 2;;
    --sysroot-dir) SYSROOT_DIR="$2"; shift 2;;
    --apl) SYSROOT_APL="$2"; shift 2;;
    --systemd) SYSTEMD_MODE="$2"; shift 2;;
    --check) CHECK_ONLY=1; shift;;
    --yes) ASSUME_YES=1; shift;;
    -h|--help) sed -n '2,33p' "$0"; exit 0;;
    *) echo "install.sh: opção desconhecida: $1" >&2; exit 2;;
  esac
done

say()  { echo -e ">> $*"; }
warn() { echo -e "!! $*" >&2; }
die()  { echo -e "XX $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; elif have sudo; then sudo "$@"; else return 127; fi; }

# ---------------- detect: distro + gerenciador de pacotes ----------------
PKG=""; PKG_INSTALL=""
detect_distro() {
  local id="" like=""
  [[ -r /etc/os-release ]] && { . /etc/os-release; id="${ID:-}"; like="${ID_LIKE:-}"; }
  case " $id $like " in
    *debian*|*ubuntu*) PKG=apt;  PKG_INSTALL="apt-get install -y --no-install-recommends";;
    *fedora*|*rhel*|*centos*) PKG=dnf; PKG_INSTALL="dnf install -y";;
    *suse*)   PKG=zypper; PKG_INSTALL="zypper install -y";;
    *arch*)   PKG=pacman; PKG_INSTALL="pacman -S --noconfirm";;
    *) PKG=""; ;;
  esac
  say "distro: ${id:-desconhecida} · gerenciador: ${PKG:-nenhum}"
}

# deps DURAS de host (runtime da jaula) por gerenciador.
host_pkgs() {
  case "$PKG" in
    apt)    echo "bash bubblewrap time coreutils util-linux bc make diffutils gawk grep sed tar gzip curl jq git procps";;
    dnf)    echo "bash bubblewrap time coreutils util-linux bc make diffutils gawk grep sed tar gzip curl jq git procps-ng";;
    zypper) echo "bash bubblewrap time coreutils util-linux bc make diffutils gawk grep sed tar gzip curl jq git procps";;
    pacman) echo "bash bubblewrap time coreutils util-linux bc make diffutils gawk grep sed tar gzip curl jq git procps-ng";;
  esac
}

# ---------------- doctor: confere o que impede o juiz de rodar ----------------
doctor() {
  say "doctor: deps de host + sandbox"
  local rootfs_arg=()
  [[ "$SYSROOT_MODE" != host && -d "$SYSROOT_DIR" ]] && rootfs_arg=(--rootfs "$SYSROOT_DIR")
  if [[ -x "$MOJTOOLS_DIR/check-deps.sh" || -r "$MOJTOOLS_DIR/check-deps.sh" ]]; then
    bash "$MOJTOOLS_DIR/check-deps.sh" "${rootfs_arg[@]}" || warn "faltam deps DURAS (veja acima)"
  else
    warn "mojtools/check-deps.sh não encontrado em $MOJTOOLS_DIR — pulei o doctor de deps"
  fi
  # bwrap REAL (não o fbwrap no-op do dev): tem de conseguir montar um namespace.
  if have bwrap; then
    if bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all --die-with-parent true 2>/dev/null; then
      say "bwrap: OK (namespace real)"
    else
      warn "bwrap presente mas NÃO cria namespace (fbwrap no-op? userns desabilitado?) — a jaula não isolará"
      # Ubuntu >= 24.04: o AppArmor barra user-namespace de processo NÃO-root sem perfil próprio.
      local uns; uns="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
      if [[ "$uns" == 1 && $EUID -ne 0 ]]; then
        warn "  causa provável: kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu >= 24.04)"
        warn "  remédio (numa máquina DEDICADA a julgar):"
        warn "    echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-moj-judge.conf"
        warn "    sudo sysctl --system"
        warn "  NÃO resolva rodando o agente como root: sem cgroup v1/cset o limite DURO de memória"
        warn "  simplesmente não existe (cage-run.sh só tem o caminho cgroup v2 p/ usuário comum)."
      fi
    fi
  else
    warn "bwrap ausente"
  fi
  # /usr/bin/time (GNU, chamado por caminho absoluto pelo cage-run)
  [[ -x /usr/bin/time ]] || warn "/usr/bin/time (GNU) ausente"
  # systemd-run --user (limite de memória cgroup v2 sem root)
  have systemd-run || warn "systemd-run ausente — limite de memória degrada (aviso na calibração)"
  # linger: sem ele o user unit morre no logout E o user manager (dono do cgroup v2) some
  if [[ "$SYSTEMD_MODE" == user ]] && have loginctl && [[ $EUID -ne 0 ]]; then
    [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == yes ]] \
      || warn "linger DESLIGADO — rode:  sudo loginctl enable-linger $USER
   (sem ele o agente cai no logout e o limite de memória da jaula degrada p/ 'MLE só por RSS')"
  fi
  # rootfs não pode ser noexec
  if [[ "$SYSROOT_MODE" != host && -d "$SYSROOT_DIR" ]]; then
    local mnt; mnt="$(df --output=target "$SYSROOT_DIR" 2>/dev/null | tail -1)"
    if findmnt -no OPTIONS "$mnt" 2>/dev/null | grep -q noexec; then
      warn "o fs de $SYSROOT_DIR está NOEXEC — a jaula não roda binários dali"
    fi
  fi
}

# ---------------- deps: instala (ou imprime o comando sem root) ----------------
install_deps() {
  [[ -n "$PKG" ]] || { warn "sem gerenciador de pacotes conhecido — instale à mão: $(host_pkgs)"; return 0; }
  local pkgs; pkgs="$(host_pkgs)"
  say "deps de host: $pkgs"
  # shellcheck disable=SC2086
  if as_root $PKG_INSTALL $pkgs; then
    say "deps instaladas"
  else
    warn "sem root: instale como root:  $PKG_INSTALL $pkgs"
  fi
}

# ---------------- sysroot: provisiona a raiz da jaula ----------------
provision_sysroot() {
  case "$SYSROOT_MODE" in
    host) say "sysroot: modo HOST (CAGE_ROOT=host) — os compiladores têm de estar no host"; return 0;;
    build)
      have podman || die "sysroot build precisa de podman"
      local apl_arg=()
      if [[ -n "$SYSROOT_APL" ]]; then
        [[ -f "$SYSROOT_APL" ]] || die "--apl: arquivo inexistente: $SYSROOT_APL"
        apl_arg=(--apl "$SYSROOT_APL"); say "sysroot: com APL (Dyalog) de $SYSROOT_APL"
      fi
      say "sysroot: build via mojtools/make-sysroot.sh -> $SYSROOT_DIR"
      bash "$MOJTOOLS_DIR/make-sysroot.sh" --out "$SYSROOT_DIR" "${apl_arg[@]}";;
    tar)
      [[ -f "$SYSROOT_TAR" ]] || die "sysroot tar: arquivo inexistente: $SYSROOT_TAR"
      say "sysroot: extrai $SYSROOT_TAR -> $SYSROOT_DIR"
      mkdir -p "$SYSROOT_DIR"
      case "$SYSROOT_TAR" in
        *.zst) if have zstd; then zstd -dc "$SYSROOT_TAR" | tar -x -C "$SYSROOT_DIR"; else tar --zstd -xf "$SYSROOT_TAR" -C "$SYSROOT_DIR"; fi;;
        *)     tar -xf "$SYSROOT_TAR" -C "$SYSROOT_DIR";;
      esac;;
    pull)
      have podman || die "sysroot pull precisa de podman (ou use --sysroot tar FILE / --sysroot host)"
      say "sysroot: pull $SYSROOT_IMAGE -> export -> $SYSROOT_DIR"
      podman pull "$SYSROOT_IMAGE"
      local cid; cid="$(podman create "$SYSROOT_IMAGE" true)"
      mkdir -p "$SYSROOT_DIR"
      podman export "$cid" | tar -x -C "$SYSROOT_DIR"
      podman rm "$cid" >/dev/null 2>&1 || true;;
    *) die "modo de sysroot inválido: $SYSROOT_MODE (use pull|tar|build|host)";;
  esac
  [[ -x "$SYSROOT_DIR/usr/bin/bash" || -x "$SYSROOT_DIR/bin/bash" ]] \
    && say "sysroot pronto em $SYSROOT_DIR" || warn "sysroot em $SYSROOT_DIR parece incompleto (sem bash)"
}

# ---------------- config: etc/agent.env + token ----------------
write_config() {
  mkdir -p "$SELF/etc" "$JUDGE_CACHE"
  local env="$SELF/etc/agent.env"
  say "config: escreve $env"
  {
    echo "# gerado por install.sh — ajuste à vontade."
    echo "MOJ_API=$MOJ_API"
    echo "CAPABILITY=$CAPABILITY"
    echo "WORKER_TOKEN_FILE=$SELF/etc/worker.token"
    echo "MOJTOOLS_DIR=$MOJTOOLS_DIR"
    echo "JUDGE_CACHE=$JUDGE_CACHE"
    [[ "$SYSROOT_MODE" == host ]] && echo "CAGE_ROOT=host" || echo "CAGE_ROOT=$SYSROOT_DIR"
    echo "HEARTBEAT_SECS=3"
    [[ -n "$PARTITION" ]] && echo "AGENT_PARTITION=$PARTITION"
    [[ -n "$RESERVE"   ]] && echo "AGENT_RESERVE=$RESERVE"
  } > "$env"
  chmod 600 "$env"
  # token
  if [[ -n "$TOKEN_SRC" ]]; then
    local tok="$SELF/etc/worker.token"
    if [[ "$TOKEN_SRC" == "-" ]]; then install -m600 /dev/stdin "$tok";
    else [[ -f "$TOKEN_SRC" ]] || die "token: arquivo inexistente: $TOKEN_SRC"; install -m600 "$TOKEN_SRC" "$tok"; fi
    say "token instalado em $SELF/etc/worker.token (600)"
  elif [[ ! -f "$SELF/etc/worker.token" ]]; then
    warn "sem token: instale o worker-token (mojw_…) 600 em $SELF/etc/worker.token antes de subir"
  fi
}

# ---------------- service: sobe o agente ----------------
setup_service() {
  local unit="$SELF/etc/systemd/moj-agent@.service"
  case "$SYSTEMD_MODE" in
    user)
      [[ -f "$unit" ]] || die "unit não encontrado: $unit"
      mkdir -p "$HOME/.config/systemd/user"
      ln -sf "$unit" "$HOME/.config/systemd/user/moj-agent@.service"
      systemctl --user daemon-reload
      systemctl --user enable --now "moj-agent@${CAPABILITY}.service"
      say "agente (user) enable --now moj-agent@${CAPABILITY}"
      say "acompanhe: journalctl --user -u moj-agent@${CAPABILITY} -f";;
    system)
      as_root cp "$unit" /etc/systemd/system/ || die "sem root p/ instalar unit de sistema"
      as_root systemctl daemon-reload
      as_root systemctl enable --now "moj-agent@${CAPABILITY}.service"
      say "agente (system) enable --now moj-agent@${CAPABILITY}";;
    none)
      say "modo none: suba à mão com  bash $SELF/run-agent.sh  (lê etc/agent.env)";;
    *) die "modo systemd inválido: $SYSTEMD_MODE";;
  esac
}

# ---------------- verify ----------------
verify() {
  say "verify: /index/status"
  if have curl; then
    curl -fsS "$MOJ_API/index/status" 2>/dev/null | jq -c '.judge // .' 2>/dev/null \
      || warn "não consegui ler $MOJ_API/index/status (rede/URL?)"
  fi
}

# ================================ fluxo ================================
detect_distro
doctor
if (( CHECK_ONLY )); then say "só --check: nada foi escrito."; exit 0; fi
install_deps
provision_sysroot
write_config
setup_service
verify
say "pronto. capability=$CAPABILITY  sysroot=$SYSROOT_MODE  systemd=$SYSTEMD_MODE"
