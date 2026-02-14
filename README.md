# OpenClaw Container

This repository contains the necessary files to build and run the OpenClaw container environment.

## Prerequisites

- Docker installed on your system
- Docker Compose installed on your system

## Quick Start

To build and start the container:

```bash
docker compose up -d --build
```

## Manual Build and Run (Alternative)

If you prefer to build and run manually:

### 1. Build the Docker image:
```bash
docker build -t aihost .
```

### 2. Run the container with SSH key mounting:
```bash
docker run -d \
  --name aihost \
  --hostname aihost \
  -p 2222:22 \
  -v ~/.ssh:/home/aiuser/.ssh:ro \
  -v ~/.gitconfig:/home/aiuser/.gitconfig:ro \
  -v ~/.git-credentials:/home/aiuser/.git-credentials:ro \
  aihost
```

### 3. Using docker-compose:
```bash
docker-compose up -d
```

## Configuration

The container uses the following volume mounts:
- `~/.ssh` → `/home/aiuser/.ssh:ro`
- `~/.gitconfig` → `/home/aiuser/.gitconfig:ro`
- `~/.git-credentials` → `/home/aiuser/.git-credentials:ro`

Ensure your SSH keys have the proper permissions:
- Private keys: `chmod 600`
- Public keys: `chmod 644`

## Note

The container will be available at port 2222 for SSH access.