"""Backend de SpeedRunners Inc.

Servidor HTTP ligero basado solo en la libreria estandar de Python, con una
latencia artificial configurable por variable de entorno.

Endpoints:
    GET /            -> pagina HTML con informacion del contenedor y pedidos
    GET /api/orders  -> listado de pedidos en JSON
    GET /health      -> health check (sin latencia artificial)
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DELAY_MS = int(os.environ.get("ARTIFICIAL_DELAY_MS", "500"))
BACKEND_ID = os.environ.get("BACKEND_ID", os.environ.get("HOSTNAME", "backend"))
PORT = int(os.environ.get("PORT", "8000"))
CACHE_MAX_AGE = int(os.environ.get("CACHE_MAX_AGE", "30"))
ORDER_COUNT = int(os.environ.get("ORDER_COUNT", "40"))

CITIES = [
    "San Salvador", "Santa Ana", "San Miguel", "Soyapango", "Antiguo Cuscatlan",
    "Mejicanos", "Apopa", "Sonsonate", "Usulutan", "La Libertad",
]
PRODUCTS = [
    "Combo Familiar", "Pizza Suprema", "Sushi Box", "Hamburguesa Doble",
    "Pupusas x10", "Cafe Frio", "Burrito Express", "Ramen Picante",
    "Ensalada Cesar", "Postre del Dia",
]


def build_orders():
    orders = []
    for i in range(1, ORDER_COUNT + 1):
        orders.append({
            "order_id": f"SR-{i:04d}",
            "city": CITIES[i % len(CITIES)],
            "product": PRODUCTS[i % len(PRODUCTS)],
            "status": "en_camino",
            "eta_min": (i % 25) + 5,
            "total_usd": round(4.5 + (i % 17) * 1.35, 2),
        })
    return orders


ORDERS = build_orders()
STARTED_AT = time.time()


def render_html(served_ms):
    rows = "\n".join(
        f"<tr><td>{o['order_id']}</td><td>{o['city']}</td><td>{o['product']}</td>"
        f"<td>{o['status']}</td><td>{o['eta_min']} min</td><td>${o['total_usd']:.2f}</td></tr>"
        for o in ORDERS
    )
    return f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <title>SpeedRunners Inc. - Panel de Pedidos</title>
  <style>
    body {{ font-family: system-ui, sans-serif; margin: 2rem; background: #0f172a; color: #e2e8f0; }}
    h1 {{ color: #38bdf8; }}
    .badge {{ display: inline-block; padding: .35rem .7rem; border-radius: 999px;
              background: #1e293b; border: 1px solid #334155; margin-right: .5rem; }}
    table {{ border-collapse: collapse; width: 100%; margin-top: 1rem; font-size: .9rem; }}
    th, td {{ border-bottom: 1px solid #334155; padding: .5rem; text-align: left; }}
    th {{ background: #1e293b; }}
  </style>
</head>
<body>
  <h1>SpeedRunners Inc. - Panel de Pedidos</h1>
  <p>
    <span class="badge">Contenedor: <strong>{BACKEND_ID}</strong></span>
    <span class="badge">Latencia artificial: <strong>{DELAY_MS} ms</strong></span>
    <span class="badge">Respuesta generada en: <strong>{served_ms:.1f} ms</strong></span>
  </p>
  <p>Pedidos activos en la red de entregas ultra rapidas: {len(ORDERS)}</p>
  <table>
    <thead>
      <tr><th>Pedido</th><th>Ciudad</th><th>Producto</th><th>Estado</th><th>ETA</th><th>Total</th></tr>
    </thead>
    <tbody>
{rows}
    </tbody>
  </table>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SpeedRunnersBackend/1.0"
    sys_version = ""

    def _respond(self, body, content_type, status=200):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", f"public, max-age={CACHE_MAX_AGE}")
        self.send_header("X-Backend", BACKEND_ID)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def do_GET(self):
        started = time.perf_counter()
        path = self.path.split("?")[0]

        if path == "/health":
            self._respond(
                json.dumps({"status": "ok", "backend": BACKEND_ID, "uptime_s": round(time.time() - STARTED_AT, 1)}),
                "application/json",
            )
            return

        if path not in ("/", "/api/orders"):
            self._respond(json.dumps({"error": "not_found", "path": path}), "application/json", status=404)
            return

        time.sleep(DELAY_MS / 1000.0)
        served_ms = (time.perf_counter() - started) * 1000

        if path == "/api/orders":
            self._respond(
                json.dumps({
                    "backend": BACKEND_ID,
                    "served_ms": round(served_ms, 1),
                    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "total": len(ORDERS),
                    "orders": ORDERS,
                }, ensure_ascii=False),
                "application/json",
            )
        else:
            self._respond(render_html(served_ms), "text/html; charset=utf-8")

    def do_HEAD(self):
        self.do_GET()

    def log_message(self, fmt, *args):
        print(f"[{BACKEND_ID}] {self.address_string()} - {fmt % args}", flush=True)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print(f"[{BACKEND_ID}] escuchando en :{PORT} con delay artificial de {DELAY_MS} ms", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
