# DeepSeek Harness in Docker

Web UI from the published `@deepseek-ai/dsh` npm package, reachable from another PC on the LAN. Model access is an OpenAI-compatible gateway configured via `.env` before start (not via Settings).

## Prerequisites

- Docker Desktop with Compose
- A reachable OpenAI-compatible endpoint (`/v1/chat/completions`)
- LAN IP of this Windows machine (for the other PC's browser)

## Setup

1. Copy the env template and fill it in:

```powershell
Copy-Item .env.example .env
```

| Variable | Required | Meaning |
|---|---|---|
| `DSH_LLM_BASE_URL` | yes | Gateway base URL (usually ends with `/v1`) |
| `DSH_LLM_API_KEY` | yes | Gateway API key |
| `DSH_MODEL` | yes | Model id sent on the wire |
| `DSH_TRUSTED_HOST` | yes | Host as typed in the other PC's browser (e.g. `192.168.1.50`, no `http://`) |
| `WORKSPACE_PATH` | yes | Host folder mounted as `/workspace` |

2. Start:

```powershell
docker compose up -d --build
```

3. Open the UI:

- This PC: [http://localhost:3080](http://localhost:3080)
- Other PC: `http://<DSH_TRUSTED_HOST>:3080`

4. Choose workspace → `/workspace`.

## Model configuration

The container disables the native DeepSeek adapter and mounts `llm-pi-ai` with one route (`docker-gateway`, protocol `openai-completions`). New sessions use `DSH_MODEL` by default.

The API key is **runtime-only** (`environment` from `.env`). It is not passed as a Docker build arg, so it does not appear in image layers.

To change URL, key, or model: edit `.env`, then:

```powershell
docker compose up -d --build
```

## LAN and trusted host

`dsh` rejects `--host 0.0.0.0` on the CLI. This stack binds `0.0.0.0` through a cordis overlay and publishes port `3080`.

Requests to `/api` must present a loopback `Host` or an authority listed in `--trusted-host`. Set `DSH_TRUSTED_HOST` to exactly what the remote browser uses (IP or hostname). A mismatch yields UI shell with API `403`.

## Settings from another PC

Settings, credential writes, and the native directory picker are loopback-only. From another PC you **cannot** save an API key in the Models page — that is why the gateway is configured via `.env`. Workspace selection uses the in-app browser against paths inside the container (start with `/workspace`).

## Security

There is **no Web UI authentication**. Anyone who can open `http://LAN_IP:3080` can run the agent and execute commands inside the container.

- Do not publish port 3080 to the internet or forward it on the router.
- Restrict Windows Firewall inbound TCP 3080 to the LAN.
- Keep `.env` out of git (already in `.gitignore`).
- Prefer a `WORKSPACE_PATH` outside OneDrive; OneDrive binds under Docker Desktop are often slow and break file watchers.

## Data

- Named volume `dsh-home` → `$DSH_HOME` (`/data/dsh`): profiles, sessions, local settings.
- Bind mount `WORKSPACE_PATH` → `/workspace`: project files the agent may read and edit.

## Stop / logs

```powershell
docker compose logs -f dsh
docker compose down
```
