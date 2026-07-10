# judge — agente pull do juiz

Código que roda **nas máquinas de julgamento** (sem server/web). **Ver `README.md`** (tabela dos
3 repos, layout, como subir). Workspace multi-repo: ver `../CLAUDE.md`. Uma máquina de juiz clona
`judge` + `mojtools` (sandbox) — **não** o `cdmoj`.

## Peças

- `agent/moj-agent.sh` — o **agente** (modelo pull): conecta na API do MOJ, puxa jobs no
  **heartbeat**, baixa o pacote do problema sob demanda p/ um **cache local**
  (`JUDGE_CACHE`, default `~/.cache/moj/problems`), calibra na 1ª vez e **reporta o TL**.
  - **MULTI-SLOT**: a máquina pode ser particionada (`off` = 1 slot; `numa` = 1 slot por
    NUMA node; `cpus:<X>` = fatias de X cpus; `reserve` tira as N primeiras cpus) e corrigir
    N problemas AO MESMO TEMPO — cada job/calibração roda num subshell PINADO ao cpuset do
    slot (`taskset -pc` no próprio $BASHPID; herda p/ bwrap/compilador/solução; o `nproc` da
    fatia auto-limita o paralelismo interno de testes). Heartbeat manda
    `{free_slots,total_slots,cfg_hash}` e recebe `assigned` em LOTE (array) + `config` nova
    quando o admin muda (`moj judges config <host>`); aplicar config/clearcache/GC exige
    QUIESCÊNCIA (drena todos os slots primeiro). Fallback local: `AGENT_PARTITION`/
    `AGENT_RESERVE` no agent.env (a config do servidor vence). 1 instância por host
    (duas capabilities na mesma máquina teriam cpusets sobrepostos — não particione nesse caso).
  - **GC do cache**: cada uso carimba `$cdir/.last-used`; a cada `AGENT_CACHE_GC_HOURS` (6)
    com o juiz LIVRE, pacote sem uso há `AGENT_CACHE_MAX_DAYS` (14; 0=off) vira **STUB** —
    `pkg/` sai, `.moj-cache.json` + `tl.$host` ficam (o TL segue re-reportado no boot e é
    **restaurado sem recalibrar** no próximo uso com o MESMO checksum; checksum novo =
    recalibra como sempre). Teto opcional `AGENT_CACHE_MAX_MB` (evict LRU). O sweep respeita
    o flock por-problema e pula downloads em curso.
  - **Token nunca no argv**: os curls usam `curl -K <authfile>` (config 600 em
    `$XDG_RUNTIME_DIR`/`/dev/shm`, removido no EXIT) — `ps`/`/proc/*/cmdline` não veem o
    `mojw_…`; o `TOKEN` também é `unset` após montar o arquivo (não vaza em `/proc/*/environ`).
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
- Tokens de worker têm prefixo `mojw_` e ficam `600` — **nunca ecoar**.
- `macalan` (sshd IPv6) limita conexões rápidas — espace os SSH.
- `bash -n` antes de commitar. Rodapé de commit: **só** `Co-Authored-By:`, **nunca** `Claude-Session:`.
- **Doc junto com o código** (doc atrasada = bug): mudou o protocolo pull/agente? atualize
  `cdmoj/server/judge-gw/PULL.md` e os `CLAUDE.md` no mesmo commit.
