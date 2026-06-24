#!/bin/bash
MASTERDIR="./master"

# "filas" para os tipos de submissões
FILAPRIORIDADES=()
FILAPRIORIDADES+=("${MASTERDIR}/000-super/")          # prioridade 1
FILAPRIORIDADES+=("${MASTERDIR}/001-intermed/")       # prioridade 2
FILAPRIORIDADES+=("${MASTERDIR}/019-intermed/")       # prioridade 3
FILAPRIORIDADES+=("${MASTERDIR}/020-prova/")          # prioridade 4
FILAPRIORIDADES+=("${MASTERDIR}/021-intermed/")       # prioridade 5
FILAPRIORIDADES+=("${MASTERDIR}/039-intermed/")       # prioridade 6
FILAPRIORIDADES+=("${MASTERDIR}/040-lista-privada/")  # prioridade 7
FILAPRIORIDADES+=("${MASTERDIR}/041-intermed/")       # prioridade 8
FILAPRIORIDADES+=("${MASTERDIR}/059-intermed/")       # prioridade 9
FILAPRIORIDADES+=("${MASTERDIR}/060-rejulgar/")      # prioridade 10
FILAPRIORIDADES+=("${MASTERDIR}/061-intermed/")      # prioridade 11
FILAPRIORIDADES+=("${MASTERDIR}/079-intermed/")      # prioridade 12
FILAPRIORIDADES+=("${MASTERDIR}/080-lista-publica/") # prioridade 13

ENFILEIRADODIR="${MASTERDIR}/enfileirado/"
ENVIADODIR="${MASTERDIR}/enviado/"
LOCKDIR="${MASTERDIR}/lock/"
LOGDIR="${MASTERDIR}/logs/"

MOJPORTS=()
MOJPORTS+=(pos2:41000) # pos2
MOJPORTS+=(pos1:41050) # pos1
MOJPORTS+=(gpu2:42050) # gpu2
MOJPORTS+=(gpu3:42100) # gpu3
MOJPORTS+=(gpu1:42000) # gpu1
MOJPORTS+=(cm2:43050) # cm2
MOJPORTS+=(cm3:43100) # cm3
MOJPORTS+=(cm4:43150) # cm4
MOJPORTS+=(cm1:43000) # cm1
MOJPORTS+=(hu1:44000) # hu1

LISTADELIVRES=()

