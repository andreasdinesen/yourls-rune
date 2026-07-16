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

# Create YOURLS tables + admin on first run (the script self-guards if already
# installed). Runs as root — it only touches the database, no files — and is
# non-fatal so a fresh boot against an existing DB is fine.
log "Kontrollerer YOURLS-installation ..."
( cd /var/www/html && php /usr/local/lib/yourls-install.php ) \
    || log "install-script gav en fejl (fortsætter)"

log "Starter Apache ..."
exec apache2-foreground
