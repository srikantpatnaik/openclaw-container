# OpenClaw Container

Container environment for OpenClaw with Docker.

## Prerequisites
- Docker
- Docker Compose

## Quick Start
```bash
docker compose up -d --build
```

## Manual Build
```bash
docker build -t aihost .
docker run -d --name aihost --hostname aihost -p 2222:22 \
  -v ~/.ssh:/home/aiuser/.ssh:ro \
  -v ~/.gitconfig:/home/aiuser/.gitconfig:ro \
  -v ~/.git-credentials:/home/aiuser/.git-credentials:ro \
  aihost
```

## SSH Access
- User: `aiuser`
- Port: `2222`
- Default password: `aipass` (SSH keys recommended)

## Setup
1. `openclaw configure` - Select defaults, custom provider for models
2. `openclaw gateway install` - Install gateway service
3. `systemctl --user start openclaw-gateway.service` - Start gateway

## Notes
- `polkitd` is not required in most setups
- Volume mounts: `~/.ssh`, `~/.gitconfig`, `~/.git-credentials`, `~/.config/gh`