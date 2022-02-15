FROM ubuntu:18.04

RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends bash curl jq ca-certificates; \
    rm -rf /var/lib/apt/lists/*

ADD entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

