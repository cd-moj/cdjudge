#!/bin/bash

LOGDIR=$PWD/log
#PROBLEMDIR=$(realpath ../moj-problems/)
#PROBLEMDIR=$HOME/unb/teaching/apc/
PROBLEMDIR=$HOME/problems.cm/

# This is executed everytime a connection happens to hit our tcpserver
# TODO maybe make functions separated by files, it will load faster if the
# command is very simple
# XXX It should authenticate and exchange encrypted messages

function queuejob()
{
  local ID=$1
  local LANGUAGE=$2
  local FILE="$3"
  local FILENAME=$4
  local PROBLEMID=$5
  local RESP
  declare -a RESP
  mkdir -p $LOGDIR/$ID
  echo $HOSTNAME > $LOGDIR/$ID/host
  touch $LOGDIR/$ID/report.html
  echo "$FILE" | base64 -i -d > $LOGDIR/$ID/$FILENAME
  echo 'On queue' > $LOGDIR/$ID/status
  echo "$JSON" | jshon > $LOGDIR/$ID/job.json
  mkdir -p /dev/shm/moj-queue
  touch /dev/shm/moj-queue/$ID
  date > $LOGDIR/$ID/requestdate
}

function cmd-run()
{
  local PROBLEMID="$(jshon -e problemid <<< "$JSON"|tr -d '"')"
  local LANGUAGE="$(jshon -e language <<< "$JSON"|tr -d '"')"
  local FILENAME="$(basename $(jshon -e filename <<< "$JSON"|tr -d '"'))"
  local FILEB64="$(jshon -e fileb64 <<< "$JSON"|tr -d '"')"
  local JOBID=$(echo "$EPOCHSECONDS $$ $JSON $HOSTNAME $SRANDOM"|sha224sum|awk '{print $1}')
  queuejob $JOBID $LANGUAGE "$FILEB64" $FILENAME $PROBID
  #echo "{ \"jobid\": \"$JOBID\", \"status\": \"$(< $LOGDIR/$JOBID/status)\" }"
  JSON="$( echo "$JSON"|jshon -s "$JOBID" -i jobid)"
  echo "{ \"jobid\": \"$JOBID\" }"
  #cmd-getresult
}

