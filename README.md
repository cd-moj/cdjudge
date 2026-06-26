# cd-moj — Repositório do JUIZ

Código que roda **nas máquinas de julgamento** (não tem server/web). Uma máquina de
juiz clona **só este repo** + o **mojtools** (sandbox) e sobe o **agente** (`moj-agent`),
que se conecta à API do MOJ, **puxa jobs no heartbeat** (modelo pull) e **baixa o pacote
de cada problema sob demanda p/ um cache local** (modelo cache — sem clonar repo, sem
depender de NFS). Na 1ª vez calibra o problema e **reporta o TL** ao MOJ.

## Os três repositórios (separados de propósito)

| Repo | Caminho (dev) | Caminho (deploy) | O que é |
|---|---|---|---|
| **moj** (`cdmoj.git`) | `~/moj` | host web | Plataforma: `server/` (API bash) + `web/` (frontend) + `docs/`. **O juiz NÃO precisa.** |
| **mojtools** (`mojtools.git`) | `~/moj/mojtools` | `/home/prof/mojtools` | Sandbox/julgamento: `build-and-test.sh`, `cage-run.sh`, `gen-report.sh`, `calibreitor.sh`, `lang/`. |
| **judge** (este, `cdjudge.git`) | `~/moj/judge` | `/home/prof/judge` | Agente + daemons do juiz. |

> Os três são repos git independentes. No checkout de dev, `mojtools/` e `judge/`
> ficam aninhados em `~/moj/` mas são **gitignored** pelo moj (têm `.git` próprio).
> **Problemas** o juiz baixa do MOJ por problema (`GET /judge/package`) p/ um **cache
> local** (`JUDGE_CACHE`, default `~/.cache/moj/problems`) — nunca versionados aqui.

## Layout deste repo

```
judge/
├── agent/                  # AGENTE (modelo pull) — o juiz roda isto
│   ├── moj-agent.sh        #   loop: register → heartbeat → (puxa job) → julga → POST result
│   └── inventory.sh        #   coleta specs (CPU/mem/GPU) + inventário do cache
├── etc/agent.env.sample    # modelo de config do agente (copie p/ etc/agent.env)
└── CLAUDE.md · README.md   # docs
```

> O cluster legado (master tcpserver `:27000` + `root-daemon*`/`job-receiveitor*` + `escalonador`)
> e o `update-problems.sh` (NFS) foram **removidos** — o modelo pull os substituiu. Histórico da
> migração em **`server/judge-gw/PULL.md`** (repo moj).

## Pré-requisitos por máquina

`bash`, `jq`, `curl`, `git`, **`bubblewrap` (`bwrap`)** (sandbox), `/usr/bin/time`, e os
compiladores/runtimes das linguagens que a máquina vai julgar (gcc/g++, python3, openjdk, …).
Máquinas **GPU**: `nvidia-smi` (a detecção de GPU usa ele; cai p/ `lspci`).

> **Toolchain reprodutível (opcional):** em vez de instalar compiladores no host, a jaula pode
> rodar a partir de um **rootfs** (ex.: Ubuntu 24.04 com tudo). Construa com `make-sysroot.sh`
> (podman) e aponte `CAGE_ROOT=<dir>` no `agent.env`. Aí o host só precisa de `bwrap`+`podman`.
> Ver **`mojtools/SANDBOX.md`**.

## Levantar um juiz (passo a passo)

Exemplo com deploy em `/home/prof`. Ajuste os caminhos no `etc/agent.env`.

### 1. Clonar o código (uma vez por máquina; ou via NFS, ver nota)
```bash
sudo -u prof -i
git clone git@github.com:cd-moj/cdjudge.git    /home/prof/judge
git clone git@github.com:cd-moj/mojtools.git   /home/prof/mojtools
```
> **NFS:** `mojtools` e o **código** do juiz podem morar no NFS compartilhado (montados
> read-only em cada máquina) — assim você atualiza num lugar só. O que **precisa** ser
> local/escrita é o sandbox temporário (`/tmp`, `/dev/shm`) e o `etc/worker.token`.

### 2. Cache de problemas (automático — nada a montar)
O juiz **baixa o pacote de cada problema sob demanda** do MOJ (`GET /judge/package`) p/ o
cache local `JUDGE_CACHE` (default `~/.cache/moj/problems`). Não há NFS a montar nem repo a
clonar — só garanta que `JUDGE_CACHE` seja **local com escrita** e tenha espaço.
```bash
# opcional: fixar o local do cache no etc/agent.env
JUDGE_CACHE=/home/prof/judge/cache/problems
```
> NFS vira **opcional**: se você já tiver os pacotes num NFS, dá p/ pré-popular o cache, mas
> não é necessário — levantar um juiz novo é só conectar; ele cacheia conforme julga.

