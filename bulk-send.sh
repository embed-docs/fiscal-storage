#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bulk-send.sh — Envio massivo de XMLs fiscais para a XML Ingest API
#
# Uso:
#   ./scripts/bulk-send.sh <api_key> <path_xmls> [opcoes]
#
# Exemplos:
#   ./scripts/bulk-send.sh emb_abc123... /tmp/notas/
#   ./scripts/bulk-send.sh emb_abc123... /tmp/notas/ --recursive
#   ./scripts/bulk-send.sh emb_abc123... /tmp/notas/ --recursive --parallel 20
#   ./scripts/bulk-send.sh emb_abc123... /tmp/notas/ --env prod
#   ./scripts/bulk-send.sh emb_abc123... /tmp/notas/ --organize
#   ./scripts/bulk-send.sh emb_abc123... /tmp/notas/ --recursive --parallel 20 --verbose
#   ./scripts/bulk-send.sh emb_abc123... /tmp/notas/ --sent-log /tmp/meu-controle.log
#
# Opcoes:
#   --parallel N    Numero de envios simultaneos (default: 10)
#   --env ENV       Ambiente: dev | prod (default: dev)
#   --recursive     Varre subdiretorios recursivamente buscando XMLs
#   --organize      Move XMLs para subpastas processed/ e errors/ apos envio
#   --sent-log FILE Caminho do arquivo de controle de enviados (default: <path_xmls>/.bulk-send-sent.log)
#   --dry-run       Apenas lista os arquivos sem enviar
#   --verbose       Mostra detalhes de cada envio
#   --help          Mostra esta ajuda
#
# Retomada automatica:
#   O script registra cada XML enviado com sucesso em um arquivo de controle
#   (sent-log). Se o processo for interrompido, basta reexecutar o mesmo
#   comando — os arquivos ja enviados serao pulados automaticamente.
#   Os arquivos sao processados em ordem alfabetica pelo caminho completo.
#
# Estrutura com --organize:
#   <path_xmls>/
#     processed/    <- XMLs enviados com sucesso
#     errors/       <- XMLs com falha no envio
#     logs/         <- Relatorio de cada execucao
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
PARALLEL=10
ENV="dev"
DRY_RUN=false
VERBOSE=false
ORGANIZE=false
RECURSIVE=false
SENT_LOG=""
API_KEY=""
XML_PATH=""

# ── URLs por ambiente ─────────────────────────────────────────────────────
API_URL_DEV="https://storage-api.embed.zone/ingest"
API_URL_PROD=""  # preencher quando disponivel

# ── Parse de argumentos ──────────────────────────────────────────────────
show_help() {
    sed -n '2,/^# ----/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parallel)
            PARALLEL="$2"; shift 2 ;;
        --env)
            ENV="$2"; shift 2 ;;
        --recursive)
            RECURSIVE=true; shift ;;
        --organize)
            ORGANIZE=true; shift ;;
        --sent-log)
            SENT_LOG="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --verbose)
            VERBOSE=true; shift ;;
        --help|-h)
            show_help ;;
        -*)
            echo "ERRO: Opcao desconhecida: $1"; echo "Use --help para ver as opcoes."; exit 1 ;;
        *)
            if [ -z "$API_KEY" ]; then
                API_KEY="$1"
            elif [ -z "$XML_PATH" ]; then
                XML_PATH="$1"
            else
                echo "ERRO: Argumento inesperado: $1"; exit 1
            fi
            shift ;;
    esac
done

# ── Validacoes ────────────────────────────────────────────────────────────
if [ -z "$API_KEY" ] || [ -z "$XML_PATH" ]; then
    echo "Uso: $0 <api_key> <path_xmls> [opcoes]"
    echo "     $0 --help para mais detalhes"
    exit 1
fi

if [[ ! "$API_KEY" =~ ^emb_ ]]; then
    echo "ERRO: API key deve comecar com 'emb_'"
    exit 1
fi

# Normalizar path (remover trailing slash)
XML_PATH="${XML_PATH%/}"

if [ ! -d "$XML_PATH" ]; then
    echo "ERRO: Diretorio nao encontrado: $XML_PATH"
    exit 1
fi

case "$ENV" in
    dev)  API_URL="$API_URL_DEV" ;;
    prod)
        if [ -z "$API_URL_PROD" ]; then
            echo "ERRO: URL de producao ainda nao configurada. Edite API_URL_PROD no script."
            exit 1
        fi
        API_URL="$API_URL_PROD"
        ;;
    *)
        echo "ERRO: Ambiente '$ENV' nao reconhecido. Use: dev | prod"
        exit 1 ;;
