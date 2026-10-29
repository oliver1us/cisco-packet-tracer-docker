#!/bin/sh
# Caddy reverse proxy for noVNC; bcrypt hash at startup so the password never hits disk
set -eu

HTTP_USER="${HTTP_USER:-admin}"
HTTP_PASSWORD="${HTTP_PASSWORD:-}"
LISTEN_PORT="${LISTEN_PORT:-8080}"
UPSTREAM="${UPSTREAM:-packet-tracer:6080}"

CADDYFILE=/tmp/Caddyfile

if [ -z "$HTTP_PASSWORD" ]; then
    echo "[proxy] WARNING: HTTP_PASSWORD is empty -> noVNC is left WITHOUT authentication."
    cat > "$CADDYFILE" <<EOF
:${LISTEN_PORT} {
    reverse_proxy ${UPSTREAM}
}
EOF
else
    HASH=$(caddy hash-password --plaintext "$HTTP_PASSWORD")
    cat > "$CADDYFILE" <<EOF
:${LISTEN_PORT} {
    basic_auth {
        ${HTTP_USER} ${HASH}
    }
    reverse_proxy ${UPSTREAM}
}
EOF
    echo "[proxy] Basic Auth enabled for '${HTTP_USER}' on :${LISTEN_PORT}"
fi

exec caddy run --config "$CADDYFILE" --adapter caddyfile
