# SpeedRunners Inc. — La Carrera contra el Reloj

Laboratorio de SRE: una plataforma web que colapsa bajo carga y hay que dejar por debajo de
500 ms con menos del 1 % de errores. El repositorio contiene la infraestructura completa
(Nginx + backends en Python + cAdvisor), el dashboard de monitoreo, las pruebas de estrés y los
resultados obtenidos.

**Documentación completa: [INFORME.md](./INFORME.md)** — diagnóstico, optimizaciones, tablas
comparativas, capturas y respuestas a las preguntas de reflexión.

## Qué se hizo

| Fase | Resultado |
|---|---|
| Diagnóstico | Línea base medida: 147.5 req/s, 677.9 ms de media, p99 2584 ms, 99.9 % fuera de SLA |
| Caché | `proxy_cache` de 30 s con `X-Cache-Status`: 504 ms → 1.6 ms por petición repetida |
| Compresión | gzip en HTML/JSON/CSS/JS: -78.5 % en `/` y -86.2 % en `/api/orders` |
| Backends | Delay de 500 → 50 ms y de 2 a 4 instancias con healthcheck |
| Balanceo | `least_conn` + `max_fails`/`fail_timeout` + keepalive hacia los backends |
| Monitoreo | `stub_status`, cAdvisor en `:8080` y dashboard en terminal/HTML |
| Estrés | 100 concurrentes: **3209.7 req/s, 31.2 ms de media, p99 35 ms, 0 fallos** |

## Stack

- **Nginx** 1.27 (proxy, caché, gzip, balanceo)
- **Python 3.12** (backends con latencia artificial configurable)
- **cAdvisor** 0.55 (métricas de contenedores, compatible con cgroups v2)
- **Docker Compose** y **ApacheBench** para las pruebas de carga

## Cómo levantarlo

```bash
docker compose up -d --build

curl -sI http://localhost:8000/                    # X-Cache-Status y gzip
./monitoreo/dashboard.sh                           # dashboard en terminal
./monitoreo/dashboard.sh --html                    # dashboard web
./pruebas/stress-test.sh                           # ab -n 1000 -c 100
```

La plataforma se publica en **`http://localhost:8000`** (el puerto 80 del host está ocupado por
otro Nginx) y cAdvisor en **`http://localhost:8080/containers/`**.

## Estructura

```
├── docker-compose.yml      Nginx, 4 backends y cAdvisor
├── nginx/nginx.conf        Caché, gzip, least_conn, stub_status
├── backends/               API en Python stdlib + Dockerfile
├── monitoreo/              dashboard.sh y reporte.html
├── pruebas/                stress-test.sh y resultados de las corridas
├── public/screenshots/     Capturas del antes y el después
└── INFORME.md              Documentación completa del laboratorio
```