esac

if ! command -v curl &>/dev/null; then
    echo "ERRO: curl nao encontrado."
    exit 1
fi

# ── Paths de organizacao ─────────────────────────────────────────────────
PROCESSED_DIR="$XML_PATH/processed"
ERRORS_DIR="$XML_PATH/errors"
LOGS_DIR="$XML_PATH/logs"

# Validar permissao de escrita no diretorio antes de prosseguir
if $ORGANIZE; then
    if [ ! -w "$XML_PATH" ]; then
        echo "ERRO: Sem permissao de escrita em: $XML_PATH"
        echo ""
        echo "O parametro --organize precisa criar subpastas nesse diretorio."
        echo "Execute o comando abaixo e tente novamente:"
        echo ""
        echo "  mkdir -p \"$PROCESSED_DIR\" \"$ERRORS_DIR\" \"$LOGS_DIR\""
        echo ""
        exit 1
    fi
fi

# ── Sent-log (controle de retomada) ──────────────────────────────────────
if [ -z "$SENT_LOG" ]; then
    SENT_LOG="$XML_PATH/.bulk-send-sent.log"
fi

# Se o diretorio do sent-log nao permite escrita, tentar /tmp
SENT_LOG_DIR=$(dirname "$SENT_LOG")
if [ ! -w "$SENT_LOG_DIR" ]; then
    SENT_LOG="/tmp/bulk-send-sent_$(echo "$XML_PATH" | sed 's/[^a-zA-Z0-9]/_/g').log"
    echo "AVISO: Sem permissao de escrita para sent-log no diretorio original."
    echo "       Usando: $SENT_LOG"
    echo ""
fi

# Carregar sent-log (se existir) para controle de retomada
if [ -f "$SENT_LOG" ]; then
    ALREADY_SENT=$(wc -l < "$SENT_LOG" | tr -d '[:space:]')
    if [ "$ALREADY_SENT" -gt 0 ]; then
        echo "Retomando: $ALREADY_SENT arquivo(s) ja enviado(s) serao pulados."
        echo "  (sent-log: $SENT_LOG)"
        echo ""
    fi
else
    ALREADY_SENT=0
fi

# ── Listar XMLs ─────────────────────────────────────────────────────────
FIND_ARGS=("$XML_PATH")
if ! $RECURSIVE; then
    FIND_ARGS+=(-maxdepth 1)
fi
# Excluir subpastas de organizacao
FIND_ARGS+=(-type f -name "*.xml" -not -path "*/processed/*" -not -path "*/errors/*" -not -path "*/logs/*" -print0)

ALL_XML_FILES=()
while IFS= read -r -d '' f; do
    ALL_XML_FILES+=("$f")
done < <(find "${FIND_ARGS[@]}" | sort -z)

# Filtrar arquivos ja enviados (busca exata no sent-log)
XML_FILES=()
SKIPPED=0
for f in "${ALL_XML_FILES[@]}"; do
    if [ -f "$SENT_LOG" ] && grep -qFx "$f" "$SENT_LOG"; then
        SKIPPED=$((SKIPPED + 1))
    else
        XML_FILES+=("$f")
    fi
done

