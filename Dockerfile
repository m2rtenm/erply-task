FROM dunglas/frankenphp:1-php8.3-alpine

# Single process (Caddy + embedded PHP), no supervisor needed.
COPY docker/Caddyfile /etc/caddy/Caddyfile
COPY docker/zz-prod.ini $PHP_INI_DIR/conf.d/zz-prod.ini
COPY app/ /app/public/

# Run as non-root: unprivileged port, no file caps, writable Caddy dirs only.
RUN apk add --no-cache libcap \
 && setcap -r /usr/local/bin/frankenphp || true \
 && apk del libcap \
 && adduser -D -u 10001 app \
 && mkdir -p /data/caddy /config/caddy \
 && chown -R app:app /data /config

ENV XDG_DATA_HOME=/data XDG_CONFIG_HOME=/config
USER 10001
WORKDIR /app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
