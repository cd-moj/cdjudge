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
git clone <cdjudge>   ~/judge        # TEM de ser $HOME/judge (o unit usa %h/judge)
git clone <mojtools>  ~/mojtools
sudo loginctl enable-linger "$USER"  # OBRIGATÓRIO — ver abaixo
cd ~/judge
make doctor                                   # só confere (deps + bwrap real + rootfs)
make install CAP=pos MOJ_API=https://moj.naquadah.com.br/api/v1 \
     INSTALL_FLAGS="--token /caminho/worker.token"
# capability: pos | gpu | cm | hu  (uma instância por capacidade)
```

> **Linger é obrigatório** (com `--systemd user`, o default): sem ele o user manager morre no
> logout — o agente cai junto **e**, pior, o limite **duro** de memória da jaula some (ele vem de
> `systemd-run --user --scope -p MemoryMax`, que precisa do user manager; sem isso sobra só o "MLE
> por RSS medido depois", que não contém um estouro rápido).
>
> **Rodar como root NÃO é alternativa:** como root o `cage-run.sh` usa cgroup **v1** (`cset`), que
> não existe em distro moderna (cgroup v2 unificado) ⇒ **nenhum** limite de memória. O agente é p/
> rodar como **usuário comum**.
>
> **Ubuntu ≥ 24.04:** o AppArmor bloqueia user-namespace de processo não-root
> (`kernel.apparmor_restrict_unprivileged_userns=1`) e **sem userns não há `bwrap`**. Numa máquina
> dedicada a julgar, libere:
> `echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-moj-judge.conf && sudo sysctl --system`.
> O `make doctor` acusa isso e imprime o remédio.

O **rootfs** é o **PADRÃO** (não opcional): os compiladores moram numa raiz reprodutível
(`$HOME/moj-sysroot`), então o host só precisa do runtime (`bwrap`, coreutils, …). Modos
(`--sysroot`):

| modo | como | quando |
|---|---|---|
| `pull` (default) | `podman pull ghcr.io/cd-moj/moj-sysroot` + export | máquina com podman |
| `tar` | extrai um tarball (`make sysroot-tar TAR=…`) | **C3SL / sem podman / sem root** |
| `build` | `mojtools/make-sysroot.sh` (precisa podman) | montar do zero |
| `keep` | usa o que já está em `--sysroot-dir` | a rootfs veio de fora (ex.: **root** a construiu) |
| `host` | usa o host (`CAGE_ROOT=host`) | todos os compiladores já no host |

**APL (Dyalog):** o `.deb` é proprietário e não vai em imagem pública — instale-o na rootfs com
`--sysroot build --apl /caminho/dyalog.deb` (camada extra; o `postinst` cria `/usr/bin/dyalogscript`).

**Se o userns só foi liberado p/ o `bwrap`** (perfil AppArmor, em vez do sysctl global), o `podman`
**rootless** do usuário do agente também fica sem namespace ⇒ construa a rootfs **como root**
(`sudo bash ../mojtools/make-sysroot.sh --out ~agente/moj-sysroot --apl …`, depois `chown -R`) e
instale com **`--sysroot keep`**.

> **`make config`/`make sysroot` agora PRESERVAM o `agent.env` existente**: flag explícita vence;
> sem flag, vale o valor que JÁ está no arquivo (só então o default) — e linhas extras
> (`MOJ_RESOLVE`, `AGENT_CACHE_*`, …) são mantidas. (Antes reescreviam com defaults — `MOJ_API`
> voltava p/ localhost e `AGENT_PARTITION`/`AGENT_RESERVE` sumiam; foi a divergência de config
> que wedgeou o restart no incidente 2026-07-15.) Além disso a config de partição **aplicada**
> persiste em `<cache>/../agent-state.json` e é a fonte da verdade do boot — servidor > estado
> persistido > agent.env.
>
> ⚠️ `--systemd system` **não funciona**: o unit é *user* (usa `%h`), e copiado p/
> `/etc/systemd/system/` procuraria o config em `/root/judge/…`. Use `user` (default) ou `none`.

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

## Subir/reiniciar o agente — SEM PERDER FILA

Reiniciar é sempre seguro: os jobs em voo morrem **limpos** (a árvore inteira, sem órfãos) e o
servidor os **re-enfileira NA HORA** quando o agente novo registra com `boot:true` — nenhuma
submissão/calibração se perde (rede de segurança: `q_reconcile` 120s / `upd_reconcile` 1800s
p/ host morto). A config de partição volta exatamente como estava (`agent-state.json` + a config
do servidor adotada no boot) — restart nunca mais wedgeia por config divergente.

- **`moj judges restart <host>`** (admin, sem SSH) — o agente mata os slots (SIGKILL no grupo de
  processos de cada job, reportando judge-error/calib-fail ao servidor) e se re-executa.
  `moj judges reset <host>` só mata os jobs presos e reconcilia a config, sem reiniciar o processo.
- **systemd (user)** — o `install.sh` já faz `enable --now`. Manual:
  `systemctl --user restart moj-agent@pos` · `journalctl --user -u moj-agent@pos -f`.
  O unit vive aqui: `etc/systemd/moj-agent@.service` (user unit, paths `%h`). O systemd mata o
  cgroup INTEIRO — é o caminho recomendado onde houver linger.
- **`run-agent.sh`** — launcher de **instância única** sem systemd: mata a **SESSÃO** antiga
  (sid no `agent-<host>.pid` — pega build-and-test/bwrap/soluções, não só o agente) e sobe um
  novo desacoplado (`setsid`, flock). `make restart` usa systemd se ativo, senão cai p/ ele.
- **manual (teste):** `set -a; . etc/agent.env; set +a; bash agent/moj-agent.sh`.

**Tetos de wall-clock (anti-wedge):** todo julgamento/calibração roda sob um `timeout` que mata o
**grupo de processos** ao estourar um teto **DINÂMICO** — proporcional ao TL-por-teste × nº de
testes (× soluções na calibração), ×2 p/ reruns de TLE, + compilação + folga (piso 300s). Um job
preso em infra reporta `Judge Error`/falha de calibração e libera o slot sozinho — a fila nunca
mais congela como no incidente 2026-07-15. Knobs: `AGENT_HARD_TL_FALLBACK` (default 1800s; usado
só quando o pacote não dá p/ estimar) e `AGENT_LOCK_WAIT` (espera máx no flock por-problema,
default 3600s). O scratch de cada job vive num **TMPDIR próprio** (`AGENT_WORK`, default
`/tmp/moj-agent-work.<host>/s<slot>.<epoch>.<rand>`) removido no fim — slots nunca compartilham
diretório de escrita.

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
