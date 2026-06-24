#!/bin/bash
MASTERDIR="./master"

# "filas" para os tipos de submissões
SUPERDIR="${MASTERDIR}/000-super/"                  # prioridade 1
PROVADIR="${MASTERDIR}/020-prova/"                  # prioridade 2
LISTAPRIVADADIR="${MASTERDIR}/040-lista-privada/"   # prioridade 3
REJULGARDIR="${MASTERDIR}/060-rejulgar/"           # prioridade 4
LISTAPUBLICADIR="${MASTERDIR}/080-lista-publica/"  # prioridade 5

ENVIADODIR="${MASTERDIR}/enviado/"

HOSTEXECUCAO="" 
PORTAEXECUCAO=""
JOBIDHOST=""
JOB_SELECIONADO=

function cmd-run()
{
    # Determinar o diretório apropriado com base no CONTEST_TYPE
    local CONTEST_TYPE=$(jq -r '.type' <<< "$JSON")
    local CONTEST_DIR
    case $CONTEST_TYPE in
        "super")
            CONTEST_DIR=$SUPERDIR
        ;;
        "prova")
            CONTEST_DIR=$PROVADIR
        ;;
        "lista-privada")
            CONTEST_DIR=$LISTAPRIVADADIR
        ;;
        "lista-publica")
            CONTEST_DIR=$LISTAPUBLICADIR
        ;;
        *)
            echo "Tipo de concurso desconhecido: $CONTEST_TYPE" >&2
            # atribuicao padrao para listra-privada
            CONTEST_DIR=$LISTAPRIVADADIR
        ;;
    esac
    
    # Verificar se o diretório de concurso existe
    if [ ! -d "$CONTEST_DIR" ]; then
        mkdir -p "$CONTEST_DIR"
    fi
    
    local PROBLEMID=$(jq -r '.problemid' <<< "$JSON")
    local LANGUAGE=$(jq -r '.language' <<< "$JSON")
    local FILENAME=$(basename $(jq -r '.filename' <<< "$JSON"))
    local FILEB64=$(jq -r '.fileb64' <<< "$JSON")
    local JOBID=$(echo "$EPOCHSECONDS $$ $JSON $HOSTNAME $SRANDOM" | sha224sum | awk '{print $1}')
    if jq -r '.metadata' <<< "$JSON" | grep -q ':rejulgar:'; then
        CONTEST_DIR=$REJULGARDIR
    fi    
    # Obter o timestamp atual para usar no nome do arquivo
    local CURRENT_TIMESTAMP=$(date +"%s")
    local JSON_FILE="$CONTEST_DIR${CURRENT_TIMESTAMP}_${JOBID}.json"
    
    # Escrever o arquivo JSON no diretório apropriado
    mkdir -p "$(dirname "$JSON_FILE")"
    echo "$JSON" > "$JSON_FILE"

    # Definir o arquivo de lock
    local LOCKFILE="${MASTERDIR}/lock/${CURRENT_TIMESTAMP}_${JOBID}.json.lock"

    # Usar flock para garantir que a área crítica seja executada de forma segura
    (
        flock 9 || { echo "Falha ao usar o lock."; exit 1; }

        # Área crítica: gerando código ticket
        jq --arg jobid "$JOBID" '. + {jobid: $jobid}' "$JSON_FILE" > "$JSON_FILE.tmp" && mv "$JSON_FILE.tmp" "$JSON_FILE"

        # Adicionando o atributo enviado_master
        jq --arg enviado_master_ts "$CURRENT_TIMESTAMP" '. + {enviado_master_ts: $enviado_master_ts}' "$JSON_FILE" > "$JSON_FILE.tmp" && mv "$JSON_FILE.tmp" "$JSON_FILE"
    ) 9>"$LOCKFILE"

    echo "{ \"jobid\": \"$JOBID\" }"
}

function cmd-islocked()
{
    FREEMACHINE=/dev/shm/free-machine
    #if flock -n $FREEMACHINE true && grep -q '^0.0' /proc/loadavg; then
    if flock -n $FREEMACHINE true ; then
        echo '{ "status": "false" }'
    else
        echo '{ "status": "true" }'
    fi
}

function cmd-reportmachine()
{
    echo -n "{ \"hostname\": \"$HOSTNAME\", \"arch\": \"$(arch)\", \"cpu\":"
    echo -n " \"$(grep 'model name' /proc/cpuinfo|head -n1|cut -d: -f2-)\","
    echo " \"memory\": $(head -n1 /proc/meminfo|awk '{print $(NF-1)}') }"
}

# Consulta UMA máquina (host:port): reportmachine + islocked -> escreve o JSON em $2.
function _query_machine()
{
    local hp="$1" out="$2" host="${1%%:*}" port="${1##*:}" rep lock on busy
    rep=$(echo '{ "cmd": "reportmachine" }' | timeout 3 nc -w 2 "$host" "$port" 2>/dev/null)
    lock=$(echo '{ "cmd": "islocked" }'      | timeout 3 nc -w 2 "$host" "$port" 2>/dev/null | jq -r '.status' 2>/dev/null)
    if [[ -n "$rep" ]] && jq -e 'has("hostname")' >/dev/null 2>&1 <<< "$rep"; then on=true; else on=false; rep='{}'; fi
    [[ "$lock" == "true" ]] && busy=true || busy=false
    jq -cn --arg h "$host" --arg p "$port" --argjson on "$on" --argjson busy "$busy" --argjson rep "$rep" \
        '{ host:$h, port:($p|tonumber? // $p), online:$on, busy:$busy, report:$rep }' > "$out"
}

