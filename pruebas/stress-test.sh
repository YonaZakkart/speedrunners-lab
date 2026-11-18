#!/usr/bin/env bash
#
# Prueba de estres de SpeedRunners Inc.
#
# Simula usuarios concurrentes con ApacheBench (ab) contra la plataforma y
# resume: requests/segundo, latencia media, p95, p99, errores y tasa de cache.
#
# Uso:
#   ./pruebas/stress-test.sh                 # 1000 requests / 100 concurrentes (oficial)
#   ./pruebas/stress-test.sh -n 5000 -c 200  # parametrizado
#   ./pruebas/stress-test.sh --no-cold       # omite la prueba sin cache
#
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
REQUESTS="${REQUESTS:-1000}"
CONCURRENCY="${CONCURRENCY:-100}"
TIMEOUT="${TIMEOUT:-30}"
COLD_TEST=1
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$PROJECT_DIR/pruebas/resultados"
STAMP="$(date '+%Y%m%d_%H%M%S')"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) REQUESTS="$2"; shift 2 ;;
        -c) CONCURRENCY="$2"; shift 2 ;;
        --no-cold) COLD_TEST=0; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Opcion desconocida: $1"; exit 1 ;;
    esac
done

if ! command -v ab >/dev/null 2>&1; then
    echo "ERROR: 'ab' no esta instalado. Instala httpd-tools:"
    echo "  sudo dnf install -y httpd-tools"
    exit 1
fi

mkdir -p "$OUT_DIR"

if ! curl -sf --max-time 3 "$BASE_URL/health" >/dev/null 2>&1 \
   && ! curl -sf --max-time 3 "$BASE_URL/" >/dev/null 2>&1; then
    echo "ERROR: la plataforma no responde en $BASE_URL"
    echo "  Levanta el stack con: docker compose up -d"
    exit 1
fi

# Extrae una metrica numerica del informe de ab
metric() {
    awk -v key="$1" '
        index($0, key) == 1 {
            for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) { print $i; exit }
        }' "$2"
}

percentile() {
    awk -v p="$1" '
        $1 == p "%" { print $2; exit }
        $1 == "100%" { print $2; exit }' "$2"
}

run_ab() {
    local label="$1" url="$2" log="$3"
    ab -n "$REQUESTS" -c "$CONCURRENCY" -s "$TIMEOUT" "$url" > "$log" 2>&1
}

print_result() {
    local label="$1" log="$2"
    local rps mean p50 p95 p99 failed non2xx

    rps="$(metric "Requests per second:" "$log")"
    mean="$(metric "Time per request:" "$log")"
    p50="$(percentile 50 "$log")"
    p95="$(percentile 95 "$log")"
    p99="$(percentile 99 "$log")"
    failed="$(metric "Failed requests:" "$log")"
    non2xx="$(metric "Non-2xx responses:" "$log")"
    non2xx="${non2xx:-0}"

    printf "\n  %-34s\n" "$label"
    printf "    Requests per second ......... %s\n" "${rps:-0}"
    printf "    Time per request (media) .... %s ms\n" "${mean:-0}"
    printf "    p50 / p95 / p99 ............. %s / %s / %s ms\n" "${p50:-0}" "${p95:-0}" "${p99:-0}"
    printf "    Failed requests ............. %s\n" "${failed:-0}"
    printf "    Non-2xx responses ........... %s\n" "$non2xx"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$STAMP" "$label" "$REQUESTS" "$CONCURRENCY" \
        "${rps:-0}" "${mean:-0}" "${p95:-0}" "${p99:-0}" "${failed:-0}" "$non2xx" \
        >> "$OUT_DIR/historial.csv"
}

echo "=========================================================================="
echo "  SPEEDRUNNERS INC. - PRUEBA DE ESTRES"
echo "=========================================================================="
echo "  Objetivo ......... $BASE_URL/"
echo "  Requests ......... $REQUESTS"
echo "  Concurrencia ..... $CONCURRENCY usuarios"
echo "  Inicio ........... $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Resultados ....... $OUT_DIR/"
echo "=========================================================================="

# Calienta el stack y deja la entrada en cache
curl -s -o /dev/null "$BASE_URL/"

LOG_CACHE="$OUT_DIR/ab_cache_${STAMP}.log"
run_ab "cache HIT" "$BASE_URL/" "$LOG_CACHE"

if [[ "$COLD_TEST" -eq 1 ]]; then
    # URL unica por request para forzar MISS: mide el costo real de los backends
    COLD_URL="$BASE_URL/?nocache=${STAMP}"
    LOG_COLD="$OUT_DIR/ab_nocache_${STAMP}.log"
    run_ab "sin cache (MISS forzado)" "$COLD_URL" "$LOG_COLD"
fi

LOG_API="$OUT_DIR/ab_api_${STAMP}.log"
run_ab "API /api/orders (cache HIT)" "$BASE_URL/api/orders" "$LOG_API"

echo ""
echo "--------------------------------------------------------------------------"
print_result "GET / (cache HIT)" "$LOG_CACHE"
[[ "$COLD_TEST" -eq 1 ]] && print_result "GET /?nocache (MISS forzado)" "$LOG_COLD"
print_result "GET /api/orders (cache HIT)" "$LOG_API"

# Tasa de cache observada durante la ventana de la prueba
NGINX_CONTAINER="${NGINX_CONTAINER:-speedrunners-nginx}"
HITS=$(docker logs --tail 200 "$NGINX_CONTAINER" 2>/dev/null | grep -c 'cs=HIT')
MISSES=$(docker logs --tail 200 "$NGINX_CONTAINER" 2>/dev/null | grep -c 'cs=MISS')
TOTAL=$((HITS + MISSES))
if [[ "$TOTAL" -gt 0 ]]; then
    RATIO=$(awk -v h="$HITS" -v t="$TOTAL" 'BEGIN { printf "%.1f", h * 100.0 / t }')
    echo ""
    echo "  Cache observado en nginx (ultimos 200 requests): $HITS HIT / $MISSES MISS -> $RATIO % de aciertos"
fi

echo ""
echo "=========================================================================="
echo "  Prueba terminada: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Logs completos de ab en $OUT_DIR/"
echo "=========================================================================="
