#!/bin/bash

LOGDIR=/home/prof/judge/log
PROBLEMDIR=$(realpath /home/prof/judge/problems.gpu/)
FREEMACHINE=/dev/shm/free-machine

mkdir -p /dev/shm/moj-queue
chmod 1777 /dev/shm/moj-queue

cd /dev/shm/moj-queue

#Recover from possible unexpected break
CONT=0
if false; then
for LOG in $LOGDIR/*; do
  [[ ! -d $LOG ]] && continue
  echo ":$CONT"
  ((CONT++))
  egrep -q '(On queue|Running)' $LOG/status && touch $(basename $LOG)
done
fi

CONT=0
while true; do
  for ID in *; do
    [[ "$ID" == "*" ]] && echo -n "<" && sleep 1 && continue
    [[ ! -e "$ID" ]] && sleep 1 && ((CONT % 6 == 0 )) && echo -n . && CONT=0
    [[ ! -e "$ID" ]] && sleep 0.5 && ((CONT++))
    [[ ! -e "$ID" ]] && sleep 0.5 && continue
    [[ ! -d "$LOGDIR/$ID" ]] && echo -n "$LOGDIR/$ID does not exist\n" && rm $ID && continue
    set -x
    JSON=$LOGDIR/$ID/job.json
    echo "Running" > $LOGDIR/$ID/status
    PROBLEMID="$(jshon -e problemid < "$JSON"|tr -d '"'|tr -d '\\')"
    LANGUAGE="$(jshon -e language < "$JSON"|tr -d '"')"
    FILENAME="$(basename $(jshon -e filename < "$JSON"|tr -d '"'))"
    if [[ ! -d "$PROBLEMDIR/$PROBLEMID" ]]; then
      echo "Wrong Problem ID [$PROBLEMID]" > $LOGDIR/$ID/status
      rm $ID
      continue
    fi
    flock $FREEMACHINE bash $HOME/mojtools/build-and-test.sh\
                                    $LANGUAGE $LOGDIR/$ID/$FILENAME\
                                    $PROBLEMDIR/$PROBLEMID y &> $LOGDIR/$ID/buildinfo
    readarray -t RESP < $LOGDIR/$ID/buildinfo
    cp ${RESP[0]}/report.html ${RESP[0]}/report.org $LOGDIR/$ID/ 2>/dev/null
    [[ ! -n "${RESP[1]}" ]] && RESP[1]="Time Limit Exceeded"
    echo "${RESP[1]}" > $LOGDIR/$ID/status
    rm -rf "${RESP[0]}"
    chown -R judge.prof $LOGDIR/$ID
    rm $ID
    set +x
  done
done