# Lista TODAS as máquinas configuradas (MOJPORTS do escalonador), consultando em paralelo.
function cmd-listmachines()
{
    local ESC; ESC="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/escalonador.sh"
    [[ -f "$ESC" ]] || ESC="./escalonador.sh"
    local ports=() hp tmp i=0
    while read -r hp; do [[ -n "$hp" ]] && ports+=("$hp"); done \
        < <(grep -E '^[[:space:]]*MOJPORTS\+=\(' "$ESC" 2>/dev/null | sed -E 's/.*\(([^)]+)\).*/\1/' | tr ' ' '\n')
    tmp=$(mktemp -d)
    for hp in "${ports[@]}"; do
        _query_machine "$hp" "$tmp/$(printf '%04d' "$i")" &
        ((i++))
    done
    wait
    cat "$tmp"/* 2>/dev/null | jq -cs '{ machines: ., count: length, online_count: (map(select(.online))|length) }'
    rm -rf "$tmp"
}

function cmd-getresultindirect()
{
    local JOBMASTER=$1

    # Encontrar o arquivo json com o id $JOBMASTER
    local FILE=$(find "$ENVIADODIR" -type f -name "*$JOBMASTER*.json" -print -quit)
    
    JOB_SELECIONADO=$FILE
    
    if [ -z "$FILE" ]; then 
        HOSTEXECUCAO=""
        PORTAEXECUCAO=""
        JOBIDHOST=""
    else
        # Pegar do json o host, porta e ID de execução
        HOSTEXECUCAO=$(jq -r '.host' "$FILE")
        PORTAEXECUCAO=$(jq -r '.porta' "$FILE")
        JOBIDHOST=$(jq -r '.codigo' "$FILE")
    fi
}

function cmd-getresult()
{
    # id do job-master
    local JOBID=$(jq -r '.jobid' <<< "$JSON")
    local STATUS_RESPONSE="On queue"
    local REQUESTDATE_RESPONSE=""
    
    cmd-getresultindirect "$JOBID"
    # Verifica se o arquivo foi encontrado e as informacoes extraídas corretamente
    if [ ! -z "$HOSTEXECUCAO" ] && [ ! -z "$PORTAEXECUCAO" ] && [ ! -z "$JOBIDHOST" ]; then
        RESPONSE=$(echo "{ \"cmd\": \"getresult\", \"jobid\": \"$JOBIDHOST\"}" | nc $HOSTEXECUCAO $PORTAEXECUCAO | jq -c '.')
        # Extrair informações da resposta
        STATUS_RESPONSE=$(jq -r '.status' <<< "$RESPONSE")
        REQUESTDATE_RESPONSE=$(jq -r '.jobrequested' <<< "$RESPONSE")
    fi

    if [ "$STATUS_RESPONSE" != "On queue" ] && [ ! -z "$STATUS_RESPONSE" ]; then
        # Verifica se o atributo resultado_final ja existe ou esta vazio
        local RESULTADO_FINAL=$(echo "$JSON" | jq -r '.resultado_final_ts')
        if [ "$RESULTADO_FINAL" = "null" ]; then
            # Adiciona o atributo resultado_final com o timestamp atual ao JSON
            local CURRENT_TIMESTAMP=$(date +"%s")

            # Definir o arquivo de lock
            local LOCKFILE="${MASTERDIR}/lock/$(basename ${JOB_SELECIONADO}).lock"

            # Usar flock para garantir que a área crítica seja executada de forma segura
            (
                flock 9 || { echo "Falha ao usar o lock."; exit 1; }

                jq --arg resultado_final_ts "$CURRENT_TIMESTAMP" '. + {resultado_final_ts: $resultado_final_ts}' "$JOB_SELECIONADO" > "$JOB_SELECIONADO.tmp" && mv "$JOB_SELECIONADO.tmp" "$JOB_SELECIONADO"
                
            ) 9>"$LOCKFILE"
            rm $LOCKFILE
        fi
    fi

  cat << EOF | jq -c .
{ "id": "$JOBID",
  "status": "$STATUS_RESPONSE",
  "jobrequested": "$REQUESTDATE_RESPONSE",
  "logfileb64": null
}
EOF
}

function cmd-getresultfull() {
    # id do job-master
    local JOBID=$(jq -r '.jobid' <<< "$JSON")
        
    cmd-getresultindirect "$JOBID"
    # Verifica se o arquivo foi encontrado e as informacoes extraídas corretamente
    if [ ! -z "$HOSTEXECUCAO" ] && [ ! -z "$PORTAEXECUCAO" ] && [ ! -z "$JOBIDHOST" ]; then
        RESPONSE=$(echo "{ \"cmd\": \"getresultfull\", \"jobid\": \"$JOBIDHOST\"}" | nc $HOSTEXECUCAO $PORTAEXECUCAO | jq -c '.')
        
        # Extrair informações da resposta
        STATUS_RESPONSE=$(jq -r '.status' <<< "$RESPONSE")
        REQUESTDATE_RESPONSE=$(jq -r '.jobrequested' <<< "$RESPONSE")
        LOGFILEB64=$(jq -r '.logfileb64' <<< "$RESPONSE")
    fi

    cat << EOF | jq -c .
{ "id": "$JOBID",
  "status": "$STATUS_RESPONSE",
  "jobrequested": "$REQUESTDATE_RESPONSE",
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

for f in run getresultfull getresult reportmachine islocked listmachines; do
    COMMANDFUNCTIONS[$f]=true
done

#JSON is global
read JSON

CMD=$(jq -r '.cmd' <<< "$JSON" | tr -d '"')
set -x

if [[ -n "${COMMANDFUNCTIONS[$CMD]}" ]]; then
  cmd-$CMD
else
  cmd-unknowncommand
fi

set +x
