FROM alpine:3.21 AS base

LABEL org.opencontainers.image.source="https://github.com/ry-ops/stackforge"
LABEL org.opencontainers.image.description="Guided homelab infrastructure bootstrapper"
LABEL org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache \
      curl \
      jq \
      openssl

RUN adduser -D -h /opt/stackforge stackforge

COPY stackforge.sh /usr/local/bin/stackforge
COPY manifests/ /opt/stackforge/manifests/
COPY dashboard/ /opt/stackforge/dashboard/

RUN chmod +x /usr/local/bin/stackforge && \
    chown -R stackforge:stackforge /opt/stackforge

WORKDIR /opt/stackforge
USER stackforge

ENTRYPOINT ["stackforge"]
