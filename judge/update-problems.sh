#!/bin/bash

cd /home/prof/judge

if [[ "$1" != "stdout" ]]; then
  exec &> update-log/$(date +%s)
fi

INICIAL=$EPOCHSECONDS

date -R
echo '---------------------------'
echo

PROBDIR=problems
REPO="$2"

[[ "$HOSTNAME" == "gpu1" ]] && PROBDIR=problems.gpu
[[ "$HOSTNAME" == "cm1" ]] && PROBDIR=problems.cm
[[ "$HOSTNAME" == "hu1" ]] && PROBDIR=problems.hu

[[ -n "$2" ]] && REPO="$PROBDIR/$2"
[[ -z "$REPO" ]] && REPO="$PROBDIR/*"

for DIR in $REPO; do
  cd $DIR
  echo "###### $DIR ######"
  echo "----------- GIT GIT GIT"
  flock /dev/shm/free-machine git pull --recurse-submodules 2>&1
  echo "----------- GIT GIT GIT"
  echo
  echo
  flock /dev/shm/free-machine make -k 2>&1
  echo
  cd - &>/dev/null
done

echo
echo '---------------------------------------'
echo "Update took $((EPOCHSECONDS-INICIAL)) seconds"

exit 0
echo iniciando ovomaltine
echo skiping
#ssh -p 13508 judge@ovomaltine.naquadah.com.br bash update.sh
echo finalizado
