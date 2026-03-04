FROM alpine:3.20 AS base

LABEL org.opencontainers.image.source="https://github.com/ry-ops/stackforge"
LABEL org.opencontainers.image.description="Guided homelab infrastructure bootstrapper"
LABEL org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache \
      bash \
      curl \
      wget \
      jq \
      openssl

COPY stackforge.sh /usr/local/bin/stackforge
COPY manifests/ /opt/stackforge/manifests/
COPY dashboard/ /opt/stackforge/dashboard/

RUN chmod +x /usr/local/bin/stackforge

WORKDIR /opt/stackforge

ENTRYPOINT ["stackforge"]
