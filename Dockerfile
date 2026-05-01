# Use debian:trixie-slim as the base image
FROM debian:trixie-slim

# Install tini init system
RUN apt-get update && apt-get install -y \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV container=docker
ENV TINI_SUBREAPER=true

# Set hostname to "aihost"
RUN echo "aihost" > /etc/hostname

# Remove motd
RUN rm -v /etc/motd

# Install essential apt packages + network tools + nginx + openssl
RUN apt-get update && apt-get install -y \
    vim \
    htop \
    git \
    openssh-server \
    locales \
    sudo \
    curl \
    wget \
    systemd \
    at \
    cron \
    jq \
    dnsutils \
    netcat-openbsd \
    iputils-ping \
    iproute2 \
    nginx \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Set user variable for easy configuration
ARG USERNAME=aiuser
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# Create local user with specified UID/GID
RUN groupadd --gid $USER_GID $USERNAME && \
    useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME && \
    echo "$USERNAME:aipass" | chpasswd && \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Generate locale
RUN locale-gen en_US.UTF-8 && \
    localedef -i en_US -f UTF-8 en_US.UTF-8

# Set working directory to aiuser's home directory
WORKDIR /home/$USERNAME

# Install curl first, then Node.js LTS and build tools
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get update && apt-get install -y nodejs build-essential python3 make g++ && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh

# Set PATH for npm global packages
ENV PATH=/home/$USERNAME/.npm-global/bin:$PATH
RUN echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> /home/$USERNAME/.bashrc

# Install clawhub using npm (latest versions)
RUN su $USERNAME -c "npm config set prefix '~/.npm-global' && npm install -g openclaw@latest clawhub@latest && rm -rf /home/$USERNAME/.npm"

# Configure systemd to run without problems in container
RUN rm -f /etc/systemd/system/*.wants/* && \
    systemctl disable systemd-networkd-wait-online && \
    sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*/' /etc/ssh/sshd_config && \
    sed -i 's/^#Port .*/Port 2222/' /etc/ssh/sshd_config && \
    systemctl enable ssh

# Create systemd service for openclaw gateway
RUN cat > /etc/systemd/system/openclaw-gateway.service << 'SERVICE'
[Unit]
Description=OpenClaw Gateway
After=network.target ssh.service

[Service]
Type=simple
User=aiuser
Environment=HOME=/home/aiuser
Environment=PATH=/home/aiuser/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EnvironmentFile=/etc/openclaw/token.env
ExecStart=/usr/local/bin/openclaw-start.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE
RUN ln -s /etc/systemd/system/openclaw-gateway.service /etc/systemd/system/multi-user.target.wants/openclaw-gateway.service

# Expose ports (bridge network: mapped via docker-compose)
EXPOSE 2222 8080

# Fix permission for .config directory
RUN mkdir -p /home/$USERNAME/.config/systemd && \
    mkdir -p /home/$USERNAME/.openclaw && \
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.config && \
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.openclaw && \
    chmod -R 700 /home/$USERNAME/.config && \
    chmod -R 700 /home/$USERNAME/.openclaw

