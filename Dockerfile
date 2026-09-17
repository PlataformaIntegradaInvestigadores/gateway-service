FROM swaggerapi/swagger-ui:latest AS swagger

FROM nginx:1.27-alpine

RUN apk add --no-cache nginx-mod-http-js

COPY nginx.conf /etc/nginx/nginx.conf
COPY health_aggregate.js /etc/nginx/health_aggregate.js
COPY docs/ /usr/share/nginx/docs/
COPY --from=swagger /usr/share/nginx/html/swagger-ui-bundle.js \
                     /usr/share/nginx/html/swagger-ui-standalone-preset.js \
                     /usr/share/nginx/html/swagger-ui.css \
                     /usr/share/nginx/html/favicon-32x32.png \
                     /usr/share/nginx/docs/assets/
