# Centinela — gateway-service

Gateway central (nginx) que enruta `/api`, `/ws` y `/media` a los backends de la plataforma sobre la red Docker `centinela-net`, y sirve el hub centralizado de documentación Swagger de todos los servicios (`/api/docs/v1/`). No tiene código de aplicación propio — es configuración de nginx + assets estáticos.

Parte del org multi-repo `PlataformaIntegradaInvestigadores`. Es el punto de entrada único desde `centinela-front` (que proxea `/api/`, `/ws/` y `/media/` hacia acá) hacia todos los backends.

## Stack

- nginx 1.27 (imagen `nginx:1.27-alpine`)
- Assets de Swagger UI (`swaggerapi/swagger-ui:latest`), horneados en la imagen vía build multi-stage — sin dependencia de CDN

## Estructura del proyecto

```
Dockerfile                      # multi-stage: trae assets de swagger-ui + imagen nginx final
docker-compose.yml              # despliegue en desarrollo/staging
docker-compose_produccion.yaml  # despliegue en producción
nginx.conf                      # configuración de rutas, upstreams y hub de docs
docs/
  index.html                    # índice del hub (lista los 6 servicios)
  swagger.html                  # shell de Swagger UI reutilizado por los 6 servicios
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

## Documentación (Swagger)

`http://<host>/api/docs/v1/` — hub público (sin auth) con el Swagger UI de los 6 backends con API REST/HTTP:

| Ruta | Servicio |
|---|---|
| `/api/docs/v1/identity` | identity-service |
| `/api/docs/v1/social` | social-service |
| `/api/docs/v1/search` | search-service |
| `/api/docs/v1/search-bff` | search-bff-service |
| `/api/docs/v1/predictive` | predictive-service |
| `/api/docs/v1/rag` | rag-service |

Cada página es el mismo `docs/swagger.html`, que pide el spec a `<ruta>/openapi.json` (proxeado directo al upstream real, sin pasar por el rewrite de `/api/<servicio>/`). Cada backend declara su `servers` público para que "Try it out" pegue a la ruta del gateway, no a su ruta interna — ver README de cada servicio.

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
