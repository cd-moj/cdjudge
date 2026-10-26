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
  - **LARGURA k / grupos de CPU (24/09/2026)** — o job/calibração pode pedir **k CPUs por teste**
    (`CPUNEEDED` do conf; o servidor manda `test_cpus`, `same_numa`, `par_max` (grupos que podem
    consumir slot NOVO), `par_cap` (teto = MAXPARALLELTESTS)). **`alloc_slots k P numa cap`**
    (função pura sobre `SLOT_*`) escolhe até P grupos de k CPUs entre os slots livres: grupo dentro
    de um nó (obrigatório com `same_numa`; preferido sempre; sem numa, sobras de nós compõem no fim);
    com SMT (`CPU_SIB`, de `thread_siblings_list`) e k ≥ 2 o grupo é de NÚCLEOS INTEIROS; sobra de
    um slot já consumido (partition numa/off, slot > k) vira grupo extra de graça até `cap`; partition
    `off` = P grupos vazios (sem pin). Resultado em `ALLOC_GROUPS`/`ALLOC_SLOTS`; `_alloc_env` dá a
    união (pin do subshell) e a string `g0|g1|…`; nem 1 grupo ⇒ **`_decline`** (`POST /judge/decline`
    com `id`/`reqid`/`command`; servidor antigo ignora e o job volta pelo ASSIGN_TTL). O
    build-and-test recebe `MOJ_TEST_CPUS/MOJ_PARALLEL/MOJ_CPU_GROUPS/MOJ_RELEASE_FILE` (calibração:
    `MOJ_PARALLEL=1`). **Primário/membros** (`_slot_take`, resultado em `TAKEN_PRIMARY` — nunca por
    `$(…)`): o 1º slot guarda pid/tmp/kind/meta + `SLOT_ALLOC` ("slots do g0|slots do g1|…"); os
    demais são `kind=member` com o MESMO pid e `meta` = índice do primário (o reap os solta junto;
    `_report_slot_killed` ignora member). **Liberação de cauda**: `_release_tail` lê o
    `$TMPDIR/released` do primário (índices de grupo que o b-a-t anotou; append-only, idempotente
    via `SLOT_RELEASED`) e solta os slots que só grupos liberados usam (grupo 0 nunca; partition
    numa: slot com grupo vivo fica). Job sem `test_cpus` (servidor antigo) = caminho de sempre.
    **A calibração NUNCA libera grupo** (26/10/2026): o calibreitor roda sob `env -u MOJ_RELEASE_FILE`
    (e o mojtools novo também a tira). A disparada DENTRO de um job de P grupos herdava o arquivo, os
    build-and-test dela anotavam os grupos ≥ 1 e o laço devolvia ao escalonador os slots que o job ainda
    ia usar — CPU disputada, TLE espúrio no 1º envio depois de recalibrar.
    **Raias da calibração (26/10/2026)**: a calibração aceita os `par_max` grupos que o servidor der (com slot livre
    e fila vazia; teto `CALIB_PAR_MAX` lá) só se o calibreitor local tem raias (`_calib_lanes_ok`: o nome
    `MOJ_CALIB_LANES` no `calibreitor.sh`) e `AGENT_CALIB_LANES≠0`; senão 1 grupo, como antes. Os grupos ficam
    presos até o fim (sem liberação de cauda). O calibreitor recebe `MOJ_CALIB_LANES=$AGENT_CALIB_LANES` nas duas
    chamadas (a disparada por job usa os grupos do job como raias).
    Register manda `slot_cpus` (menor slot), `slots_by_node`, `smt`; heartbeat manda `slot_cpus` e
    `max_free_group` (maior nº de slots livres num nó).
  - **Métodos de TL (26/10/2026)**: a tabela `tl.<host>` leva `TL[]` (MOJ) e `TLKATTIS[]` (Kattis por
    linguagem, mojtools `tl-methods.sh`); `tl_to_json <arq> [TLKATTIS]` e o `report_tl` mandam as duas (`tl`,
    `tl_kattis`). O job traz `tl_method` (o servidor lê o conf ATUAL no claim): vai ao build-and-test
    (`MOJ_TL_METHOD`), ao `_job_cap` (TLKATTIS + TLMOD sum/mult) e ao `ensure_cached` (5º arg): job `kattis` com
    tabela sem a metade Kattis recalibra (rápido) antes de julgar (`_tl_has_method`; não exige se o mojtools local
    não tem o `tl-methods.sh`). `_calib_cap` da full orça o piso de pass/slow/wrong (b × ⌈a × CALIBRATIONTL⌉,
    teto 30 s por teste).
  - **Juízes idênticos, mesmo TL (26/10/2026)**: o job traz `tl_class` (o máx, por linguagem, entre os juízes da
    mesma classe de hardware — o servidor deriva a classe dos specs do register). `_tl_job_file` grava `tl.job` no
    dir do job = a tabela local + uma linha por chave em que a classe é MAIOR (o `source` fica com a última; nunca
    abaixo da medição deste juiz), só com o MESMO `tl_checksum` (o `ensure_cached` grava `<cache>/<id>/.tl_checksum`
    do package-meta). Vai ao build-and-test por `MOJ_TLFILE` e ao `_job_cap` (4º arg). O 3º arg é SÓ o `tl_class`
    (o job leva o código em base64: >128 KiB num argumento do jq); chave/valor/host fora do formato não entram
    (o arquivo é `source`ado). Sem classe, servidor antigo ou checksum diferente: a tabela local.
  - **Calibração reportada por extenso**: `report_calib_log` envia, além do log/reports (TODOS os report.html
    até `AGENT_REPORT_MAX_BYTES` (10 MB) por arquivo e `AGENT_REPORTS_MAX_BYTES` (50 MB) no total — o que não cabe é
    pulado, os seguintes ainda entram, e sai no log; o teto era 12 POR CONTAGEM e 500 KB por arquivo: o olamundo
    perdia os 3 últimos e 22% dos reports nunca subiam; o `_api_file` dá 60 s + 2 s/MB ao curl), o
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
  - **Problema que não existe mais (26/10/2026)**: os POSTs passam por `_api_ex` (lê o código HTTP em
    `_API_CODE`/`_API_BODY`; `_api`/`_api_file` mantêm o contrato), que só repete 000/408/409/429/5xx — antes
    todo erro era repetido 3×. O 404 `problem_gone` do `tl-report`/`calib-report` faz `report_tl`/
    `report_calib_log` devolverem **rc 3** e marcarem a entrada (`_cache_mark_gone`: arquivo `<cache>/<id>/.gone`,
    não campo do meta — marcar não disputa o meta com o `ensure_cached`); `exists:false` VÁLIDO no package-meta
    também marca (sem resposta não). A marca tira a entrada do inventário (`agent_problems_json`) e do re-report do
    boot, e o GC apaga o diretório inteiro (passo 0, sob o flock do problema); package-meta `exists:true` de novo
    tira a marca e re-reporta o TL. O `tl_reported` do meta grava o resultado REAL do report (era true sempre): o
    inventário só lista o que o servidor recebeu, e o re-report do boot completa o que falhou (vira true e pede
    re-registro).
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
