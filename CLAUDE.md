# judge — agente pull do juiz

Código que roda **nas máquinas de julgamento** (sem server/web). **Ver `README.md`** (tabela dos
DOIS repos que o juiz clona, instalação, rootfs, cache do agente e como subir). Workspace
multi-repo: ver `../CLAUDE.md`. Uma máquina de juiz clona `judge` + `mojtools` (sandbox) —
**não** o `cdmoj`.

## Peças

- `agent/moj-agent.sh` — o **agente** (modelo pull): conecta na API do MOJ, puxa jobs no
  **heartbeat**, baixa o pacote do problema sob demanda p/ um **cache local**
  (`JUDGE_CACHE`, default `~/.cache/moj/problems`), calibra na 1ª vez e **reporta o TL**.
  - **MULTI-SLOT**: a máquina pode ser particionada (`off` = 1 slot; `numa` = 1 slot por
    NUMA node; `cpus:<X>` = fatias de X cpus **dentro de cada nó NUMA** — um slot nunca cruza
    nós, o resto `< X` de cada nó fica fora (bug (e), 24/09/2026: a fatia por ordem numérica
    das cpus cruzava nós); `reserve` tira as N primeiras cpus) e corrigir
    N problemas AO MESMO TEMPO — cada job/calibração roda num subshell PINADO ao cpuset do
    slot (`taskset -pc` no próprio $BASHPID; herda p/ bwrap/compilador/solução; o `nproc` da
    fatia auto-limita o paralelismo interno de testes). `SLOT_NODE[i]` guarda o nó de cada
    slot. **Matar um slot = `_kill_tree`** (colhe a árvore por parentesco com `pgrep -P`,
    SIGSTOP em todos, colhe de novo, SIGKILL): é o ÚNICO matador — reset/restart, TERM/INT e
    teto de wall-clock. O `kill -- -pid` do process group (set -m) não alcançava o que rodava
    sob `timeout` (pgroup próprio) — bug (a). Heartbeat manda
    `{free_slots,total_slots,cfg_hash,status:ok|draining|disabled}` e recebe `assigned` em
    LOTE (array) + `config` nova quando o admin muda (`moj judges config <host>`); **o lote
    que veio no MESMO beat da config é despachado** (`_beat_dispatch`; bug (b): era descartado
    e ficava em assigned/ até o ASSIGN_TTL) e a drenagem começa no beat seguinte; **config
    igual à aplicada com hash novo é adotada sem drenar** (`_config_adopt` — o servidor hasheia
    só partition/reserve/disabled). Aplicar config/clearcache/GC exige QUIESCÊNCIA (drena
    todos os slots primeiro — e a drenagem SEMPRE converge, ver tetos abaixo). Precedência de
    config no BOOT: **servidor (resposta do register boot:true) > estado persistido
    (`<cache>/../agent-state.json`, gravado a cada apply) > agent.env** — restart nunca diverge
    (C5 do incidente 2026-07-15). **Nenhum slot chama `register`** (pinado, mediria `nproc` =
    tamanho do slot e o INVHASH ficaria só na cópia dele — bug (c)): o slot deixa o flag
    `AGENT_WORK/.reregister` (`_request_register`) e o laço registra; as specs (`AGENT_SPECS`)
    são medidas UMA vez no boot. 1 instância
    por host (duas capabilities na mesma máquina teriam cpusets sobrepostos — não particione
    nesse caso). Modo ROOT força 1 slot (cset/cgroup do cage-run são globais).
    Teste: `test/agent.sh` (`make test`; sysfs FALSO via `AGENT_SYSFS`).
  - **Calibração reportada por extenso**: `report_calib_log` envia, além do log/reports, o
    campo **`sols`** (o `.calib-sols.json` do calibreitor — por solução, teste a teste; ≤300 KB,
    via `--slurpfile`) com cópia em `<cache>/<id>/.calib-sols.json` p/ o re-envio de boot;
    pkg presente SEM o arquivo remove a cópia (nunca re-enviar dado velho). O `_job_cap`
    considera o **`TLOVERRIDE`** do conf (o autor pode subir o TL na marra — o teto de
    wall-clock tem de acompanhar, senão mataria job legítimo).
  - **ANTI-WEDGE (lições do incidente 2026-07-15)**: (1) **teto de wall-clock DINÂMICO** por
    julgamento (`_job_cap`: TL×testes×2 + compile + folga) e por calibração (`_calib_cap`:
    CALIBRATIONTL×testes×soluções×2 + folga), imposto pelo LAÇO (`_reap_slots`): o slot grava
    o prazo da fase em `$TMPDIR/.deadline` (`_slot_deadline`, antes do build-and-test e do
    calibreitor) e o laço faz `_kill_tree` + `_report_slot_killed` quando passa — job preso
    reporta Judge Error/calib-fail e libera o slot sozinho, sem `timeout(1)`; (2) **calibra 1× por
    máquina**: `ensure_cached` dedupa sob o flock por-problema INCLUSIVE full — pula se uma
    full do MESMO checksum completou enquanto esperava o lock OU se o PEDIDO (`req_epoch` =
    requested_at/at, 4º arg) é mais velho que ela; checksum novo sempre recalibra — todos os
    slots usam o MESMO `tl.<host>` (e o servidor nem entrega calibração de target já em
    execução em outro lugar: serialização no `upd_claim`); (3) **comandos urgentes**
    `kill`/`restart` chegam MESMO ocupado (`moj judges
    reset/restart`, recuperação sem SSH); (4) **TMPDIR por job** (`AGENT_WORK/s<slot>.<epoch>`,
    removido no reap) — slots nunca compartilham escrita; (5) restart re-enfileira o trabalho
    em voo no servidor (register `boot:true`) — fila nunca se perde; (6) forks de slot fecham
    o fd do lock de instância (`8>&-`) — órfão não trava o agente novo.
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
- `agent/inventory.sh` — reporta CPU/linguagens/versões do toolchain e o **SO da rootfs** (`os`
  = `PRETTY_NAME` do `/etc/os-release` da jaula + arch) ao registro — a folha "Ambiente de
  julgamento" da prova publica os dois (2026-09-14).
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
