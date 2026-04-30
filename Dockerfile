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

# Generate self-signed TLS certificate
RUN mkdir -p /etc/ssl/certs/openclaw && \
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/ssl/certs/openclaw/server.key \
    -out /etc/ssl/certs/openclaw/server.crt \
    -subj "/C=US/ST=Local/L=Container/O=OpenClaw/CN=aihost" \
    -addext "subjectAltName=DNS:aihost,IP:127.0.0.1,IP:192.168.1.8" 2>/dev/null && \
    chmod 640 /etc/ssl/certs/openclaw/server.key && \
    chmod 644 /etc/ssl/certs/openclaw/server.crt

# Create nginx reverse proxy config for HTTPS
RUN cat > /etc/nginx/sites-available/openclaw << 'NGINX'
server {
    listen 8443 ssl;
    server_name aihost localhost;

    ssl_certificate /etc/ssl/certs/openclaw/server.crt;
    ssl_certificate_key /etc/ssl/certs/openclaw/server.key;
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
        proxy_read_timeout 86400;
    }
}
NGINX
RUN rm -f /etc/nginx/sites-enabled/default && \
    ln -s /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw

# Create systemd service for nginx
RUN cat > /etc/systemd/system/nginx.service << 'SERVICE'
[Unit]
Description=OpenClaw HTTPS Reverse Proxy
After=network.target openclaw-gateway.service
Requires=openclaw-gateway.service

[Service]
Type=forking
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

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
ExecStart=/usr/local/bin/openclaw-start.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE
RUN ln -s /etc/systemd/system/openclaw-gateway.service /etc/systemd/system/multi-user.target.wants/openclaw-gateway.service && \
    ln -s /etc/systemd/system/nginx.service /etc/systemd/system/multi-user.target.wants/nginx.service

# Expose ports (bridge network: mapped via docker-compose)
EXPOSE 2222 8080 8443

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
# Read existing token from config if present, else use env var or default
CONFIG_TOKEN=$(python3 -c "
import json, os
config_path = '/home/aiuser/.openclaw/openclaw.json'
if os.path.exists(config_path):
    with open(config_path) as f:
        d = json.load(f)
    print(d.get('gateway', {}).get('auth', {}).get('token', ''))
" 2>/dev/null)

# Use config token if found, else env var, else default
if [ -n "$CONFIG_TOKEN" ]; then
    TOKEN="$CONFIG_TOKEN"
else
    TOKEN="${OPENCLAW_GATEWAY_TOKEN:-changeme}"
fi

# Export as env var so gateway process uses it (CLI reads from config)
export OPENCLAW_GATEWAY_TOKEN="$TOKEN"

# Ensure config has auth token and allowedOrigins
python3 -c "
import json, os, time
config_path = '/home/aiuser/.openclaw/openclaw.json'
if os.path.exists(config_path):
    with open(config_path) as f:
        d = json.load(f)
else:
    d = {}
gw = d.setdefault('gateway', {})
gw.setdefault('port', 8080)
gw.setdefault('mode', 'local')
gw.setdefault('bind', 'lan')
gw.setdefault('tailscale', {'mode': 'off', 'resetOnExit': False})
auth = gw.setdefault('auth', {'mode': 'token', 'token': '$TOKEN'})
auth.setdefault('mode', 'token')
auth.setdefault('token', '$TOKEN')
# Ensure remote config for CLI access
gw.setdefault('remote', {'token': '$TOKEN', 'url': 'ws://127.0.0.1:8080'})
gw['remote']['token'] = '$TOKEN'
gw['remote']['url'] = 'ws://127.0.0.1:8080'
cu = gw.setdefault('controlUi', {})
cu.setdefault('allowedOrigins', [])
required = [
    'http://localhost:8080',
    'http://127.0.0.1:8080',
    'http://192.168.1.8:8080',
    'http://localhost',
    'http://127.0.0.1',
    'https://localhost:8443',
    'https://127.0.0.1:8443',
    'https://192.168.1.8:8443',
    'https://aihost:8443',
    'https://localhost',
    'https://127.0.0.1'
]
for o in required:
    if o not in cu['allowedOrigins']:
        cu['allowedOrigins'].append(o)
with open(config_path, 'w') as f:
    json.dump(d, f, indent=2)
print('Config verified, token length:', len('$TOKEN'))
"

# Regenerate device identity if missing (prevents "signature expired")
if [ ! -f /home/aiuser/.openclaw/identity/device.json ]; then
    /home/aiuser/.npm-global/bin/openclaw devices list > /dev/null 2>&1
fi

exec /home/aiuser/.npm-global/bin/openclaw gateway --bind lan --port 8080 --allow-unconfigured
SCRIPT
RUN chmod +x /usr/local/bin/openclaw-start.sh

# Create a simple startup script that starts SSH directly
RUN echo '#!/bin/bash\n# Start SSH daemon directly\n/usr/sbin/sshd -D\n' > /start-ssh.sh && chmod +x /start-ssh.sh

# Use Tini as init process for proper signal handling, and run sshd directly
ENTRYPOINT ["/lib/systemd/systemd"]
