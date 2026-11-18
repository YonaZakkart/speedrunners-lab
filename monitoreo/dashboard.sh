#!/usr/bin/env bash
#
# Dashboard SRE de SpeedRunners Inc.
#
# Muestra en tiempo real:
#   - Latencia promedio de los ultimos 10 requests (y p95 de la ventana reciente)
#   - Tasa de aciertos de cache (HIT / MISS) desde la cabecera X-Cache-Status
#   - Uso de CPU y memoria de los contenedores
#   - Conexiones activas desde nginx stub_status
#
# Uso:
#   ./monitoreo/dashboard.sh              # una sola foto (ideal para capturas)
#   ./monitoreo/dashboard.sh --watch      # refresco continuo
#   ./monitoreo/dashboard.sh --html       # genera monitoreo/reporte.html
#   ./monitoreo/dashboard.sh --serve      # genera y sirve en http://localhost:8090
#
set -uo pipefail

# Los calculos usan punto decimal sin importar la configuracion regional
export LC_NUMERIC=C

BASE_URL="${BASE_URL:-http://localhost:8000}"
NGINX_CONTAINER="${NGINX_CONTAINER:-speedrunners-nginx}"
LOG_LINES="${LOG_LINES:-400}"
PROBE_SAMPLES="${PROBE_SAMPLES:-20}"
REFRESH="${REFRESH:-2}"
SLA_MS="${SLA_MS:-500}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_FILE="$PROJECT_DIR/monitoreo/reporte.html"

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'; C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_CYAN=""; C_GREEN=""
    C_YELLOW=""; C_RED=""; C_BLUE=""; C_MAGENTA=""
fi

# ---------------------------------------------------------------------------
# Recoleccion de datos
# ---------------------------------------------------------------------------
collect_logs() {
    docker logs --tail "$LOG_LINES" "$NGINX_CONTAINER" 2>/dev/null
}

# Latencia real de los ultimos requests, medida en vivo.
# El access_log de nginx tiene resolucion de milisegundos y los HIT quedan
# en rt=0.000, por eso esta metrica se mide con curl.
# Imprime: avg min max p95
probe_latency() {
    local samples
    samples="$(probe_samples)"
    printf '%s\n' "$samples" | awk '
        NF { v[NR] = $1; n++ }
        END {
            if (n == 0) { print "0 0 0 0"; exit }
            start = (n > 10) ? n - 9 : 1
            for (i = start; i <= n; i++) { s += v[i]; k++ }
            min = v[start]; max = v[start]
            for (i = start; i <= n; i++) {
                if (v[i] < min) min = v[i]
                if (v[i] > max) max = v[i]
            }
            for (i = 1; i <= n; i++) o[i] = v[i]
            for (i = 2; i <= n; i++) {
                key = o[i]; j = i - 1
                while (j > 0 && o[j] > key) { o[j+1] = o[j]; j-- }
                o[j+1] = key
            }
            idx = int(n * 0.95); if (idx < 1) idx = 1
            printf "%.1f %.1f %.1f %.1f\n", s / k, min, max, o[idx]
        }'
}

probe_samples() {
    for _ in $(seq "$PROBE_SAMPLES"); do
        curl -s -o /dev/null -w '%{time_total}\n' "$BASE_URL/" 2>/dev/null
    done | awk 'NF { printf "%.1f\n", $1*1000 }'
}

# Imprime: total sla_pct hits misses otros hit_ratio
collect_latency_cache() {
    local logs rts css hits misses otros stats sla_pct hit_ratio

    logs="$(collect_logs)"
    rts="$(printf '%s\n' "$logs" | grep -oE 'rt=[0-9.]+' | cut -d= -f2 | awk '{printf "%.1f\n", $1*1000}')"
    css="$(printf '%s\n' "$logs" | grep -oE 'cs=[A-Z_]+' | cut -d= -f2)"

    hits=$(printf '%s\n' "$css" | grep -c '^HIT$')
    misses=$(printf '%s\n' "$css" | grep -c '^MISS$')
    otros=$(printf '%s\n' "$css" | grep -v '^$' | grep -vcE '^(HIT|MISS)$')

    stats="$(printf '%s\n' "$rts" | awk -v sla="$SLA_MS" '
        NF { v[NR] = $1; total++; }
        END {
            if (total == 0) { print "0 0 0"; exit }
            ok = 0
            for (i = 1; i <= total; i++) if (v[i] <= sla) ok++
            printf "%d %.1f\n", total, (ok * 100.0 / total)
        }')"

    read -r total sla_pct <<< "$stats"
    hit_ratio=$(awk -v h="$hits" -v m="$misses" -v o="$otros" \
        'BEGIN { t = h + m + o; printf "%.1f", (t > 0) ? h * 100.0 / t : 0 }')

    echo "$total $sla_pct $hits $misses $otros $hit_ratio"
}