# Create wrapper script that reads token from config, ensures allowedOrigins, then starts gateway
# Placed outside volume mount so it persists across rebuilds
RUN cat > /usr/local/bin/openclaw-start.sh << 'SCRIPT'
#!/bin/bash
# Read existing auth config from disk
EXISTING_AUTH=$(python3 -c "
import json, os
config_path = '/home/aiuser/.openclaw/openclaw.json'
if os.path.exists(config_path):
    with open(config_path) as f:
        d = json.load(f)
    auth = d.get('gateway', {}).get('auth', {})
    print(auth.get('mode', '') + '|' + auth.get('token', '') + '|' + auth.get('trustedProxy', ''))
" 2>/dev/null)

AUTH_MODE=$(echo "$EXISTING_AUTH" | cut -d'|' -f1)
CONFIG_TOKEN=$(echo "$EXISTING_AUTH" | cut -d'|' -f2)
TRUSTED_PROXY=$(echo "$EXISTING_AUTH" | cut -d'|' -f3)

# Env var always takes priority over config file token
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    TOKEN="$OPENCLAW_GATEWAY_TOKEN"
elif [ -n "$CONFIG_TOKEN" ]; then
    TOKEN="$CONFIG_TOKEN"
else
    TOKEN="changeme"
fi

# Export as env var so gateway process uses it (CLI reads from config)
export OPENCLAW_GATEWAY_TOKEN="$TOKEN"

# Ensure config has required settings without overwriting user auth mode
python3 -c "
import json, os
config_path = '/home/aiuser/.openclaw/openclaw.json'
if os.path.exists(config_path):
    with open(config_path) as f:
        d = json.load(f)
else:
    d = {}
gw = d.setdefault('gateway', {})
gw.setdefault('port', 8080)
gw.setdefault('mode', 'local')
gw['bind'] = 'auto'
gw.setdefault('tailscale', {'mode': 'off', 'resetOnExit': False})
gw['trustedProxies'] = ['127.0.0.1', '::1']

# Only set auth if not already configured
auth_mode = '$AUTH_MODE'
if not auth_mode:
    auth = {'mode': 'token', 'token': '$TOKEN'}
    gw['auth'] = auth
else:
    auth = gw.setdefault('auth', {})
    if auth_mode == 'token':
        auth['token'] = '$TOKEN'

# Ensure remote config for CLI access
gw.setdefault('remote', {'token': '$TOKEN', 'url': 'ws://127.0.0.1:8080'})
gw['remote']['token'] = '$TOKEN'
gw['remote']['url'] = 'ws://127.0.0.1:8080'

cu = gw.setdefault('controlUi', {})
cu.setdefault('allowedOrigins', [])
cu['dangerouslyDisableDeviceAuth'] = True
required = [
    'http://localhost:8080',
    'http://127.0.0.1:8080',
    'http://192.168.1.8:8080',
    'https://192.168.1.8:8443',
    'https://aihost:8443',
    'https://localhost:8443',
    'https://127.0.0.1:8443',
    'http://localhost',
    'http://127.0.0.1'
]
for o in required:
    if o not in cu['allowedOrigins']:
        cu['allowedOrigins'].append(o)

with open(config_path, 'w') as f:
    json.dump(d, f, indent=2)
print('Config verified, auth_mode:', auth_mode)
"

# Regenerate device identity if missing (prevents "signature expired")
if [ ! -f /home/aiuser/.openclaw/identity/device.json ]; then
    /home/aiuser/.npm-global/bin/openclaw devices list > /dev/null 2>&1
fi

exec /home/aiuser/.npm-global/bin/openclaw gateway --bind lan --port 8080 --allow-unconfigured
SCRIPT
RUN chmod +x /usr/local/bin/openclaw-start.sh

# Generate self-signed TLS certificate
RUN mkdir -p /etc/nginx/ssl && \
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/server.key \
    -out /etc/nginx/ssl/server.crt \
    -subj "/CN=aihost" \
    -addext "subjectAltName=DNS:aihost,IP:192.168.1.8,IP:127.0.0.1" 2>/dev/null

# Configure nginx as HTTPS reverse proxy to gateway
# Token is baked in — Control UI frontend reads it from localStorage
RUN cat > /etc/nginx/sites-available/default << 'NGINX'
server {
    listen 8443 ssl;
    server_name aihost;

    ssl_certificate /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port 8443;

        # Inject token via URL fragment — frontend reads #token=...
        sub_filter '<head>' '<head><script>(function(){var t="3dd2ece4eddf27a09106872b41441bc9ba37005f2b5769cb6c1d4040f0606ad0";var c=document.cookie.split(";").find(function(r){return r.trim().startsWith("openclaw_token_set=")});if(c)return;document.cookie="openclaw_token_set=1;path=/;max-age=31536000";var u=location.href.split("#")[0]+"#token="+t;if(u!==location.href)location.replace(u);})();</script>';
        sub_filter_once on;
        sub_filter_types text/html;
    }
}
NGINX
RUN rm -f /etc/nginx/sites-enabled/default && ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# Start nginx alongside SSH and gateway
RUN cat > /etc/systemd/system/nginx.service << 'SERVICE'
[Unit]
Description=nginx reverse proxy
After=network.target openclaw-gateway.service

[Service]
Type=forking
ExecStart=/usr/sbin/nginx
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/usr/sbin/nginx -s stop
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE
RUN systemctl enable nginx

# Create a simple startup script that starts SSH directly
RUN echo '#!/bin/bash\n# Start SSH daemon directly\n/usr/sbin/sshd -D\n' > /start-ssh.sh && chmod +x /start-ssh.sh

# Wrapper entrypoint: write env vars to file, then start systemd
RUN mkdir -p /etc/openclaw && \
    cat > /usr/local/bin/docker-entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
# Write runtime env vars to file for systemd services
echo "ENTRYPOINT: STARTING" > /dev/kmsg 2>/dev/null || true
mkdir -p /etc/openclaw
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN" > /etc/openclaw/token.env
else
    echo "OPENCLAW_GATEWAY_TOKEN=changeme" > /etc/openclaw/token.env
fi
exec /lib/systemd/systemd "$@"
ENTRYPOINT
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
