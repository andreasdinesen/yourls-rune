# All-in-one YOURLS image for yggdrasil: YOURLS + MariaDB + supervisor in one
# container, so no separate database rune is needed. Built on the official YOURLS
# image; bumping YOURLS_VERSION is the only change needed to ship a new version.
ARG YOURLS_VERSION=1.10.4
FROM yourls:${YOURLS_VERSION}-apache

# Re-declare after FROM so the value is available in the following layers.
ARG YOURLS_VERSION=1.10.4
# The core version baked into this image (used by the AUTO_UPDATE comparison).
ENV YOURLS_RUNE_VERSION=${YOURLS_VERSION}

# Bundle the database engine and a process supervisor.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        mariadb-server \
        mariadb-client \
        supervisor \
        ca-certificates \
        curl \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    # DB data lives on the persisted volume (/data/mysql), never in the image.
    rm -rf /var/lib/mysql; \
    mkdir -p /run/mysqld; \
    chown -R mysql:mysql /run/mysqld

# Our env-driven config template (adds YOURLS_SITE auto-detect, no-hash password,
# and a persistent config-extra.php include). Replaces the stock template.
COPY config-container.php /usr/src/yourls/user/config-container.php

# One-shot table installer, invoked when the database has no YOURLS tables yet.
COPY yourls-install.php /usr/local/lib/yourls-install.php

# Process supervision + the per-process launchers.
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY rune-entrypoint.sh start-apache.sh run-mariadb.sh db-dump.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/rune-entrypoint.sh \
             /usr/local/bin/start-apache.sh \
             /usr/local/bin/run-mariadb.sh \
             /usr/local/bin/db-dump.sh

# The official YOURLS image serves on 8080.
EXPOSE 8080/tcp

ENTRYPOINT ["rune-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
