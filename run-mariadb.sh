#!/usr/bin/env bash
# MariaDB launcher (supervisord program). Data lives on the persisted volume;
# only loopback TCP is exposed, for the local PHP/YOURLS process.
set -Eeuo pipefail

exec mariadbd \
    --user=mysql \
    --datadir=/data/mysql \
    --bind-address=127.0.0.1 \
    --port=3306 \
    --socket=/run/mysqld/mysqld.sock \
    --skip-name-resolve \
    --pid-file=/run/mysqld/mysqld.pid
