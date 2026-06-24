tmux new-session -s 'judge-master' -n 'receveitor-master' -d "tcpserver -c 800 -H 0.0.0.0 27000 ./job-receiveitor-master.sh" \; new-window -n 'escalonador' -d 'bash escalonador.sh'
