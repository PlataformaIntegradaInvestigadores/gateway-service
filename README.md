# Centinela — gateway-service

Gateway central (nginx) que enruta `/api`, `/ws` y `/media` a los backends de la plataforma sobre la red Docker `centinela-net`. No tiene código de aplicación propio — es configuración de nginx.

Parte del org multi-repo `PlataformaIntegradaInvestigadores`. Es el punto de entrada único desde `centinela-front` (que proxea `/api/`, `/ws/` y `/media/` hacia acá) hacia todos los backends.

## Stack

- nginx 1.27 (imagen `nginx:1.27-alpine`)

## Estructura del proyecto

```
Dockerfile
docker-compose.yml              # despliegue en desarrollo/staging
docker-compose_produccion.yaml  # despliegue en producción
nginx.conf                      # configuración de rutas y upstreams
```

## Requisitos previos

- Docker + Docker Compose

## Levantar en local

```bash
docker compose up -d --build
```

Healthcheck: `curl -f http://localhost:8080/health`

## Rutas (ver `nginx.conf`)

Esquema `/api/<servicio>/`:

| Ruta | Upstream |
|---|---|
| `/api/identity/` | `identity-service:8002` |
| `/api/social/` | `social-service:8000` |
| `/api/search/` | `search-service:8001` |
| `/api/search/v2/` | `search-bff-service:8002` |
| `/api/predictive/` | `predictive-service:8003` |
| `/api/rag/` | `rag-service:8181` |
| `/ws/` | `social-service:8000` (WebSocket) |
| `/media/` | `social-service:8000` / `identity-service:8002` |

## Variables de entorno

Este repo no usa `.env` — la configuración de rutas vive directo en `nginx.conf`.

## Tests

No hay tests de aplicación (repo config-only). CI valida sintaxis de `nginx.conf` y `docker-compose.yml`:

```bash
docker run --rm -v "$PWD/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:1.27-alpine nginx -t
docker compose config -q
```

## CI/CD

GitHub Actions (`.github/workflows/ci.yml`): validación de config (`nginx -t` + `docker compose config`) → deploy automático a staging (`develop` branch, runner self-hosted `ticcd`) con healthcheck y rollback automático.

## Convenciones

- Branches: `feature/*` → `develop`, `hotfix/*` → `main`.
- Commits: [Conventional Commits](https://www.conventionalcommits.org/), inglés, con el *por qué* en el cuerpo.

## Notas

- Auth vía `auth_request /_auth_identity` → identity `/internal/auth/validate-token/`.
- Usa `resolver 127.0.0.11` (DNS de Docker) → tolera orden de arranque de los backends.
