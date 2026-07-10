# judge/Makefile — atalhos p/ provisionar e operar uma máquina de juiz.
# O trabalho pesado vive em install.sh; aqui só conveniência. Uma máquina de juiz
# precisa de judge/ + mojtools/ (não do cdmoj).
#
#   make doctor                 # só confere deps/sandbox (não escreve nada)
#   make install CAP=pos        # provisiona tudo (deps, rootfs, agent.env, sobe o agente)
#   make deploy HOSTS="cpu1 cpu2 macalan"   # rsync + restart em várias máquinas

SHELL     := /bin/bash
CAP       ?= pos
MOJ_API   ?= http://localhost/api/v1
MOJTOOLS  ?= ../mojtools
SYSROOT   ?= pull
SYSROOT_DIR ?= $(HOME)/moj-sysroot
INSTALL_FLAGS ?=
# deploy: usuário@ e caminho remoto (ajuste por sítio; C3SL = /home/ppginf/bcribas/moj-judge)
REMOTE_DIR ?= moj-judge
SSH_GAP    ?= 3

.PHONY: help doctor install sysroot sysroot-tar config restart status logs deploy

help:
	@sed -n '1,10p' Makefile

## doctor — só confere (deps de host + bwrap real + rootfs)
doctor:
	bash install.sh --check --mojtools $(MOJTOOLS) --sysroot $(SYSROOT) --sysroot-dir $(SYSROOT_DIR)

## install — provisiona a máquina (deps, rootfs, agent.env, systemd user)
install:
	bash install.sh --capability $(CAP) --moj-api $(MOJ_API) --mojtools $(MOJTOOLS) \
	  --sysroot $(SYSROOT) --sysroot-dir $(SYSROOT_DIR) $(INSTALL_FLAGS)

## sysroot / sysroot-tar — (re)provisiona só a raiz da jaula
sysroot:
	bash install.sh --check --sysroot $(SYSROOT) --sysroot-dir $(SYSROOT_DIR) --mojtools $(MOJTOOLS)
	bash install.sh --sysroot $(SYSROOT) --sysroot-dir $(SYSROOT_DIR) --mojtools $(MOJTOOLS) \
	  --systemd none --yes
sysroot-tar:
	@test -n "$(TAR)" || { echo "uso: make sysroot-tar TAR=<rootfs.tar.zst>"; exit 2; }
	bash install.sh --sysroot tar --sysroot-tar $(TAR) --sysroot-dir $(SYSROOT_DIR) \
	  --systemd none --yes --mojtools $(MOJTOOLS)

## config — reescreve só o etc/agent.env (não mexe em deps/rootfs/serviço)
config:
	bash install.sh --capability $(CAP) --moj-api $(MOJ_API) --mojtools $(MOJTOOLS) \
	  --sysroot $(SYSROOT) --sysroot-dir $(SYSROOT_DIR) --systemd none --yes

## restart — reinício de instância única (run-agent.sh) ou via systemd user
restart:
	@if systemctl --user is-enabled "moj-agent@$(CAP)" >/dev/null 2>&1; then \
	  systemctl --user restart "moj-agent@$(CAP)"; echo ">> restart moj-agent@$(CAP) (user)"; \
	else bash run-agent.sh; fi

## status / logs
status:
	@systemctl --user status "moj-agent@$(CAP)" --no-pager 2>/dev/null || pgrep -af 'bash agent/moj-agent.sh' || echo "agente parado"
logs:
	@journalctl --user -u "moj-agent@$(CAP)" -f 2>/dev/null || tail -f "agent-$$(hostname).log"

## deploy — rsync de judge/ + mojtools/ p/ cada host e restart remoto.
## Espaça os SSH (SSH_GAP s) — macalan limita conexões rápidas.
deploy:
	@test -n "$(HOSTS)" || { echo 'uso: make deploy HOSTS="cpu1 cpu2 macalan"'; exit 2; }
	@for h in $(HOSTS); do \
	  echo ">> $$h: rsync judge/ + mojtools/"; \
	  rsync -az --delete --exclude '.git' --exclude 'etc/agent.env' --exclude 'etc/*.token' \
	    --exclude 'cache/' ./ "$$h:$(REMOTE_DIR)/judge/" ; \
	  rsync -az --delete --exclude '.git' $(MOJTOOLS)/ "$$h:$(REMOTE_DIR)/mojtools/" ; \
	  echo ">> $$h: restart"; \
	  ssh "$$h" "cd $(REMOTE_DIR)/judge && make restart CAP=$(CAP)" || echo "  (restart falhou em $$h)"; \
	  sleep $(SSH_GAP); \
	done