# Imprime: active reading writing waiting accepted handled requests
collect_stub_status() {
    curl -s --max-time 2 "$BASE_URL/nginx_status" | awk '
        /Active connections/ { active = $3 }
        /^Reading/ { reading = $2; writing = $4; waiting = $6 }
        NF == 3 && $1 ~ /^[0-9]+$/ { accepted = $1; handled = $2; requests = $3 }
        END { printf "%d %d %d %d %d %d %d\n", active, reading, writing, waiting, accepted, handled, requests }'
}

collect_resources() {
    docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null \
        | grep '^speedrunners-' \
        | awk -F'|' '{ printf "%s|%s|%s|%s\n", $1, $2, $3, $4 }'
}

# ---------------------------------------------------------------------------
# Salida en terminal
# ---------------------------------------------------------------------------
render_terminal() {
    local lat_line req_total sla hits misses otros hit_ratio
    local avg lat_min lat_max lat_p95
    local active reading writing waiting accepted handled requests
    local stamp

    lat_line="$(collect_latency_cache)"
    read -r req_total sla hits misses otros hit_ratio <<< "$lat_line"
    read -r avg lat_min lat_max lat_p95 <<< "$(probe_latency)"
    read -r active reading writing waiting accepted handled requests <<< "$(collect_stub_status)"
    stamp="$(date '+%Y-%m-%d %H:%M:%S')"

    local sla_color="$C_GREEN"
    (( $(printf '%.0f' "$sla") < 99 )) && sla_color="$C_YELLOW"
    (( $(printf '%.0f' "$sla") < 90 )) && sla_color="$C_RED"

    local lat_color="$C_GREEN"
    (( $(printf '%.0f' "$avg") > 100 )) && lat_color="$C_YELLOW"
    (( $(printf '%.0f' "$avg") > 400 )) && lat_color="$C_RED"

    echo ""
    echo "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"
    echo "${C_CYAN}${C_BOLD}  SPEEDRUNNERS INC. - DASHBOARD SRE${C_RESET}${C_DIM}                    $stamp${C_RESET}"
    echo "${C_CYAN}${C_BOLD}==========================================================================${C_RESET}"
    echo ""
    echo "  ${C_BOLD}LATENCIA${C_RESET} ${C_DIM}(SLA < ${SLA_MS} ms)${C_RESET}"
    echo "    Promedio ultimos 10 .... ${lat_color}${C_BOLD}$(printf '%6.1f' "$avg") ms${C_RESET}   ${C_DIM}(min $(printf '%.1f' "$lat_min") / max $(printf '%.1f' "$lat_max") ms)${C_RESET}"
    echo "    p95 ultimas 20 ......... $(printf '%6.1f' "$lat_p95") ms   ${C_DIM}(medidas en vivo)${C_RESET}"
    echo "    Cumplimiento SLA ....... ${sla_color}${C_BOLD}$(printf '%5.1f' "$sla") %${C_RESET}   ${C_DIM}($req_total requests del log)${C_RESET}"
    echo ""
    echo "  ${C_BOLD}CACHE${C_RESET} ${C_DIM}(cabecera X-Cache-Status)${C_RESET}"
    echo "    HIT .................... ${C_GREEN}${C_BOLD}$(printf '%5.1f' "$hit_ratio") %${C_RESET}   ${C_DIM}($hits HIT / $misses MISS / $otros otros)${C_RESET}"
    echo ""
    echo "  ${C_BOLD}CONEXIONES${C_RESET} ${C_DIM}(nginx stub_status)${C_RESET}"
    echo "    Activas $active   ${C_DIM}|${C_RESET}   Reading $reading   Writing $writing   Waiting $waiting"
    echo "    Aceptadas $accepted   Handled $handled   Requests $requests"
    echo ""
    echo "  ${C_BOLD}RECURSOS${C_RESET} ${C_DIM}(docker stats)${C_RESET}"
    printf "    ${C_DIM}%-26s %9s  %-22s %7s${C_RESET}\n" "CONTENEDOR" "CPU" "MEMORIA" "MEM"
    while IFS='|' read -r name cpu mem memp; do
        [[ -z "$name" ]] && continue
        printf "    %-26s ${C_BLUE}%9s${C_RESET}  %-22s %7s\n" "$name" "$cpu" "$mem" "$memp"
    done < <(collect_resources)
    echo ""
    echo "${C_CYAN}==========================================================================${C_RESET}"
    echo "${C_DIM}  Refresco: ${REFRESH}s | Log: docker logs $NGINX_CONTAINER | Ctrl+C para salir${C_RESET}"
}

