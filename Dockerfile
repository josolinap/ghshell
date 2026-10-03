FROM alpine:3.20 AS tailscale-builder
ARG TS_VERSION=1.86.2
RUN apk add --no-cache curl ca-certificates
WORKDIR /tmp
RUN curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_amd64.tgz" | \
    tar -xz --strip-components=1

# ---------- Runtime stage ----------
FROM alpine:3.20

# Core packages + openssh (shellinabox authenticates via SSH)
RUN apk add --no-cache \
        ca-certificates \
        tini \
        supervisor \
        python3 \
        shadow \
        openssh \
        curl \
        git \
        vim \
        nano \
        openssh-client \
        htop \
        bash \
        coreutils \
        findutils \
        grep \
        tar \
        gzip \
        unzip \
        wget

# Install shellinabox from Alpine edge/testing
RUN apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing \
        shellinabox

# Copy tailscale binaries from builder
COPY --from=tailscale-builder /tmp/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale-builder /tmp/tailscale   /usr/local/bin/tailscale

# Supervisor config
COPY supervisord.conf /etc/supervisor/conf.d/services.conf

# Entrypoint
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Set up root password (override at runtime with ROOT_PASSWORD env var)
ENV ROOT_PASSWORD=change-me
RUN echo "root:${ROOT_PASSWORD}" | chpasswd

# Generate SSH host keys + configure sshd
RUN ssh-keygen -A && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's|^root:x:0:0:root:/root:/bin/.*|root:x:0:0:root:/root:/bin/bash|' /etc/passwd && \
    echo "render-shell" > /etc/hostname && \
    # Suppress shellinabox SSH warnings: it hardcodes deprecated options
    # (RhostsRSAAuthentication, RSAAuthentication) that Alpine's OpenSSH 9.x
    # doesn't recognize. Rename real ssh, replace with wrapper that filters them.
    mv /usr/bin/ssh /usr/bin/ssh.real && \
    printf '#!/bin/sh\nexec /usr/bin/ssh.real "$@" 2> >(grep -v "Unsupported option" >&2)\n' > /usr/bin/ssh && \
    chmod +x /usr/bin/ssh

# Workspace + status page
RUN mkdir -p /var/run/tailscale /workspace /run/sshd

RUN printf '%s\n' \
  '<!DOCTYPE html>' \
  '<html><head><title>Render Shell</title>' \
  '<style>body{font-family:system-ui,sans-serif;max-width:700px;margin:50px auto;padding:0 20px;color:#333}' \
  '.card{background:#f5f5f5;padding:20px;border-radius:8px;margin:15px 0}' \
  'a{color:#1976d2;text-decoration:none;font-weight:500}' \
  'a:hover{text-decoration:underline}code{background:#e0e0e0;padding:2px 6px;border-radius:3px}</style></head>' \
  '<body><h1>Render Shell</h1>' \
  '<div class="card"><h3>Web Terminal (shellinabox)</h3>' \
  '<p>HTTPS via Tailscale Serve: <code>https://render-exit-node.curl-trench.ts.net/</code></p>' \
  '<p>Login: <code>root</code> / password from <code>ROOT_PASSWORD</code> env var</p></div>' \
  '<div class="card"><h3>Tailscale Exit Node</h3><p>Active and available for your tailnet.</p></div>' \
  '</body></html>' > /workspace/index.html

WORKDIR /workspace

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD tailscale status >/dev/null 2>&1 || exit 1

EXPOSE 8080 4200

ENTRYPOINT ["/sbin/tini", "--", "/docker-entrypoint.sh"]
