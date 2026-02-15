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

# Install apt packages including systemd and other useful tools
RUN apt-get update && apt-get install -y \
    vim \
    htop \
    git \
    openssh-server \
    locales \
    sudo \
    curl \
    systemd \
    && rm -rf /var/lib/apt/lists/*

# Generate SSH host keys
RUN ssh-keygen -A

# Create local user "aiuser" with passwordless sudo access
RUN useradd -m -s /bin/bash aiuser && \
    echo "aiuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Generate locale
RUN locale-gen en_US.UTF-8 && \
    localedef -i en_US -f UTF-8 en_US.UTF-8

# Set working directory to aiuser's home directory
WORKDIR /home/aiuser

# Create SSH directory for aiuser with proper ownership
RUN mkdir -p /home/aiuser/.ssh && \
    chmod 700 /home/aiuser/.ssh && \
    chown aiuser:aiuser /home/aiuser/.ssh && \
    # Ensure proper permissions for home directory
    chmod 755 /home/aiuser

# Install curl first, then Node.js and npm from official website
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh

# Install latest openclaw package (commented out to avoid build hangs)
RUN npm install -g openclaw

# Copy systemd service file for sshd
COPY etc/systemd/system/ssh.service /etc/systemd/system/ssh.service

# Configure systemd to run without problems in container
RUN rm -f /etc/systemd/system/*.wants/*
RUN systemctl disable systemd-networkd-wait-online
RUN systemctl enable ssh

# Expose ports (adjust as needed)
EXPOSE 22

# Create a simple startup script that starts SSH directly
RUN echo '#!/bin/bash\n# Start SSH daemon directly\n/usr/sbin/sshd -D\n' > /start-ssh.sh && chmod +x /start-ssh.sh

# Use Tini as init process for proper signal handling, and run sshd directly
ENTRYPOINT ["/lib/systemd/systemd"]
CMD []