### 3. Instalar o token de worker (segredo)
A API valida `Authorization: Bearer mojw_<segredo>` contra um token **compartilhado**.
Gere uma vez (no host da API) e espelhe no juiz (NFS de preferência), **modo 600**:
```bash
# no host da API:
TOK="mojw_$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
install -Dm600 <(printf '%s' "$TOK") "$RUNDIR/secrets/worker.token"
# espelhe p/ os juízes (NFS):
install -Dm600 <(printf '%s' "$TOK") /home/prof/judge/etc/worker.token
```

### 4. Calibração do TL (automática na 1ª vez)
Cada máquina tem timing próprio. O agente **calibra sozinho** na 1ª vez que vê um problema
(ou quando ele muda): roda o `calibreitor.sh` no cache (gera `tl.<hostname>`) e **reporta o
TL ao MOJ** (`POST /judge/tl-report`). O MOJ serve o **máx entre os hosts** no treino. Ao
relançar, o agente re-reporta os TLs do cache (sem recalibrar). Para forçar a calibração de
um diretório inteiro antes de uma prova, o admin usa `POST /ops/updateproblemset {repo}`
(enfileira calibração dos problemas novos/alterados). Calibrar na mão (opcional):
```bash
bash /home/prof/mojtools/calibreitor.sh ~/.cache/moj/problems/<id-encoded>/pkg
```

### 5. Configurar e subir o agente
```bash
cd /home/prof/judge
cp etc/agent.env.sample etc/agent.env
$EDITOR etc/agent.env      # MOJ_API, CAPABILITY (pos|gpu|cm|hu), caminhos
```
Via **systemd** (recomendado) — o unit vive no repo moj (`server/etc/systemd/moj-agent@.service`)
e lê o `etc/agent.env`:
```bash
sudo cp /caminho/moj/server/etc/systemd/moj-agent@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now moj-agent@pos       # @pos | @gpu | @cm | @hu = a CAPABILITY
journalctl -u moj-agent@pos -f                  # acompanhar
```
Ou **na mão** (teste rápido):
```bash
set -a; . etc/agent.env; set +a
bash agent/moj-agent.sh
```

### 6. Verificar
```bash
# saúde geral (público): deve mostrar workers_registered subir
curl -s https://moj.naquadah.com.br/api/v1/index/status | jq '.judge'
# detalhe por juiz (admin): esta máquina aparece com specs + inventário + último update
curl -s -H "Authorization: Bearer <admin-token>" \
     https://moj.naquadah.com.br/api/v1/judge/list | jq '.judges[] | {host,online,state,problems_count,gpu,last_update}'
```

## Capacidades

`CAPABILITY` = `pos` (CPU padrão) · `gpu` · `cm` (compiladores) · `hu`. Um job com
`need_capability` definido só é entregue a máquinas daquela capacidade; sem isso, qualquer
uma. Rode um `moj-agent@<cap>` por capacidade da máquina.

## Atualizar os problemas (pela plataforma)

Admin dispara `POST /api/v1/ops/updateproblemset {repo}`. No **modelo cache** isso não clona
nada: enfileira **calibração** dos problemas novos/alterados (checksum ≠ o do TL já reportado).
Os juízes livres pegam os pedidos no heartbeat, baixam o pacote, calibram e **reportam o TL**
(visto em `/judge/list .last_update` e `/ops/problemtl`). `{all:true}` recalibra tudo. Indexar
o enunciado (HTML/`var/jsons`) roda **no servidor** (publish/webhook). Não precisa entrar em
cada máquina, e um juiz novo se popula sozinho conforme julga.

## Legado (aposentado)

O cluster legado (`root-daemon*`/`job-receiveitor*` via `nc` + `sistema_escalonador/` master
tcpserver `:27000`) foi **removido** deste repo — o modelo pull (acima) o substituiu. A sequência
de migração/aposentadoria fica registrada em **`server/judge-gw/PULL.md`** (repo moj).

## Primeiro push deste repo

`git init` já foi feito. Para publicar:
```bash
cd /home/ribas/moj/judge
git add -A && git commit -m "juiz: agente pull + daemons legados"
git remote add origin git@github.com:cd-moj/cdjudge.git
git push -u origin <branch>
```
(O `.gitignore` já mantém fora os problemas, a fila do master e os segredos.)
