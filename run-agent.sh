#!/bin/bash
# run-agent.sh — sobe o moj-agent como INSTÂNCIA ÚNICA e com folga de processos.
# Config (paths, MOJ_API, token, CAGE_ROOT, CAPABILITY) vem de etc/agent.env
# (copie de etc/agent.env.sample). Reexecutar é seguro: encerra a instância antiga —
# a SESSÃO INTEIRA (agente + build-and-test + bwrap + soluções, nada fica órfão) — e
# sobe uma nova. Jobs em voo morrem e são RE-ENFILEIRADOS pelo servidor no register
# boot:true do agente novo: nenhum item de fila se perde num restart.
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || exit 1
set -a; . etc/agent.env 2>/dev/null; set +a
export AGENT_HOST="${AGENT_HOST:-$(hostname)}"
ulimit -u "$(ulimit -Hu)" 2>/dev/null || true        # folga: a calibração forka bwrap+time+timeout

PIDFILE="agent-$AGENT_HOST.pid"

# encerra a instância antiga MATANDO A SESSÃO (sid = pid do setsid): pega o agente E todos os
# descendentes. O `pkill -f 'bash agent/moj-agent.sh'` antigo só matava o main e os subshells
# de slot — os NETOS (build-and-test/cage-run/bwrap/solução) viravam órfãos rodando E seguravam
# o flock de instância herdado (fd 8), fazendo o agente novo desistir ("já há um agente rodando").
_kill_session() {
  local sid="$1" n
  [[ "$sid" =~ ^[0-9]+$ ]] || return 0
  pkill -TERM -s "$sid" 2>/dev/null || return 0
  for n in 1 2 3 4 5; do pgrep -s "$sid" >/dev/null 2>&1 || return 0; sleep 1; done
  pkill -KILL -s "$sid" 2>/dev/null; sleep 1
}
# SYSTEMD MANDA: se a unit do agente está instalada/enabled p/ este usuário, o restart é DELA.
# Subir via setsid por fora cria um agente FORA do supervisor — não volta no reboot, não
# reinicia em crash, e a unit fica inactive achando que não há agente (o drift descoberto em
# 2026-08-04, quando o run-agent.sh pós-pull virou o caminho de fato). O caminho manual abaixo
# continua como fallback p/ máquina sem a unit (dev/instalação nova); RUN_AGENT_FORCE_MANUAL=1
# força o manual mesmo com unit (debug).
if [[ -z "${RUN_AGENT_FORCE_MANUAL:-}" ]]; then
  _xdg="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if env XDG_RUNTIME_DIR="$_xdg" systemctl --user is-enabled "moj-agent@${CAPABILITY:-pos}" >/dev/null 2>&1; then
    [[ -f "$PIDFILE" ]] && { _kill_session "$(cat "$PIDFILE" 2>/dev/null)"; rm -f "$PIDFILE"; }
    echo "unit moj-agent@${CAPABILITY:-pos} instalada — entregando ao systemd (restart)"
    exec env XDG_RUNTIME_DIR="$_xdg" systemctl --user restart "moj-agent@${CAPABILITY:-pos}"
  fi
fi

[[ -f "$PIDFILE" ]] && _kill_session "$(cat "$PIDFILE" 2>/dev/null)"
# fallback legado (1º restart pós-upgrade, sem pidfile): mata por cmdline como antes — cobre o
# main e os subshells; netos remanescentes morrem quando o servidor re-enfileira e o TL dinâmico
# do agente novo assume. Confirma que morreu antes de subir o novo.
pkill -f 'bash agent/moj-agent.sh' 2>/dev/null
for _ in 1 2 3 4 5; do pgrep -f 'bash agent/moj-agent.sh' >/dev/null 2>&1 || break; sleep 1; done
pkill -9 -f 'bash agent/moj-agent.sh' 2>/dev/null; sleep 1

# sobe desacoplado do terminal; o próprio agente segura um flock (instância única de verdade).
# O pid do setsid É o session id da árvore nova — fica no PIDFILE p/ o próximo restart.
setsid bash agent/moj-agent.sh >> "agent-$AGENT_HOST.log" 2>&1 </dev/null &
echo $! > "$PIDFILE"
echo "started moj-agent on $AGENT_HOST pid $! (cap=${CAPABILITY:-pos}, ulimit -u=$(ulimit -u), sid em $PIDFILE)"