function cmd-listproblems()
{
  cd $PROBLEMDIR
  echo '{ "problems": ['
  ls */*/tl| while read f; do
    echo "\"${f%%/tl}\","
  done
  echo ' null ] }'
}

function cmd-islocked()
{
  FREEMACHINE=/dev/shm/free-machine
  #if flock -n $FREEMACHINE true; then
  if flock -n $FREEMACHINE true && grep -q '^0.' /proc/loadavg; then
    echo '{ "status": "false" }'
  else
    echo '{ "status": "true" }'
  fi
}

function cmd-reporttls()
{
  cd $PROBLEMDIR
  echo '{ "problems": ['
  find . -type f -name 'tl'| while read f; do
    echo "{ \"id\": \"${f%%/tl}\", "
    echo " \"last-modification\": $(stat -c %Y $f),"
    local TL
    declare -A TL
    source $f
    echo ' "tl": ['
    echo "{ \"language\": \"default\", \"tl\": \"${TL[default]}\" }"
    unset TL[default]
    for LANG in ${!TL[@]}; do
      echo ", { \"language\": \"$LANG\", \"tl\": \"${TL[$LANG]}\" }"
    done
    echo " ]"
    unset TL

    echo "},"
  done
  echo ' null ] }'
}

function cmd-updateproblemset()
{
  if [[ "$HOSTNAME" != "cm1" ]]; then
    echo "{ \"string\": \"$(base64 <<< "$HOSTNAME nao atualiza nada")\" }"
    return
  fi
  local REPO="$1"
  FILE=/home/prof/judge/update-log/mojinho-$HOSTNAME-$EPOCHSECONDS
  if ! [[ -d "$PROBLEMDIR/$REPO" ]]; then
	  echo "repositório $REPO inexistente"|base64 -w0 > $FILE
  else
	  cd $PROBLEMDIR
	  bash /home/prof/judge/update-problems.sh stdout $REPO|base64 -w0 > $FILE
  fi
  echo "{ \"string\": \"$(< $FILE)\" }"
}

function cmd-problemtl()
{
  cd $PROBLEMDIR
  f=$(echo $JSON|jshon -e param|tr -d '"'|tr -d '\\')
  if [[ ! -d "$PROBLEMDIR/$f" ]]; then
    echo "{ \"id\": null, \"error\": \"Invalid problem ID\" }"
    return
  fi
  echo "{ \"hostname\": \"$HOSTNAME\", \"id\": \"${f}\", "
  echo " \"last-modification\": $(stat -c %Y $f/tl),"
  local TL
  declare -A TL
  source $f/tl
  echo ' "tl": ['
  echo "{ \"language\": \"default\", \"tl\": \"${TL[default]}\" }"
  unset TL[default]
  for LANG in ${!TL[@]}; do
    echo ", { \"language\": \"$LANG\", \"tl\": \"${TL[$LANG]}\" }"
  done
  echo " ]"
  unset TL

  echo "}"
}

function cmd-reportmachine()
{
  echo -n "{ \"hostname\": \"$HOSTNAME\", \"arch\": \"$(arch)\", \"cpu\":"
  echo -n " \"$(grep 'model name' /proc/cpuinfo|head -n1|cut -d: -f2-)\","
  echo " \"memory\": $(head -n1 /proc/meminfo|awk '{print $(NF-1)}') }"
}

function cmd-getresult()
{
  local JOBID="$(jshon -e jobid <<< "$JSON"|tr -d '"')"
  if [[ ! -d "$LOGDIR/$JOBID" ]]; then
    echo "{ \"id\": \"$JOBID\", \"status\": null, \"logfileb64\": null, \"error\": \"Invalid ID\" }"
    return
  fi

  local LOGFILEB64=null
  #[[ -e "$LOGDIR/$JOBID/build-and-test.log" ]] && LOGFILEB64="$(base64 -w0 $LOGDIR/$JOBID/build-and-test.log)"
  cat << EOF | jshon
{ "id": "$JOBID",
  "status": "$(< $LOGDIR/$JOBID/status)",
  "jobrequested": "$(< $LOGDIR/$JOBID/requestdate)",
  "logfileb64": null
}
EOF
}

function cmd-getresultfull()
{
  local JOBID="$(jshon -e jobid <<< "$JSON"|tr -d '"')"
  if [[ ! -d "$LOGDIR/$JOBID" ]]; then
    echo "{ \"id\": \"$JOBID\", \"status\": null, \"logfileb64\": null, \"error\": \"Invalid ID\" }"
    return
  fi

  local LOGFILEB64=null
  [[ -e "$LOGDIR/$JOBID/report.html" ]] && LOGFILEB64="$(base64 -w0 $LOGDIR/$JOBID/report.html)"
  cat << EOF | jshon
{ "id": "$JOBID",
  "status": "$(< $LOGDIR/$JOBID/status)",
  "jobrequested": "$(< $LOGDIR/$JOBID/requestdate)",
  "logfileb64": "$LOGFILEB64"
}
EOF
}

function cmd-unknowncommand()
{
  echo "{ \"id\": \"$CMD\", \"status\": null, \"logfileb64\": null, \"error\": \"Invalid Command\" }"
}

if false && [[ "$TCPREMOTEIP" != "2604:a880:2:d0::21bc:d001" ]] && [[ "$TCPREMOTEIP" != "::ffff:159.65.72.180" ]]; then
	echo "I dont like you : $TCPREMOTEIP"
	echo "bye"
	sleep 1
	exit 0
fi

declare -A COMMANDFUNCTIONS

for f in run updateproblemset getresultfull getresult report reportmachine reporttls problemtl listproblems islocked; do
  COMMANDFUNCTIONS[$f]=true
done

#JSON is global
read JSON

CMD=$(jshon -e cmd <<< "$JSON"|tr -d '"')
PARAM="$(jshon -e param <<< "$JSON"|tr -d '"')"
set -x

if [[ -n "${COMMANDFUNCTIONS[$CMD]}" ]]; then
  cmd-$CMD $PARAM
else
  cmd-unknowncommand
fi

set +x
