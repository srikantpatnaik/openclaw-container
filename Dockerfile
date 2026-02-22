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

# Install essential apt packages
RUN apt-get update && apt-get install -y \
    vim \
    htop \
    git \
    openssh-server \
    locales \
    sudo \
    curl \
    systemd \
    wget \
    at \
    cron \
    jq \
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

# Install curl first, then Node.js and npm from official website
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs build-essential && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh

# Set PATH for npm global packages
ENV PATH=/home/$USERNAME/.npm-global/bin:$PATH
RUN echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> /home/$USERNAME/.bashrc

# Install clawhub using npm
RUN su $USERNAME -c "npm config set prefix '~/.npm-global' && npm install -g openclaw clawhub && rm -rf /home/$USERNAME/.npm" 

# Configure systemd to run without problems in container
RUN rm -f /etc/systemd/system/*.wants/* && \
    systemctl disable systemd-networkd-wait-online && \
    sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*/' /etc/ssh/sshd_config && \
    systemctl enable ssh

# Expose ports (adjust as needed)
EXPOSE 22

# Fix permission for .config directory
RUN mkdir -p /home/$USERNAME/.config/systemd && \
    mkdir -p /home/$USERNAME/.openclaw && \
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.config && \
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.openclaw && \
    chmod -R 700 /home/$USERNAME/.config && \
    chmod -R 700 /home/$USERNAME/.openclaw

# Create a simple startup script that starts SSH directly
RUN echo '#!/bin/bash\n# Start SSH daemon directly\n/usr/sbin/sshd -D\n' > /start-ssh.sh && chmod +x /start-ssh.sh

# Use Tini as init process for proper signal handling, and run sshd directly
ENTRYPOINT ["/lib/systemd/systemd"]
