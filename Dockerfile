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

# Install essential apt packages + network tools + openssl
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
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Set user variable for easy configuration
ARG USERNAME=aiuser
ARG USER_UID=1000
ARG USER_GID=$USER_UID
ARG OPENCLAW_GATEWAY_TOKEN
ARG TLS_CN=aihost
ARG TLS_IP1=192.168.1.8
ARG TLS_IP2=127.0.0.1

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

# Inject token into Control UI HTML at build time
RUN TOKEN="${OPENCLAW_GATEWAY_TOKEN:-changeme}" && \
    sed -i "s|<head>|<head><script>(function(){var t=\"${TOKEN}\";var c=document.cookie.split(\";\").find(function(r){return r.trim().startsWith(\"openclaw_token_set=\")});if(c)return;document.cookie=\"openclaw_token_set=1;path=/;max-age=31536000\";var u=location.href.split(\"#\")[0]+\"#token=\"+t;if(u!==location.href)location.replace(u);})();</script>|" \
    /home/$USERNAME/.npm-global/lib/node_modules/openclaw/dist/control-ui/index.html

# Configure systemd to run without problems in container
RUN rm -f /etc/systemd/system/*.wants/* && \
    systemctl disable systemd-networkd-wait-online && \
    sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_\*/' /etc/ssh/sshd_config && \
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

# Expose ports (SSH + gateway TLS)
EXPOSE 2222 8443

# Fix permission for .config directory
RUN mkdir -p /home/$USERNAME/.config/systemd && \
    mkdir -p /home/$USERNAME/.openclaw && \
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.config && \
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.openclaw && \
    chmod -R 700 /home/$USERNAME/.config && \
    chmod -R 700 /home/$USERNAME/.openclaw

# Generate self-signed TLS certificate for gateway (wildcard CN=*)
RUN mkdir -p /etc/openclaw/tls && \
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/openclaw/tls/server.key \
    -out /etc/openclaw/tls/server.crt \
    -subj "/CN=*" \
    -addext "subjectAltName=DNS:*,IP:127.0.0.1,IP:::1" 2>/dev/null && \
    chmod 644 /etc/openclaw/tls/server.crt && \
    chmod 644 /etc/openclaw/tls/server.key

# Create wrapper script that reads token from config, sets up TLS + auth, then starts gateway
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

# Enable TLS with bundled self-signed cert
gw.setdefault('tls', {})
gw['tls']['enabled'] = True
gw['tls']['certPath'] = '/etc/openclaw/tls/server.crt'
gw['tls']['keyPath'] = '/etc/openclaw/tls/server.key'

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
gw.setdefault('remote', {'token': '$TOKEN', 'url': 'wss://127.0.0.1:8443'})
gw['remote']['token'] = '$TOKEN'
gw['remote']['url'] = 'wss://127.0.0.1:8443'

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
    'http://127.0.0.1',
    'https://*',
    'http://*',
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

exec /home/aiuser/.npm-global/bin/openclaw gateway --bind lan --port 8443 --allow-unconfigured
SCRIPT
RUN chmod +x /usr/local/bin/openclaw-start.sh

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
