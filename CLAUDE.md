# CLAUDE.md

This project is a Docker-only container setup for running OpenClaw (AI agent framework) in a containerized environment.

## Quick Start

```bash
# Production
docker compose up -d --build

# Test environment
docker compose -f docker-compose.test.yml up -d --build
```

## Architecture

Single container (`aihost`) running:
- **systemd** as PID 1 inside the container
- **SSH** on port 2222 (user: `aiuser`, password: `aipass`)
- **OpenClaw gateway** on port 8080 (`openclaw gateway --bind lan --port 8080`)
- **nginx** HTTPS reverse proxy on port 8443 → forwards to 127.0.0.1:8080
- Self-signed TLS cert for `aihost` (SAN: DNS:aihost, IP:192.168.1.8, IP:127.0.0.1)

## Key Files

| File | Purpose |
|---|---|
| `Dockerfile` | Base: debian:trixie-slim. Installs systemd, nginx, nodejs 22.x, openclaw, clawhub, ssh. Entrypoint writes gateway token to `/etc/openclaw/token.env`, execs systemd. |
| `docker-compose.yml` | Production: 3 ports (2222/8080/8443), 2 named volumes (systemd-config, openclaw-data), hardcoded `OPENCLAW_GATEWAY_TOKEN` env var. |
| `docker-compose.test.yml` | Test: ports 2223/8083, no named volumes, `TEST_MODE=true`. |

## Volumes

- `~/.ssh` → `/home/aiuser/.ssh:ro`
- `~/.gitconfig` → `/home/aiuser/.gitconfig:ro`
- `~/.git-credentials` → `/home/aiuser/.git-credentials:ro`
- `~/.config/gh` → `/home/aiuser/.config/gh:ro`
- Named: `systemd-config` (systemd user config)
- Named: `openclaw-data` (openclaw state)

## Notes

- No build/lint/test commands — this is infrastructure-as-code.
- `docker-compose.yml` contains a plaintext gateway token. Rotate if committed to version control.
- OpenClaw setup: `openclaw configure` → `openclaw gateway install` → `systemctl --user start openclaw-gateway.service`