TOTAL=${#XML_FILES[@]}
TOTAL_FOUND=${#ALL_XML_FILES[@]}

if [ "$TOTAL_FOUND" -eq 0 ]; then
    echo "Nenhum arquivo .xml encontrado em: $XML_PATH"
    if $RECURSIVE; then
        echo "(Busca recursiva ativada. Subpastas processed/, errors/ e logs/ sao ignoradas)"
    else
        echo "(Nota: subpastas nao foram varridas. Use --recursive para busca em subdiretorios)"
    fi
    exit 0
fi

if [ "$TOTAL" -eq 0 ]; then
    echo "Todos os $TOTAL_FOUND arquivo(s) .xml ja foram enviados anteriormente."
    echo "  (sent-log: $SENT_LOG)"
    echo ""
    echo "Para reenviar, remova ou renomeie o arquivo de controle."
    exit 0
fi

# ── Timestamp de inicio ──────────────────────────────────────────────────
START_TIME=$(date +%s)
START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')

echo "============================================"
echo " Envio Massivo — XML Ingest API"
echo " Ambiente:   $ENV"
echo " Endpoint:   $API_URL"
echo " Diretorio:  $XML_PATH"
echo " Recursivo:  $( $RECURSIVE && echo 'sim' || echo 'nao' )"
echo " Arquivos:   $TOTAL (de $TOTAL_FOUND encontrados, $SKIPPED ja enviados)"
echo " Paralelo:   $PARALLEL"
echo " Organizar:  $( $ORGANIZE && echo 'sim (processed/, errors/, logs/)' || echo 'nao' )"
echo " Sent-log:   $SENT_LOG"
echo " Inicio:     $START_DATETIME"
echo "============================================"
echo ""

if $DRY_RUN; then
    echo "[DRY-RUN] Arquivos que seriam enviados ($TOTAL):"
    for f in "${XML_FILES[@]}"; do
        echo "  $f"
    done
    echo ""
    if [ "$SKIPPED" -gt 0 ]; then
        echo "[DRY-RUN] Arquivos ja enviados (pulados): $SKIPPED"
    fi
    if $ORGANIZE; then
        echo "[DRY-RUN] Com --organize, arquivos seriam movidos para:"
        echo "  Sucesso: $PROCESSED_DIR/"
        echo "  Erro:    $ERRORS_DIR/"
        echo "  Log:     $LOGS_DIR/"
    fi
    echo ""
    echo "[DRY-RUN] Nenhum envio realizado."
    exit 0
fi

# ── Diretorios de resultado (temporario) ─────────────────────────────────
RESULT_DIR=$(mktemp -d)

# ── Funcao de envio (executada em paralelo) ──────────────────────────────
send_xml() {
    local xml_file="$1"
    local index="$2"
    local total="$3"
    local filename
    filename=$(basename "$xml_file")

    local http_code
    local response
    local tmpfile
    tmpfile=$(mktemp)

    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        -X POST "${API_URL}?filename=$(printf '%s' "$filename" | sed 's/ /%20/g')" \
        -H "X-Api-Key: $API_KEY" \
        -H "Content-Type: application/xml" \
        --data-binary "@$xml_file" \
        --max-time 30 \
        2>/dev/null) || http_code="000"

    response=$(cat "$tmpfile" 2>/dev/null || echo "")
    rm -f "$tmpfile"

    local hash=""
    local error=""

    if [ "$http_code" = "200" ]; then
        hash=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('hash',''))" 2>/dev/null || echo "")
        echo "OK|$xml_file|$http_code|$hash" >> "$RESULT_DIR/results.txt"
        # Registrar no sent-log para controle de retomada
        echo "$xml_file" >> "$SENT_LOG"
        if $VERBOSE; then
            echo "  [$index/$total] OK    $filename -> $hash"
        fi
    else
        error=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error', d.get('message','')))" 2>/dev/null || echo "$response")
        echo "ERRO|$xml_file|$http_code|$error" >> "$RESULT_DIR/results.txt"
        if $VERBOSE; then
            echo "  [$index/$total] ERRO  $filename -> HTTP $http_code: $error"
        fi
    fi
}

export -f send_xml
export API_URL API_KEY RESULT_DIR VERBOSE SENT_LOG

# ── Envio em paralelo ────────────────────────────────────────────────────
touch "$RESULT_DIR/results.txt"

echo "Enviando $TOTAL arquivo(s) com $PARALLEL thread(s)..."
echo ""

INDEX=0
PIDS=()