function enviar_cdmoj() {
    local LISTAJOBS=()
    # Loop para cada arquivo dentro do diretório ENFILEIRADODIR
    for job in "$ENFILEIRADODIR"*.json; do
        # Verifica se o arquivo é realmente um arquivo regular
        if [ -f "$job" ]; then
            # Adiciona o job à lista de jobs
            LISTAJOBS+=("$job")
        fi
    done
    
    local max=0
    # Verifica se o tamanho de LISTAJOBS é menor ou igual ao tamanho de LISTADELIVRES
    if [ ${#LISTAJOBS[@]} -le ${#LISTADELIVRES[@]} ]; then
        max=${#LISTAJOBS[@]}
    else
        max=${#LISTADELIVRES[@]}
    fi
    
    # Loop para verificar se algum job precisa rodar em uma máquina específica
    for ((i = 0; i < max; i++)); do
        local job="${LISTAJOBS[i]}"
        local EXECUTAR_EM="$(jq -r '.executar_em' "$job")"
        trata_envio $job $EXECUTAR_EM
    done
    
    # Limpa as listas depois do loop
    unset LISTADELIVRES
}

# Função para encontrar o índice de um elemento em uma array
function index_of() {
    local element="$1"
    shift
    local array=("$@")
    for i in "${!array[@]}"; do
        if [[ "${array[$i]}" == "$element" ]]; then
            echo "$i"
            return
        fi
    done
    echo "-1"  # Retorna -1 se o elemento não for encontrado
}

# Função para encontrar o índice de um servidor (apenas nome do host)
function index_of_server() {
    local server="$1"
    local array=("${!2}")
    for i in "${!array[@]}"; do
        local host="${array[$i]%%:*}"
        if [[ "$host" == "$server" ]]; then
            echo "$i"
            return
        fi
    done
    echo "-1"  # Retorna -1 se o servidor não for encontrado
}

function trata_envio() {
    ARQFONTE=$1
    porta=$2
    # Extrai as informações necessárias do JSON
    local PROBID=$(jq -r '.problemid' "$ARQFONTE")
    local LINGUAGEM=$(jq -r '.language' "$ARQFONTE")
    local FILENAME=$(jq -r '.filename' "$ARQFONTE")
    local FILEB64=$(jq -r '.fileb64' "$ARQFONTE")
    
    # Cria um arquivo temporário
    local TEMP=$(mktemp)
    
    # Constrói o comando JSON
    cat << EOF > "$TEMP"
{ "cmd": "run", "problemid": "$PROBID", "language": "$LINGUAGEM", "filename": "$FILENAME", "fileb64": "$FILEB64", "metadata": "$ARQFONTE" }
EOF
    
    # Envia o comando para a máquina correspondente
    local PORT="${porta}"
    # VERIFICAR FALHA
    set +x
    timeout 60 nc "${PORT/:??*}" "${PORT/??*:/}" < $TEMP > $TEMP.a
    echo "==============="
    cat $TEMP.a
    echo "==============="
        CODIGO=$(jq -r .jobid < $TEMP.a)
    set +x
    if [[ -n "$CODIGO" ]]; then
        
        # Imprime o resultado
        log_message "$PORT-$CODIGO" | tr ':' ','
        log_message "$PORT-$CODIGO" >&2
        log_message "=== $CODIGO" >&2
        
        local CURRENT_TIMESTAMP=$(date +"%s")
        
        # Definir o arquivo de lock
        local LOCKFILE="${LOCKDIR}$(basename ${ARQFONTE}).lock"
        
        # Usar flock para garantir que a área crítica seja executada de forma segura
        (
            flock 9 || { log_message "Falha ao usar o lock."; exit 1; }
            
            # Salvar a porta, o host e o código no JSON
            jq --arg PORT "$(echo "$porta" | cut -d ':' -f 2)" \
            --arg HOST "$(echo "$porta" | cut -d ':' -f 1)" \
            --arg CODIGO "$CODIGO" \
            --arg TIMESTAMP "$CURRENT_TIMESTAMP" \
            '.porta = $PORT | .host = $HOST | .codigo = $CODIGO | .enviado_correcao_ts = $TIMESTAMP' \
            "$ARQFONTE" > tmp.json && mv tmp.json "$ARQFONTE"
            
        ) 9>"$LOCKFILE"
        
        # Remove arquivos temporários
        rm "$TEMP.a" "$TEMP"
        
        # Move o job da fila de enfileirados para a fila de enviados
        mv "$ARQFONTE" "$ENVIADODIR"
    else
        log_message "Falha ao enviar o comando para a maquina $porta"
    fi
    set +x
}

function get_free_machine() {
    echo "getting free machines..."
    while [[ ${#LISTADELIVRES[@]} -eq 0 ]]; do
        for p in "${MOJPORTS[@]}"; do
            echo '{ "cmd": "islocked" }' | timeout 3 nc -w 1 "${p/:??*}" "${p/??*:}" | grep -q "false" && LISTADELIVRES+=("$p")
        done
        sleep 1
    done
}

function run2()
{
    echo "running..."
    NUM_MAQ=${#LISTADELIVRES[@]}
    echo "numero de maquinas livres: $NUM_MAQ"

    declare -A TORUN
    declare -A TORUN_L
    for L in "${LISTADELIVRES[@]}"; do
        TORUN_L[$L,l]=1
    done 

    for FILA in "${FILAPRIORIDADES[@]}"; do
        for job in "$FILA"/*.json; do
            [[ ! -e $job ]] && break
            ((NUM_MAQ <= 0)) && break 2
            
            log_message "fila atual: $FILA"
            local MOJCONTESTSERVERS="$(jq -r '.contest_servers' "$job")"
            
            if [[ -z $MOJCONTESTSERVERS ]]; then
                TORUN[ANY]+="$job "
                ((NUM_MAQ--))
                log_message "job pode rodar em qualquer maquina"
                log_message "novo numero de maquinas livres: $NUM_MAQ"
                continue
            fi
        
            for MAQ in $MOJCONTESTSERVERS; do
                index=$(index_of_server "$MAQ" LISTADELIVRES[@])
                    if [[ $index -ne -1 ]]; then
                        log_message "fila atual: $fila"
                        log_message "Indice de $MAQ: $index"
                        local porta="${LISTADELIVRES[$index]}"

                        if [[ -n "${TORUN_L[$porta]}" ]]; then
                            unset TORUN_L[$porta,l]
                            TORUN["$porta"]="$job"
                            ((NUM_MAQ--))
                            log_message "job necessita rodar em maquina especifica"
                            log_message "novo numero de maquinas livres: $NUM_MAQ"
                            break
                        fi
                    fi
            done
        done
    done

    VETORLIVRES=(${!TORUN_L[@]})

    i=0
    for job in ${TORUN[ANY]}; do
        TORUN["${VETORLIVRES[$i]}"]="$job"
        local LOCKFILE="${LOCKDIR}/$(basename "$job").lock"
        # Usar flock para garantir que a área crítica seja executada de forma segura
        (
            flock 9 || { echo "Falha ao usar o lock."; exit 1; }
            
            # Adiciona a variável 'executar_em' ao JSON
            jq --arg executar_em "${VETORLIVRES[$i]}" '. + {executar_em: $executar_em}' "$job" > "$job.tmp" && mv "$job.tmp" "$job"
            
        ) 9>"$LOCKFILE"
        
        mv "$job" "$ENFILEIRADODIR"
        ((i++))
    done

    unset TORUN[ANY]
}

function run()
{
    echo "running..."
    LISTADELIVRES_TEMP=("${LISTADELIVRES[@]}")
    NUM_MAQ=${#LISTADELIVRES_TEMP[@]}
    echo "numero de maquinas livres: $NUM_MAQ"
    
    ENFILEIRADOS=()
    
    num_jobs_selecionados=0
    
    # Pegar X jobs até ser igual ao NUM_MAQ -> MOJCONTESTSERVERS
    echo "Loop para verificar jobs que devem rodar em porta especifica"
    for ((i=0; i<${#FILAPRIORIDADES[@]}; i++)); do
        fila="${FILAPRIORIDADES[i]}"
        
        if [[ -n $fila && -d $fila && -n "$(find "$fila" -maxdepth 1 -name '*.json' -print -quit)" ]]; then
            for job in "$fila"/*.json; do
                
                if (( NUM_MAQ == 0 )); then
                    break 2  # Sai do loop externo e interno
                fi
                
                ### analisar se o job precisa rodar em uma porta especifica
                local MOJCONTESTSERVERS="$(jq -r '.contest_servers' "$job")"
                
                # Verifica se MOJCONTESTSERVERS está na LISTADELIVRES_TEMP e pega a porta correspondente na lista
                # Envia o JOB para o SERVER CORRESPONDENTE
                for server in $MOJCONTESTSERVERS; do
                    index=$(index_of_server "$server" LISTADELIVRES_TEMP[@])
                    if [[ $index -ne -1 ]]; then
                        log_message "fila atual: $fila"
                        log_message "Indice de $server: $index"
                        local porta="${LISTADELIVRES_TEMP[$index]}"
                        
                        log_message "Processando job em servidor ESPECIFICO na porta $porta"
                        
                        local LOCKFILE="${LOCKDIR}$(basename ${job}).lock"
                        # Usar flock para garantir que a área crítica seja executada de forma segura
                        (
                            flock 9 || { log_message "Falha ao usar o lock."; exit 1; }
                            
                            # adicionar a variavel executar_em:
                            jq --arg executar_em "$porta" '. + {executar_em: $executar_em}' "$job" > "$job.tmp" && mv "$job.tmp" "$job"
                            
                        ) 9>"$LOCKFILE"
                        
                        mv "$job" "$ENFILEIRADODIR"
                        # Remove o servidor da LISTADELIVRES_TEMP
                        unset LISTADELIVRES_TEMP[$index]
                        LISTADELIVRES_TEMP=("${LISTADELIVRES_TEMP[@]}")
                        NUM_MAQ=${#LISTADELIVRES_TEMP[@]} ## remove 1 do numero de maquinas
                        log_message "novo numero de maquinas livres: $NUM_MAQ"
                        num_jobs_selecionados=$((num_jobs_selecionados + 1))
                        break 1
                    fi
                done
                
                if (( NUM_MAQ == 0 )); then
                    break 2  # Sai do loop externo e interno
                fi
            done
        fi
    done
    
    echo "Loop para verificar jobs que podem rodar em qualquer porta"
    for ((i=0; i<${#FILAPRIORIDADES[@]}; i++)); do
        fila="${FILAPRIORIDADES[i]}"
        
        if [[ -n $fila && -d $fila && -n "$(find "$fila" -maxdepth 1 -name '*.json' -print -quit)" ]]; then
            for job in "$fila"/*.json; do
                if (( NUM_MAQ == 0 )); then
                    break 2  # Sai do loop externo e interno
                fi
                
                ### analisar se o job precisa rodar em uma porta especifica se sim, pula para o proximo
                local MOJCONTESTSERVERS="$(jq -r '.contest_servers' "$job")"
                [[ -n "$MOJCONTESTSERVERS" ]] && continue
                
                ### segue fluxo normal: job pode rodar em qualquer porta
                if [[ ${#LISTADELIVRES_TEMP[@]} -gt 0 ]]; then
                    local porta="${LISTADELIVRES_TEMP[0]}"
                    log_message "fila atual: $fila"
                    log_message "Processando job em um servidor QUALQUER na porta $porta" 
                    
                    local LOCKFILE="${LOCKDIR}$(basename ${job}).lock"
                    
                    # Usar flock para garantir que a área crítica seja executada de forma segura
                    (
                        flock 9 || { log_message "Falha ao usar o lock."; exit 1; }
                        
                        # adicionar a variavel executar_em:
                        jq --arg executar_em "$porta" '. + {executar_em: $executar_em}' "$job" > "$job.tmp" && mv "$job.tmp" "$job"
                        
                    ) 9>"$LOCKFILE"
                    
                    # Remove o servidor da LISTADELIVRES_TEMP
                    index=$(index_of "$porta" "${LISTADELIVRES_TEMP[@]}")
                    if [[ $index -ne -1 ]]; then
                        log_message "Indice de $porta: $index"
                        mv "$job" "$ENFILEIRADODIR"
                        unset LISTADELIVRES_TEMP[$index]
                        LISTADELIVRES_TEMP=("${LISTADELIVRES_TEMP[@]}")
                        NUM_MAQ=${#LISTADELIVRES_TEMP[@]} ## remove 1 do numero de maquinas
                        log_message "novo numero de maquinas livres: $NUM_MAQ"
                        num_jobs_selecionados=$((num_jobs_selecionados + 1))
                    fi
                fi
            done
        fi
    done
    
    echo "numero de jobs selecionados: $num_jobs_selecionados"
}

# itera em todos os jobs da fila (diretorios das prioridades)
# if (tempo de espera > 5 minutos) -> eleva-prioridade
function check_starvation()
{
    echo "checking starvation..."
    for ((i=0; i<${#FILAPRIORIDADES[@]}; i++)); do
        fila="${FILAPRIORIDADES[i]}"
        prioridade_anterior_index=$((i - 1))
        
        if [[ $prioridade_anterior_index -ge 0 ]]; then
            diretorio_anterior="${FILAPRIORIDADES[prioridade_anterior_index]}"
        else
            diretorio_anterior=""
        fi
        
        if [[ -n $fila && -d $fila && -n "$(find "$fila" -maxdepth 1 -name '*.json' -print -quit)" ]]; then
            for job in "$fila"/*.json; do
                timestamp_arquivo=$(basename "$job" .json | cut -d_ -f1)
                tempo_de_espera=$(( $(date +%s) - timestamp_arquivo ))
                
                if [[ $tempo_de_espera -gt 300 ]]; then  # Se o tempo de espera for superior a 5 minutos (300 segundos)
                    if [[ -n $diretorio_anterior ]]; then
                        # Cria um novo timestamp
                        novo_timestamp=$(date +%s)
                        # Remove o timestamp antigo e obtém o nome base do arquivo
                        nome_base_sem_timestamp=$(basename "$job" .json | cut -d_ -f2-)
                        novo_nome_arquivo="${novo_timestamp}_${nome_base_sem_timestamp}.json"
                        novo_caminho_arquivo="$diretorio_anterior/$novo_nome_arquivo"

                        # Move o arquivo para o diretório anterior
                        log_message "movendo $job da fila $fila para $diretorio_anterior"
                        mv "$job" "$novo_caminho_arquivo"
                    fi
                fi
            done
        fi
    done
}

function win_queue ()
{
    get_free_machine
    enviar_cdmoj
    
    # verifica se ainda tem job para vencer
    for job in "$ENFILEIRADODIR"*.json; do
        if [ -f "$job" ]; then
            win_queue
        fi
    done
    
    echo "Lista vencida"
}

function log_message() {
    local message="$1"

    logfile="${LOGDIR}escalonador-$(date +'%Y-%m-%d').log"

    local timestamp=$(date +'%Y-%m-%dT%H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$logfile"
}

function create_dir() {
    for dir in "$@"; do
        mkdir -p "$dir"
    done
}

create_dir "${FILAPRIORIDADES[@]}" "$ENFILEIRADODIR" "$ENVIADODIR" "$LOCKDIR" "$LOGDIR"

# function rename_dirs() {
#     for (( i=0; i<${#OLD_DIRS[@]}; i++ )); do
#         mv "${OLD_DIRS[$i]}" "${FILAPRIORIDADES[$i]}"
#     done
# }

# rename_dirs

while true; do
    echo "Tenta vencer a lista de enfileirados primeiro"
    win_queue
    echo
    echo "Fluxo normal"
    get_free_machine
    echo
    run
    echo
    enviar_cdmoj
    echo
    check_starvation
    echo
    sleep 0.5
done
