#!/bin/bash
# run-agent.sh — sobe o moj-agent como INSTÂNCIA ÚNICA e com folga de processos.
# Config (paths, MOJ_API, token, CAGE_ROOT, CAPABILITY) vem de etc/agent.env
# (copie de etc/agent.env.sample). Reexecutar é seguro: encerra a instância antiga e sobe uma nova.
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || exit 1
set -a; . etc/agent.env 2>/dev/null; set +a
export AGENT_HOST="${AGENT_HOST:-$(hostname)}"
ulimit -u "$(ulimit -Hu)" 2>/dev/null || true        # folga: a calibração forka bwrap+time+timeout

# encerra QUALQUER instância antiga (evita agentes duplicados) e confirma que morreu
pkill -f 'bash agent/moj-agent.sh' 2>/dev/null
for _ in 1 2 3 4 5; do pgrep -f 'bash agent/moj-agent.sh' >/dev/null 2>&1 || break; sleep 1; done
pkill -9 -f 'bash agent/moj-agent.sh' 2>/dev/null; sleep 1

# sobe desacoplado do terminal; o próprio agente segura um flock (instância única de verdade)
setsid bash agent/moj-agent.sh >> "agent-$AGENT_HOST.log" 2>&1 </dev/null &
echo "started moj-agent on $AGENT_HOST pid $! (cap=${CAPABILITY:-pos}, ulimit -u=$(ulimit -u))"
