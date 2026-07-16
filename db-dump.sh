#!/usr/bin/env bash
# Periodic logical backup (supervisord program). yggdrasil archives /data, but
# raw MariaDB files copied while running can be inconsistent, so keep a fresh
# mysqldump on the volume for portable, consistent restores.
set -Eeuo pipefail

DATA=/data
SOCK=/run/mysqld/mysqld.sock
INTERVAL="${DB_DUMP_INTERVAL:-21600}" # 6 hours

# Give the stack time to come up before the first dump.
sleep 120

while true; do
    if mariadb --protocol=socket -S "$SOCK" -uroot -e 'SELECT 1' >/dev/null 2>&1; then
        if mariadb-dump --protocol=socket -S "$SOCK" -uroot \
            --single-transaction --databases yourls \
            > "$DATA/db-dump/yourls.sql.part" 2>/dev/null; then
            mv "$DATA/db-dump/yourls.sql.part" "$DATA/db-dump/yourls.sql"
        else
            rm -f "$DATA/db-dump/yourls.sql.part"
        fi
    fi
    sleep "$INTERVAL"
done
