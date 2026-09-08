# DeepSeek Harness (remote Web UI)

Packaging around the published npm package `@deepseek-ai/dsh`: bind on `0.0.0.0`, OpenAI-compatible LLM (vLLM), trusted-host for LAN/remote browsers, and optional plugins (auth-gate, docs, sidebar, …).

**Primary path:** bare-metal install script on Ubuntu/Linux (`scripts/install-and-run-dsh.sh`).  
**Secondary:** Docker Compose (see below).

## Prerequisites (script)

- Node.js 22.19+ or 24+
- `git` (for GitHub-hosted plugins)
- Root or passwordless `sudo` for systemd (`dsh-web`); otherwise the script falls back to `nohup`
- Reachable OpenAI-compatible gateway (`…/v1`, not `…/v1/models`)

## Quick start (Ubuntu server)

```bash
cd /opt/deepseek-harness-docker   # or clone this repo
git pull
./scripts/install-and-run-dsh.sh
```

The script:

1. Detects whether `dsh-web` is already running (systemd / nohup pid / port).
2. Installs `@deepseek-ai/dsh`, writes cordis overlays (bind `0.0.0.0`, LLM, auth-gate).
3. Installs plugins into profile `web`.
4. Stops the old process if needed, then starts/restarts the service.
5. Reuses `DSH_AUTH_TOKEN` from `~/dsh-app/config/dsh.env` on re-runs (does not invalidate logins).

Open UI: `http://<DSH_TRUSTED_HOST>:3000`  
First visit: use the `?token=` URL from logs; then log in with the shared **auth-gate** token printed by the script.

```bash
systemctl status dsh-web
journalctl -u dsh-web -f
```

### Service control

| Action | Command |
|---|---|
| Full install / update + restart | `./scripts/install-and-run-dsh.sh` |
| Status only | `DSH_ACTION=status ./scripts/install-and-run-dsh.sh` |
| Stop | `DSH_ACTION=stop ./scripts/install-and-run-dsh.sh` |
| Restart (no reinstall) | `DSH_ACTION=restart ./scripts/install-and-run-dsh.sh` |
| Update config/plugins but leave process up | `DSH_RESTART=0 ./scripts/install-and-run-dsh.sh` |
| Foreground (debug) | `DSH_FOREGROUND=1 ./scripts/install-and-run-dsh.sh` |

Or: `systemctl stop|start|restart dsh-web`.

### Environment overrides

| Variable | Default | Meaning |
|---|---|---|
| `DSH_VERSION` | `0.1.2-rc.1` | npm `@deepseek-ai/dsh` version |
| `DSH_PORT` | `3000` | listen port |
| `DSH_HOME` | `~/.dsh` | profiles / sessions |
| `DSH_WORKSPACE` | `~/workspace` | agent working directory |
| `DSH_INSTALL_DIR` | `~/dsh-app` | config, unit, logs, pid |
| `DSH_LLM_BASE_URL` | `http://77.50.132.85:8111/v1` | gateway base (`/v1`) |
| `DSH_MODEL` | `Inferact/Qwen3.8-27B-NVFP4` | model id |
| `DSH_LLM_API_KEY` | `sk-local` | gateway key |
| `DSH_CONTEXT_WINDOW` | `16384` | must match server `max_model_len` |
| `DSH_MAX_TOKENS` | `8192` | must be **&lt;** context window |
| `DSH_TRUSTED_HOST` | auto / LAN IP | Host as typed in the browser (no `http://`) |
| `DSH_AUTH_TOKEN` | reused or generated | shared login for `dsh-auth-gate` |
| `DSH_SERVICE_NAME` | `dsh-web` | systemd unit name |
| `DSH_SKIP_PLUGINS` | `0` | `1` = skip plugin installs |
| `DSH_PLUGINS_STRICT` | `0` | `1` = fail if any plugin fails |
| `DSH_RESTART` | `1` | `0` = do not stop/start if already running |
| `DSH_ACTION` | `install` | `install` \| `status` \| `stop` \| `restart` |

Example:

```bash
DSH_LLM_BASE_URL=http://127.0.0.1:8111/v1 \
DSH_MODEL=Inferact/Qwen3.8-27B-NVFP4 \
DSH_TRUSTED_HOST=77.50.132.85 \
./scripts/install-and-run-dsh.sh
```

### Plugins (profile `web`)

Installed by default:

| Name | Package |
|---|---|
| dsh-document | `@jiaoqsh/dsh-document` |
| dsh-auth-gate | `dsh-auth-gate` |
| dsh-docs | `dsh-doc` |
| dsh-open-file | `dsh-open-file` |
| dsh-chat-files | `github:xzyonline/dsh-file-attachments` |
| DSH-better-sidebar | `dsh-better-sidebar` |

Auth-gate runs in **token** mode over plain HTTP (`cookieSecure: false`). The login token is stored in `$DSH_INSTALL_DIR/config/dsh.env` (mode `600`).

### LLM token limits

If the gateway returns HTTP 400 about context length, lower `DSH_CONTEXT_WINDOW` / `DSH_MAX_TOKENS` so they fit the server’s `max_model_len` (script default assumes 16384).

## Trusted host and Settings

`dsh` rejects CLI `--host 0.0.0.0`; the script binds via a cordis `--patch` (must appear **before** `--port` / `--trusted-host`).

`/api` requires `--trusted-host` to match the browser `Host`. A mismatch shows the UI shell with API `403`.

Settings / credential writes are **loopback-only**. From another PC you cannot save models in Settings — use the script overlays / env instead.

## Security

- Prefer **auth-gate** (`DSH_AUTH_TOKEN`) when exposing beyond localhost.
- Do not publish the port to the open internet without additional controls (TLS reverse proxy, firewall).
- Keep `dsh.env` private; it holds the API key and auth token.
- There is still no strong multi-user isolation inside one `dsh` process.

## Docker (optional)

```powershell
Copy-Item .env.example .env
# edit DSH_LLM_*, DSH_TRUSTED_HOST, WORKSPACE_PATH
docker compose up -d --build
```

- This PC: http://localhost:3080  
- Other PC: `http://<DSH_TRUSTED_HOST>:3080`  
- Workspace inside container: `/workspace`

```powershell
docker compose logs -f dsh
docker compose down
```

The API key is runtime-only from `.env` (not a build arg).

## Layout

| Path | Role |
|---|---|
| `scripts/install-and-run-dsh.sh` | install, plugins, systemd/nohup lifecycle |
| `docker-compose.yml` / `Dockerfile` | optional container stack |
| `docker/webserver.cordis.yml` | bind `0.0.0.0` for Docker |
| `.env.example` | Docker env template |

On the server after script install:

| Path | Role |
|---|---|
| `~/dsh-app/config/dsh.env` | runtime env + `DSH_AUTH_TOKEN` |
| `~/dsh-app/config/*.cordis.yml` | overlays |
| `~/.dsh` | profiles, plugins, sessions |
| `/etc/systemd/system/dsh-web.service` | unit (when systemd is used) |
