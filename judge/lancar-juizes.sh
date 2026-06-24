#!/bin/bash

[[ "$1" != "now" ]] && sleep 15m

declare -A relacao
relacao[gpu1]=42000
relacao[gpu2]=42050
relacao[gpu3]=42100

###if false; then
for MACHINE in ${!relacao[@]}; do
	ssh $MACHINE "tmux new-session -s 'judge' -n 'receveitor' -d \"tcpserver -H 0.0.0.0 ${relacao[$MACHINE]} /home/prof/judge/job-receiveitor-gpu.sh\" \; new-window -n 'root-daemon' -d 'bash /home/prof/judge/root-daemon-gpu.sh'"
done

#exit 0
#fi

unset relacao
declare -A relacao
relacao[pos1]=41050
relacao[pos2]=41000
for MACHINE in ${!relacao[@]}; do
	ssh $MACHINE "tmux new-session -s 'judge' -n 'receveitor' -d \"tcpserver -H 0.0.0.0 ${relacao[$MACHINE]} /home/prof/judge/job-receiveitor.sh\" \; new-window -n 'root-daemon' -d 'bash /home/prof/judge/root-daemon.sh'"
done

###exit 0
##fi

unset relacao
declare -A relacao
relacao[cm1]=43000
relacao[cm2]=43050
relacao[cm3]=43100
relacao[cm4]=43150
for MACHINE in ${!relacao[@]}; do
	ssh $MACHINE "tmux new-session -s 'judge' -n 'receveitor' -d \"tcpserver 0.0.0.0 ${relacao[$MACHINE]} /home/prof/judge/job-receiveitor-cm.sh\" \; new-window -n 'root-daemon' -d 'bash /home/prof/judge/root-daemon-cm.sh'"
done


unset relacao
declare -A relacao
relacao[hu1]=44000
for MACHINE in ${!relacao[@]}; do
	ssh $MACHINE "tmux new-session -s 'judge' -n 'receveitor' -d \"tcpserver -H 0.0.0.0 ${relacao[$MACHINE]} /home/prof/judge/job-receiveitor-hu.sh\" \; new-window -n 'root-daemon' -d 'bash /home/prof/judge/root-daemon-hu.sh'"
done

