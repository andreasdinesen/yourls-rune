#!/usr/bin/env bash
# Apache launcher (supervisord program). Waits for MariaDB, provisions the
# database + app user, installs YOURLS tables once, then serves.
set -Eeuo pipefail

DATA=/data
SOCK=/run/mysqld/mysqld.sock
DB_PASSWORD="$(cat "$DATA/secrets/db-password")"

log() { echo "[rune] $*" >&2; }

log "Venter på MariaDB ..."
i=0
until mariadb --protocol=socket -S "$SOCK" -uroot -e 'SELECT 1' >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 90 ]; then
        log "MariaDB startede ikke i tide"; exit 1
    fi
    sleep 1
done

# Provision database + application user (idempotent). YOURLS connects over TCP
# 127.0.0.1, so the grant is scoped to that host.
log "Sikrer database og bruger ..."
mariadb --protocol=socket -S "$SOCK" -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`yourls\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'yourls'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'yourls'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`yourls\`.* TO 'yourls'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# Trigger YOURLS' own web installer once Apache is serving. Running it over HTTP
# uses YOURLS' full, correct init (unlike a trimmed CLI bootstrap), needs no
# nonce (install.php reads $_REQUEST['install']), and is idempotent — on a boot
# against an existing DB it just reports "already installed". Backgrounded so we
# can exec Apache in the foreground for supervisord; the child survives the exec.
(
    # install.php is an admin page, so with an https YOURLS_SITE YOURLS would
    # redirect this local http request to https (and never install). Claim the
    # forwarded scheme so it treats us as already-secure and answers 200.
    hdr='X-Forwarded-Proto: https'
    for _ in $(seq 1 90); do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' -H "$hdr" \
                http://127.0.0.1:8080/admin/install.php || true)" = "200" ]; then
            resp="$(curl -s -H "$hdr" 'http://127.0.0.1:8080/admin/install.php?install=1' || true)"
            if printf '%s' "$resp" | grep -qiE 'successfully created|already installed'; then
                log "YOURLS-installation: OK"
            else
                log "YOURLS-installation: uventet svar (tjek /admin/install.php)"
            fi
            break
        fi
        sleep 1
    done
) &

log "Starter Apache ..."
exec apache2-foreground
