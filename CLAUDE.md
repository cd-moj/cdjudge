# judge — agente + cluster do juiz

Código que roda **nas máquinas de julgamento** (sem server/web). **Ver `README.md`** (tabela dos
3 repos, layout, como subir). Workspace multi-repo: ver `../CLAUDE.md`. Uma máquina de juiz clona
`judge` + `mojtools` (sandbox) — **não** o `cdmoj`.

## Peças

- `agent/moj-agent.sh` — o **agente** (modelo pull): conecta na API do MOJ, puxa jobs no
  **heartbeat**, baixa o pacote do problema sob demanda p/ um **cache local**
  (`JUDGE_CACHE`, default `~/.cache/moj/problems`), calibra na 1ª vez e **reporta o TL**.
  - **Jaula no rootfs por padrão** (não no host): `ensure_rootfs` usa o **`$HOME/moj-sysroot` já
    montado** (o operador provisiona/monta; o agente **não recria**). `CAGE_ROOT=host` força o host;
    `AGENT_BUILD_ROOTFS=1` manda construir com make-sysroot.sh se faltar (precisa podman). Ver `mojtools/SANDBOX.md`.
- `agent/inventory.sh` — reporta CPU/linguagens ao registro.
- `etc/agent.env.sample` — modelo de config (copie p/ `etc/agent.env`, gitignored).

> O cluster legado (master `:27000` + `root-daemon*`/`job-receiveitor*` + `sistema_escalonador/`)
> foi **removido** — o modelo pull o substituiu. Histórico em `cdmoj/server/judge-gw/PULL.md`.

## Controle pull (o lado servidor vive em `cdmoj/server/judge-gw/`)

Registro `run/registry/<host>.json` (`cpu`, `langs`, `last_seen`); fila de updates
`run/updates/{pending,inprogress,log}`; canal de comando `run/commands/<host>/`
(`cmd_request`/`cmd_claim`, `cal_request` kind=calibrate, `upd_request` kind=index). `REG_TTL≈30`.
Detalhes: `cdmoj/server/judge-gw/PULL.md`.

## Deploy / operação (referência)

- Homes de juiz: **C3SL** `/home/ppginf/bcribas/moj-judge`; **chococino** `/home/prof/ribas/moj-judge`.
- Tokens de worker têm prefixo `mojw_`; tokens do Gitea ficam `600` — **nunca ecoar** nenhum dos dois.
- `macalan` (sshd IPv6) limita conexões rápidas — espace os SSH.
- `bash -n` antes de commitar. Rodapé de commit: **só** `Co-Authored-By:`, **nunca** `Claude-Session:`.
- **Doc junto com o código** (doc atrasada = bug): mudou o protocolo pull/agente? atualize
  `cdmoj/server/judge-gw/PULL.md` e os `CLAUDE.md` no mesmo commit.