# ---------------------------------------------------------------------------
# Salida HTML
# ---------------------------------------------------------------------------
render_html() {
    local lat_line req_total sla hits misses otros hit_ratio
    local avg lat_min lat_max lat_p95
    local active reading writing waiting accepted handled requests
    local stamp rows spark max spark_html

    lat_line="$(collect_latency_cache)"
    read -r req_total sla hits misses otros hit_ratio <<< "$lat_line"
    read -r avg lat_min lat_max lat_p95 <<< "$(probe_latency)"
    read -r active reading writing waiting accepted handled requests <<< "$(collect_stub_status)"
    stamp="$(date '+%Y-%m-%d %H:%M:%S')"

    rows=""
    while IFS='|' read -r name cpu mem memp; do
        [[ -z "$name" ]] && continue
        rows+="<tr><td>${name}</td><td>${cpu}</td><td>${mem}</td><td>${memp}</td></tr>"
    done < <(collect_resources)

    spark="$(probe_samples)"
    max="$(printf '%s\n' "$spark" | sort -n | tail -1)"
    [[ -z "$max" || "$max" == "0.0" ]] && max=1
    spark_html=""
    while read -r v; do
        [[ -z "$v" ]] && continue
        h="$(awk -v v="$v" -v m="$max" 'BEGIN { h = (v/m)*100; if (h < 2) h = 2; printf "%.0f", h }')"
        cls="bar"
        awk -v v="$v" 'BEGIN { exit !(v > 500) }' && cls="bar bad"
        awk -v v="$v" 'BEGIN { exit !(v > 100 && v <= 500) }' && cls="bar warn"
        spark_html+="<div class=\"${cls}\" style=\"height:${h}%\" title=\"${v} ms\"></div>"
    done <<< "$spark"

    local sla_class="ok"
    awk -v s="$sla" 'BEGIN { exit !(s < 99) }' && sla_class="warn"
    awk -v s="$sla" 'BEGIN { exit !(s < 90) }' && sla_class="bad"

    cat > "$REPORT_FILE" <<HTML
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="${REFRESH}">
<title>SpeedRunners Inc. - Dashboard SRE</title>
<style>
  :root { --bg:#0b1220; --panel:#131c2e; --line:#22304a; --txt:#e6edf7; --dim:#8ba0bf;
          --cyan:#38bdf8; --green:#34d399; --warn:#fbbf24; --bad:#f87171; }
  * { box-sizing: border-box; }
  body { margin:0; padding:28px; background:var(--bg); color:var(--txt);
         font-family: ui-sans-serif, system-ui, "Segoe UI", Roboto, sans-serif; }
  header { display:flex; justify-content:space-between; align-items:baseline;
           border-bottom:1px solid var(--line); padding-bottom:14px; margin-bottom:22px; }
  h1 { font-size:1.35rem; margin:0; letter-spacing:.4px; }
  h1 span { color:var(--cyan); }
  .stamp { color:var(--dim); font-size:.85rem; font-variant-numeric: tabular-nums; }
  .grid { display:grid; grid-template-columns: repeat(4, 1fr); gap:16px; margin-bottom:22px; }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:18px; }
  .card .label { color:var(--dim); font-size:.78rem; text-transform:uppercase; letter-spacing:.8px; }
  .card .value { font-size:2.1rem; font-weight:700; margin-top:8px; font-variant-numeric: tabular-nums; }
  .card .sub { color:var(--dim); font-size:.8rem; margin-top:6px; }
  .ok { color:var(--green); } .warn { color:var(--warn); } .bad { color:var(--bad); }
  .cyan { color:var(--cyan); }
  section { background:var(--panel); border:1px solid var(--line); border-radius:12px;
            padding:18px; margin-bottom:18px; }
  section h2 { font-size:.95rem; margin:0 0 14px; color:var(--dim);
               text-transform:uppercase; letter-spacing:.8px; font-weight:600; }
  table { width:100%; border-collapse:collapse; font-size:.9rem; }
  th, td { text-align:left; padding:9px 10px; border-bottom:1px solid var(--line); }
  th { color:var(--dim); font-weight:600; font-size:.78rem; text-transform:uppercase; }
  tr:last-child td { border-bottom:none; }
  .spark { display:flex; align-items:flex-end; gap:3px; height:90px; margin-top:6px; }
  .bar { flex:1; background:var(--green); border-radius:2px 2px 0 0; opacity:.85; }
  .bar.warn { background:var(--warn); } .bar.bad { background:var(--bad); }
  .legend { display:flex; gap:18px; color:var(--dim); font-size:.75rem; margin-top:8px; }
  .dot { display:inline-block; width:8px; height:8px; border-radius:50%; margin-right:5px; }
  footer { color:var(--dim); font-size:.75rem; text-align:center; margin-top:8px; }
</style>
</head>
<body>
<header>
  <h1>SpeedRunners Inc. <span>/ Dashboard SRE</span></h1>
  <div class="stamp">Actualizado: ${stamp}</div>
</header>

<div class="grid">
  <div class="card">
    <div class="label">Latencia promedio (ult. 10)</div>
    <div class="value cyan">${avg} <small>ms</small></div>
    <div class="sub">min ${lat_min} / max ${lat_max} ms &middot; SLA &lt; ${SLA_MS} ms</div>
  </div>
  <div class="card">
    <div class="label">Cache hit ratio</div>
    <div class="value ok">${hit_ratio}%</div>
    <div class="sub">${hits} HIT / ${misses} MISS</div>
  </div>
  <div class="card">
    <div class="label">Cumplimiento SLA</div>
    <div class="value ${sla_class}">${sla}%</div>
    <div class="sub">p95 ${lat_p95} ms en ${req_total} requests</div>
  </div>
  <div class="card">
    <div class="label">Conexiones activas</div>
    <div class="value">${active}</div>
    <div class="sub">Reading ${reading} / Writing ${writing} / Waiting ${waiting}</div>
  </div>
</div>

<section>
  <h2>Latencia de los ultimos ${PROBE_SAMPLES} requests (medidos en vivo)</h2>
  <div class="spark">${spark_html}</div>
  <div class="legend">
    <span><i class="dot" style="background:var(--green)"></i>&lt; 100 ms</span>
    <span><i class="dot" style="background:var(--warn)"></i>100 - 500 ms</span>
    <span><i class="dot" style="background:var(--bad)"></i>&gt; 500 ms</span>
  </div>
</section>

<section>
  <h2>Recursos por contenedor</h2>
  <table>
    <thead><tr><th>Contenedor</th><th>CPU</th><th>Memoria</th><th>Mem %</th></tr></thead>
    <tbody>
      ${rows}
    </tbody>
  </table>
</section>

<section>
  <h2>Nginx stub_status</h2>
  <table>
    <thead><tr><th>Aceptadas</th><th>Handled</th><th>Requests</th><th>Reading</th><th>Writing</th><th>Waiting</th></tr></thead>
    <tbody><tr><td>${accepted}</td><td>${handled}</td><td>${requests}</td><td>${reading}</td><td>${writing}</td><td>${waiting}</td></tr></tbody>
  </table>
</section>

<footer>Generado por monitoreo/dashboard.sh &middot; refresco automatico cada ${REFRESH}s</footer>
</body>
</html>
HTML
    echo "Reporte generado en $REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
    --html)
        render_html
        ;;
    --serve)
        render_html >/dev/null
        echo "Dashboard disponible en http://localhost:8090/reporte.html"
        ( cd "$PROJECT_DIR/monitoreo" && python3 -m http.server 8090 >/dev/null 2>&1 ) &
        SERVER_PID=$!
        trap 'kill $SERVER_PID 2>/dev/null' EXIT
        while true; do
            render_html >/dev/null
            sleep "$REFRESH"
        done
        ;;
    --watch|-w)
        while true; do
            clear
            render_terminal
            sleep "$REFRESH"
        done
        ;;
    *)
        render_terminal
        echo ""
        echo "  ${C_DIM}Genera la version web con: ./monitoreo/dashboard.sh --html${C_RESET}"
        echo "  ${C_DIM}Abre monitoreo/reporte.html en el navegador (se refresca solo).${C_RESET}"
        ;;
esac
