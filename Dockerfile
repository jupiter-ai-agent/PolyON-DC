FROM debian:bookworm-slim

LABEL maintainer="Triangle.s <cmars@triangles.co.kr>"
LABEL description="PolyON DC — Samba AD Domain Controller"

ENV DEBIAN_FRONTEND=noninteractive
ENV REALM=POLYON.DEV
ENV DOMAIN=POLYON
ENV ADMIN_PASSWORD=ChangeMe123!

RUN apt-get update && apt-get install -y --no-install-recommends \
    samba \
    samba-ad-provision \
    ldb-tools \
    krb5-user \
    samba-dsdb-modules \
    samba-vfs-modules \
    winbind \
    libnss-winbind \
    libpam-winbind \
    tini \
    python3 \
    curl \
    dnsutils \
  && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD /healthcheck.sh

EXPOSE 53/tcp 53/udp 88/tcp 88/udp 135/tcp 137/udp 138/udp 139/tcp 389/tcp 389/udp \
    445/tcp 464/tcp 464/udp 636/tcp 3268/tcp 3269/tcp

VOLUME ["/var/lib/samba", "/shared"]

ENTRYPOINT ["tini", "--"]
CMD ["/entrypoint.sh"]