for xml_file in "${XML_FILES[@]}"; do
    INDEX=$((INDEX + 1))

    send_xml "$xml_file" "$INDEX" "$TOTAL" &
    PIDS+=($!)

    # Controle de paralelismo
    if [ ${#PIDS[@]} -ge "$PARALLEL" ]; then
        wait "${PIDS[0]}" 2>/dev/null || true
        PIDS=("${PIDS[@]:1}")
    fi

    # Progresso (a cada 10% ou a cada 50 arquivos)
    if ! $VERBOSE; then
        if (( TOTAL >= 50 && INDEX % (TOTAL / 10 + 1) == 0 )); then
            echo "  Progresso: $INDEX / $TOTAL ($(( INDEX * 100 / TOTAL ))%)"
        fi
    fi
done

# Aguardar os ultimos
for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

echo ""

# ── Timestamp de fim ─────────────────────────────────────────────────────
END_TIME=$(date +%s)
END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

# ── Organizar arquivos (mover para processed/ e errors/) ─────────────────
if $ORGANIZE; then
    MOVED_OK=0
    MOVED_ERR=0

    # Mover arquivos com sucesso para processed/
    if grep -q "^OK|" "$RESULT_DIR/results.txt" 2>/dev/null; then
        mkdir -p "$PROCESSED_DIR"
        grep "^OK|" "$RESULT_DIR/results.txt" | while IFS='|' read -r status filepath code info; do
            if [ -f "$filepath" ]; then
                mv "$filepath" "$PROCESSED_DIR/"
            fi
        done
        MOVED_OK=$(grep -c "^OK|" "$RESULT_DIR/results.txt" 2>/dev/null | tr -d '[:space:]')
        [ -z "$MOVED_OK" ] && MOVED_OK=0
    fi

    # Mover arquivos com erro para errors/
    if grep -q "^ERRO|" "$RESULT_DIR/results.txt" 2>/dev/null; then
        mkdir -p "$ERRORS_DIR"
        grep "^ERRO|" "$RESULT_DIR/results.txt" | while IFS='|' read -r status filepath code info; do
            if [ -f "$filepath" ]; then
                mv "$filepath" "$ERRORS_DIR/"
            fi
        done
        MOVED_ERR=$(grep -c "^ERRO|" "$RESULT_DIR/results.txt" 2>/dev/null | tr -d '[:space:]')
        [ -z "$MOVED_ERR" ] && MOVED_ERR=0
    fi

    echo "Arquivos organizados:"
    if [ "$MOVED_OK" -gt 0 ]; then
        echo "  $MOVED_OK movido(s) para $PROCESSED_DIR/"
    fi
    if [ "$MOVED_ERR" -gt 0 ]; then
        echo "  $MOVED_ERR movido(s) para $ERRORS_DIR/"
    fi
    echo ""
fi

# ── Relatorio ─────────────────────────────────────────────────────────────
OK_COUNT=$(grep -c "^OK|" "$RESULT_DIR/results.txt" 2>/dev/null | tr -d '[:space:]')
ERRO_COUNT=$(grep -c "^ERRO|" "$RESULT_DIR/results.txt" 2>/dev/null | tr -d '[:space:]')
[ -z "$OK_COUNT" ] && OK_COUNT=0
[ -z "$ERRO_COUNT" ] && ERRO_COUNT=0

echo "============================================"
echo " Resultado"
echo "============================================"
echo "  Enviados:   $TOTAL"
echo "  Sucesso:    $OK_COUNT"
echo "  Erros:      $ERRO_COUNT"
echo "  Pulados:    $SKIPPED (ja enviados anteriormente)"
echo "  Inicio:     $START_DATETIME"
echo "  Fim:        $END_DATETIME"
echo "  Duracao:    ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo "  Sent-log:   $SENT_LOG"
echo ""

if [ "$ERRO_COUNT" -gt 0 ]; then
    echo "Arquivos com erro:"
    grep "^ERRO|" "$RESULT_DIR/results.txt" | while IFS='|' read -r status filepath code msg; do
        echo "  $(basename "$filepath") — HTTP $code: $msg"
    done
    echo ""
fi

# ── Salvar log ────────────────────────────────────────────────────────────
LOG_FILENAME="bulk-send_$(date '+%Y%m%d_%H%M%S').log"

if $ORGANIZE; then
    mkdir -p "$LOGS_DIR"
    LOG_FILE="$LOGS_DIR/$LOG_FILENAME"
else
    LOG_FILE="$RESULT_DIR/$LOG_FILENAME"
fi

{
    echo "============================================"
    echo " Relatorio — bulk-send.sh"
    echo "============================================"
    echo "Ambiente:    $ENV"
    echo "Endpoint:    $API_URL"
    echo "Diretorio:   $XML_PATH"
    echo "Recursivo:   $RECURSIVE"
    echo "Paralelo:    $PARALLEL"
    echo "Organize:    $ORGANIZE"
    echo "Sent-log:    $SENT_LOG"
    echo "Inicio:      $START_DATETIME"
    echo "Fim:         $END_DATETIME"
    echo "Duracao:     ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
    echo "Enviados:    $TOTAL"
    echo "Pulados:     $SKIPPED"
    echo "Sucesso:     $OK_COUNT"
    echo "Erros:       $ERRO_COUNT"
    echo "============================================"
    echo ""
    echo "DETALHES (status|arquivo|http_code|info):"
    echo "--------------------------------------------"
    cat "$RESULT_DIR/results.txt"
} > "$LOG_FILE"

echo "Relatorio salvo em: $LOG_FILE"

# Cleanup
rm -rf "$RESULT_DIR"

if [ "$ERRO_COUNT" -gt 0 ]; then
    exit 1
fi
