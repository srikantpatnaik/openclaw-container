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
    ffmpeg \
    build-essential \
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
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh

# Install Homebrew (installs to /home/linuxbrew by default on Linux)
RUN su $USERNAME -c "export NONINTERACTIVE=1 && /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

# Add Homebrew PATH to .bashrc using the actual install location
RUN echo 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"' >> /home/$USERNAME/.bashrc

# Add Homebrew environment variables
ENV HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew
ENV HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar
ENV HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew
ENV PATH=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH

# Install GCC using Homebrew (run as non-root user)
RUN su $USERNAME -c "/home/linuxbrew/.linuxbrew/bin/brew install gcc"

# Install latest openclaw package
RUN su $USERNAME -c "npm config set prefix '~/.npm-global' && npm install -g openclaw"

# Remove npm cache
RUN rm -rf /home/$USERNAME/.npm

# Configure systemd to run without problems in container
RUN rm -f /etc/systemd/system/*.wants/* && \
    systemctl disable systemd-networkd-wait-online && \
    sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*/' /etc/ssh/sshd_config && \
    systemctl enable ssh

# Expose ports (adjust as needed)
EXPOSE 22

# Fix permission for .config directory
RUN mkdir -p /home/$USERNAME/.config && \
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.config && \
    chmod -R 700 /home/$USERNAME/.config

# Create a simple startup script that starts SSH directly
RUN echo '#!/bin/bash\n# Start SSH daemon directly\n/usr/sbin/sshd -D\n' > /start-ssh.sh && chmod +x /start-ssh.sh

# Use Tini as init process for proper signal handling, and run sshd directly
ENTRYPOINT ["/lib/systemd/systemd"]
