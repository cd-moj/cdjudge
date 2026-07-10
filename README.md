# cd-moj — Repositório do JUIZ

Código que roda **nas máquinas de julgamento** (sem server/web). Uma máquina de juiz clona
**só este repo + o `mojtools`** (sandbox) e sobe o **agente** (`moj-agent`), que conecta na API
do MOJ, **puxa jobs no heartbeat** (modelo pull) e **baixa o pacote de cada problema sob demanda
p/ um cache local** — sem clonar repo, sem NFS. Na 1ª vez calibra o problema e **reporta o TL**.

## Os dois repos que um juiz precisa

| Repo | Caminho (dev) | O que é |
|---|---|---|
| **judge** (este, `cdjudge`) | `~/judge` | Agente pull (`agent/`) + `install.sh`/`Makefile` + o unit systemd. |
| **mojtools** (`mojtools`) | `~/mojtools` | Sandbox/julgamento: `build-and-test.sh`, `cage-run.sh`, `calibreitor.sh`, `lang/`, o rootfs. |

> Repos git independentes. O **cdmoj** (server/web) **não** é clonado no juiz — o agente só faz
> `curl` de SAÍDA p/ a API (`MOJ_API`). Problemas: baixados por problema (`GET /judge/package`) p/
> o `JUDGE_CACHE` (default `~/.cache/moj/problems`), nunca versionados.

## Instalação (recomendado: `install.sh`)

O `install.sh` detecta a distro, confere/instala as dependências, monta o **rootfs** da jaula,
escreve o `etc/agent.env` + o token, e sobe o agente. Idempotente.

```bash
git clone <cdjudge>   ~/judge
git clone <mojtools>  ~/mojtools
cd ~/judge
make doctor                                   # só confere (deps + bwrap real + rootfs)
make install CAP=pos MOJ_API=https://moj.naquadah.com.br/api/v1 \
     INSTALL_FLAGS="--token /caminho/worker.token"
# capability: pos | gpu | cm | hu  (uma instância por capacidade)
```

O **rootfs** é o **PADRÃO** (não opcional): os compiladores moram numa raiz reprodutível
(`$HOME/moj-sysroot`), então o host só precisa do runtime (`bwrap`, coreutils, …). Modos
(`--sysroot`):

| modo | como | quando |
|---|---|---|
| `pull` (default) | `podman pull ghcr.io/cd-moj/moj-sysroot` + export | máquina com podman |
| `tar` | extrai um tarball (`make sysroot-tar TAR=…`) | **C3SL / sem podman / sem root** |
| `build` | `mojtools/make-sysroot.sh` (precisa podman) | montar do zero |
| `host` | usa o host (`CAGE_ROOT=host`) | todos os compiladores já no host |

### Dependências (o doctor confere)

Host, sempre: `bash bubblewrap /usr/bin/time coreutils util-linux(taskset,flock,getopt) bc make
diffutils gawk grep sed tar gzip curl jq git procps`. Opcionais: `podman`+`unzip` (montar rootfs),
`wget` (lang/riscv), `g++` (bridges do testlib/interativo), `cset` (root), `nvidia-smi`/`rocm-smi`
(capability `gpu`). Em modo `host`, some a lista inteira de compiladores (ver `mojtools/check-deps.sh`).

### Token de worker (segredo)

A API valida `Authorization: Bearer mojw_<segredo>` contra um token **compartilhado** (600):

```bash
# no host da API, uma vez:
TOK="mojw_$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
install -Dm600 <(printf '%s' "$TOK") "$RUNDIR/secrets/worker.token"
# no juiz: --token <arquivo>  (ou instale à mão em ~/judge/etc/worker.token, 600)
```

## Subir/reiniciar o agente

- **systemd (user)** — o `install.sh` já faz `enable --now`. Manual:
  `systemctl --user restart moj-agent@pos` · `journalctl --user -u moj-agent@pos -f`.
  O unit vive aqui: `etc/systemd/moj-agent@.service` (user unit, paths `%h`).
- **`run-agent.sh`** — launcher de **instância única** sem systemd: encerra o agente antigo e
  sobe um novo desacoplado (`setsid`, flock). `make restart` usa systemd se ativo, senão cai p/ ele.
- **manual (teste):** `set -a; . etc/agent.env; set +a; bash agent/moj-agent.sh`.

## Deploy em várias máquinas

```bash
make deploy HOSTS="cpu1 cpu2 macalan"   # rsync de judge/ + mojtools/ e restart remoto
```
Espaça os SSH (`SSH_GAP`, default 3s) — **`macalan`** (sshd IPv6) limita conexões rápidas.
Homes de juiz conhecidos: **C3SL** `/home/ppginf/bcribas/moj-judge` (NFS compartilhado, **sem
root**); **chococino** `/home/prof/ribas/moj-judge`. No C3SL: `--sysroot tar` + `--systemd none`
(sem podman, sem root; suba com `run-agent.sh`).

## Capacidades

`CAPABILITY` = `pos` (CPU padrão) · `gpu` · `cm` (compiladores) · `hu`. Um job com
`need_capability` só vai a máquinas daquela capacidade. **`gpu` exige GPU de compute comprovada**
(`nvidia-smi`/`rocm-smi` respondendo); sem ela, o agente e o servidor rebaixam p/ `pos`.

## Multi-slot

A máquina pode ser particionada (`AGENT_PARTITION=off|numa|cpus:N`, `AGENT_RESERVE=N`) p/ corrigir
N problemas ao mesmo tempo, cada um pinado a um cpuset (`taskset`). A config por-juiz do **servidor**
(`moj judges config <host>`) chega pelo heartbeat e **vence** o fallback local. Ver `CLAUDE.md`.

## Legado (aposentado)

O cluster síncrono (`root-daemon*`/`job-receiveitor*` via `nc` + `sistema_escalonador/` master
`:27000`) foi **removido** — o modelo pull o substituiu. Histórico: `cdmoj/server/judge-gw/PULL.md`.
