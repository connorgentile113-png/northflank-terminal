# syntax=docker/dockerfile:1
###############################################################################
#  Free Educational Coding Machine
#  -------------------------------
#  One container that serves a browser-accessible Linux terminal:
#
#    browser  ->  ngrok (https)  ->  nginx :8080  ->  ttyd :7681   (terminal)
#                                                 ->  127.0.0.1:<port> (previews)
#                                                 ->  /var/www/index.html (UI)
#
#  The browser only ever talks to the ngrok URL. Build-time downloads
#  (apt, NodeSource, ttyd, ngrok) are not browser fetches and are allowed.
###############################################################################
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
# ttyd >= 1.7.0 is required: that release introduced --base-path, which is what
# lets ttyd live behind nginx at /terminal/ instead of at the site root.
ARG TTYD_VERSION=1.7.7
ARG NODE_MAJOR=20

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    TERM=xterm-256color \
    HOME=/root \
    NGINX_PORT=8080 \
    TTYD_PORT=7681 \
    TTYD_BASE_PATH=/terminal \
    NGROK_API=http://127.0.0.1:4040/api/tunnels \
    FIREBASE_DATABASE_URL=https://vps-server-2bcbd-default-rtdb.firebaseio.com \
    FIREBASE_TUNNEL_PATH=/tunnel/url.json \
    TUNNEL_POLL_INTERVAL=20 \
    TUNNEL_REFRESH_INTERVAL=600 \
    PORT_LIST="3000 4200 5173 8000 8080 8888" \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# -----------------------------------------------------------------------------
# OS packages
#   nginx      - the single HTTP surface the tunnel points at
#   supervisor - keeps nginx/ttyd/ngrok/writer alive without crash loops
#   ttyd deps  - none (static binary below)
#   tooling    - what the terminal is *for*: nano, vim, htop, git, node, python
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl wget git gnupg unzip xz-utils tar \
        nano vim htop tmux less procps psmisc lsof iproute2 netcat-openbsd dnsutils \
        jq ripgrep fzf tree sudo \
        python3 python3-pip python3-venv python3-dev \
        openssh-client locales \
        nginx supervisor apache2-utils; \
    locale-gen en_US.UTF-8; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Node.js LTS (node / npm / npx -> dev servers and AI coding CLIs)
# -----------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource.sh; \
    bash /tmp/nodesource.sh; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/* /tmp/nodesource.sh; \
    node --version; \
    npm --version

# -----------------------------------------------------------------------------
# ttyd (static binary; apt on 22.04 only has 1.6.3, which lacks --base-path)
# -----------------------------------------------------------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) ttyd_asset=ttyd.x86_64 ;; \
        arm64) ttyd_asset=ttyd.aarch64 ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_asset}"; \
    chmod 0755 /usr/local/bin/ttyd; \
    ttyd --version

# -----------------------------------------------------------------------------
# ngrok agent (build-time fetch from the ngrok CDN — never a browser fetch)
# -----------------------------------------------------------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) ngrok_arch=amd64 ;; \
        arm64) ngrok_arch=arm64 ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/ngrok.tgz \
        "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${ngrok_arch}.tgz"; \
    tar -xzf /tmp/ngrok.tgz -C /usr/local/bin; \
    rm -f /tmp/ngrok.tgz; \
    chmod 0755 /usr/local/bin/ngrok; \
    ngrok --version

# -----------------------------------------------------------------------------
# Application files
# -----------------------------------------------------------------------------
COPY index.html           /var/www/index.html
COPY nginx.conf           /etc/nginx/nginx.conf
COPY supervisord.conf     /etc/supervisor/supervisord.conf
COPY entrypoint.sh        /usr/local/bin/entrypoint.sh
COPY tunnel-url-writer.sh /usr/local/bin/tunnel-url-writer.sh

RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/tunnel-url-writer.sh; \
    mkdir -p /etc/nginx/snippets /var/log/nginx /var/lib/nginx /var/www /run; \
    : > /etc/nginx/snippets/optional-auth.conf; \
    rm -rf /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/nginx/sites-available; \
    rm -f /etc/supervisor/conf.d/*.conf; \
    nginx -t -c /etc/nginx/nginx.conf

# Terminal conveniences (the welcome banner is rendered by entrypoint.sh).
RUN set -eux; \
    printf '%s\n' \
        'set bell-style none' \
        'set completion-ignore-case on' \
        >> /etc/inputrc; \
    printf '%s\n' \
        'unset HISTFILE' \
        'export EDITOR=vim' \
        'export PAGER=less' \
        'export LESS="-R"' \
        'alias ll="ls -alF"' \
        >> /root/.bashrc

# -----------------------------------------------------------------------------
# The only port Northflank has to expose. ngrok turns it into a public URL.
# -----------------------------------------------------------------------------
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=5 \
    CMD curl -fsS http://127.0.0.1:"${NGINX_PORT}"/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
