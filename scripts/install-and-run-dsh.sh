#!/usr/bin/env bash
# Install DeepSeek Harness (dsh) and run the Web UI in the background on 0.0.0.0:3000
# against an OpenAI-compatible (vLLM) gateway.
#
# Usage:
#   ./install-and-run-dsh.sh
#
# Optional env overrides:
#   DSH_VERSION=0.1.2-rc.1
#   DSH_PORT=3000
#   DSH_HOME=~/.dsh
#   DSH_WORKSPACE=~/workspace
#   DSH_LLM_BASE_URL=http://77.50.132.85:8111/v1
#   DSH_MODEL=Inferact/Qwen3.8-27B-NVFP4
#   DSH_LLM_API_KEY=sk-local          # vLLM often ignores the key; value must be non-empty
#   DSH_CONTEXT_WINDOW=16384          # must match vLLM max_model_len
#   DSH_MAX_TOKENS=8192               # output cap; must be < context window
#   DSH_TRUSTED_HOST=77.50.132.85     # host as typed in the browser (no http://)
#   DSH_INSTALL_DIR=~/dsh-app
#   DSH_SERVICE_NAME=dsh-web          # systemd unit name (without .service)
#   DSH_FOREGROUND=1                  # if set, run in the console instead of background

set -euo pipefail

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

DSH_VERSION="${DSH_VERSION:-0.1.2-rc.1}"
DSH_PORT="${DSH_PORT:-3000}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_WORKSPACE="${DSH_WORKSPACE:-$HOME/workspace}"
DSH_INSTALL_DIR="${DSH_INSTALL_DIR:-$HOME/dsh-app}"
DSH_LLM_BASE_URL="${DSH_LLM_BASE_URL:-http://77.50.132.85:8111/v1}"
DSH_MODEL="${DSH_MODEL:-Inferact/Qwen3.8-27B-NVFP4}"
DSH_LLM_API_KEY="${DSH_LLM_API_KEY:-sk-local}"
# vLLM reported max_model_len=16384; dsh defaultMaxTokens is 32768 and gets rejected.
DSH_CONTEXT_WINDOW="${DSH_CONTEXT_WINDOW:-16384}"
DSH_MAX_TOKENS="${DSH_MAX_TOKENS:-8192}"
DSH_SERVICE_NAME="${DSH_SERVICE_NAME:-dsh-web}"
DSH_FOREGROUND="${DSH_FOREGROUND:-0}"

# Host header the browser will send. Default: first non-loopback IPv4, else the LLM host IP.
if [[ -z "${DSH_TRUSTED_HOST:-}" ]]; then
  DSH_TRUSTED_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$DSH_TRUSTED_HOST" ]]; then
    DSH_TRUSTED_HOST="77.50.132.85"
  fi
fi

log "Step 1/8: check Node.js"
if ! command -v node >/dev/null 2>&1; then
  die "Node.js is required (22.19+ or 24+). Install it first."
fi
info "node=$(command -v node)"
info "version=$(node -v)"
info "npm=$(npm -v 2>/dev/null || echo missing)"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "$NODE_MAJOR" -lt 22 ]]; then
  die "Node.js 22+ required, found $(node -v)"
fi

log "Step 2/8: prepare directories"
info "DSH_HOME=$DSH_HOME"
info "workspace=$DSH_WORKSPACE"
info "install_dir=$DSH_INSTALL_DIR"
info "npm_prefix=$HOME/.npm-global"
mkdir -p "$DSH_HOME" "$DSH_WORKSPACE" "$DSH_INSTALL_DIR" "$HOME/.npm-global" "$DSH_INSTALL_DIR/logs"
npm config set prefix "$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"
info "PATH starts with: $(echo "$PATH" | cut -d: -f1-3)"

if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
  info "appending npm-global bin to ~/.bashrc"
  echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
else
  info "~/.bashrc already has npm-global PATH"
fi

log "Step 3/8: install @deepseek-ai/dsh@${DSH_VERSION} (user prefix, no sudo)"
info "npm install -g @deepseek-ai/dsh@${DSH_VERSION}"
npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"
DSH_BIN="$(command -v dsh || true)"
if [[ -z "$DSH_BIN" ]]; then
  die "dsh not on PATH after install. PATH=$PATH"
fi
info "dsh binary: $DSH_BIN"
info "dsh version: $($DSH_BIN --version 2>/dev/null || true)"
info "dsh web --help:"
"$DSH_BIN" web --help 2>&1 | sed 's/^/      /' || true

CONFIG_DIR="$DSH_INSTALL_DIR/config"
mkdir -p "$CONFIG_DIR"
WEBSERVER_PATCH="$CONFIG_DIR/webserver.cordis.yml"
LLM_PATCH="$CONFIG_DIR/llm.cordis.yml"
ENV_FILE="$CONFIG_DIR/dsh.env"
UNIT_FILE="$CONFIG_DIR/${DSH_SERVICE_NAME}.service"
PID_FILE="$DSH_INSTALL_DIR/dsh.pid"
LOG_FILE="$DSH_INSTALL_DIR/logs/dsh.log"

export DSH_HOME DSH_LLM_BASE_URL DSH_MODEL DSH_LLM_API_KEY DSH_TRUSTED_HOST
export DSH_CONTEXT_WINDOW DSH_MAX_TOKENS

if ! [[ "$DSH_CONTEXT_WINDOW" =~ ^[1-9][0-9]*$ && "$DSH_MAX_TOKENS" =~ ^[1-9][0-9]*$ ]]; then
  die "DSH_CONTEXT_WINDOW and DSH_MAX_TOKENS must be positive integers"
fi
if (( DSH_MAX_TOKENS >= DSH_CONTEXT_WINDOW )); then
  die "DSH_MAX_TOKENS ($DSH_MAX_TOKENS) must be smaller than DSH_CONTEXT_WINDOW ($DSH_CONTEXT_WINDOW)"
fi

log "Step 4/8: write cordis overlays"
cat > "$WEBSERVER_PATCH" <<EOF
- id: webserver
  config:
    host: '0.0.0.0'
    port: !!js ctx.webStartup.port ?? ${DSH_PORT}
EOF
info "wrote $WEBSERVER_PATCH"
sed 's/^/      /' "$WEBSERVER_PATCH"

python3 - "$LLM_PATCH" <<'PY'
import os, sys
path = sys.argv[1]
base = os.environ["DSH_LLM_BASE_URL"]
model = os.environ["DSH_MODEL"]
context_window = int(os.environ["DSH_CONTEXT_WINDOW"])
max_tokens = int(os.environ["DSH_MAX_TOKENS"])

try:
    import yaml
except ImportError:
    def q(s: str) -> str:
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    open(path, "w", encoding="utf-8").write(
        f"""- id: llm-deepseek
  disabled: true

- id: llm-pi-ai
  config:
    providers:
      docker-gateway:
        displayName: vLLM gateway
        apiKeyEnv: DSH_LLM_API_KEY
        api: openai-completions
        baseURL: {q(base)}
        defaultContextWindow: {context_window}
        defaultMaxTokens: {max_tokens}
        models:
          - id: {q(model)}
            name: {q(model)}
            contextWindow: {context_window}
            maxTokens: {max_tokens}

- id: agent-default-model
  config:
    provider: docker-gateway
    model: {q(model)}
"""
    )
    raise SystemExit(0)

overlay = [
    {"id": "llm-deepseek", "disabled": True},
    {
        "id": "llm-pi-ai",
        "config": {
            "providers": {
                "docker-gateway": {
                    "displayName": "vLLM gateway",
                    "apiKeyEnv": "DSH_LLM_API_KEY",
                    "api": "openai-completions",
                    "baseURL": base,
                    "defaultContextWindow": context_window,
                    "defaultMaxTokens": max_tokens,
                    "models": [{
                        "id": model,
                        "name": model,
                        "contextWindow": context_window,
                        "maxTokens": max_tokens,
                    }],
                }
            }
        },
    },
    {
        "id": "agent-default-model",
        "config": {"provider": "docker-gateway", "model": model},
    },
]
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(overlay, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY
info "wrote $LLM_PATCH"
sed 's/^/      /' "$LLM_PATCH"

log "Step 5/8: probe LLM gateway"
MODELS_URL="${DSH_LLM_BASE_URL%/}/models"
info "GET $MODELS_URL"
if command -v curl >/dev/null 2>&1; then
  if curl -fsS --max-time 10 "$MODELS_URL" | sed 's/^/      /'; then
    info "LLM /models reachable"
  else
    warn "could not reach $MODELS_URL — dsh may fail on first chat"
  fi
else
  warn "curl not installed; skip LLM probe"
fi

log "Step 6/8: write service env + unit files"
# IMPORTANT: launcher --patch flags MUST come before web-app flags.
CMD=(
  "$DSH_BIN" web
  --patch "$WEBSERVER_PATCH"
  --patch "$LLM_PATCH"
  --no-open
  --port "$DSH_PORT"
  --trusted-host "$DSH_TRUSTED_HOST"
)

umask 077
cat > "$ENV_FILE" <<EOF
DSH_HOME=$DSH_HOME
DSH_LLM_BASE_URL=$DSH_LLM_BASE_URL
DSH_MODEL=$DSH_MODEL
DSH_LLM_API_KEY=$DSH_LLM_API_KEY
DSH_TRUSTED_HOST=$DSH_TRUSTED_HOST
DSH_CONTEXT_WINDOW=$DSH_CONTEXT_WINDOW
DSH_MAX_TOKENS=$DSH_MAX_TOKENS
PATH=$HOME/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
chmod 600 "$ENV_FILE"
info "wrote $ENV_FILE (mode 600; contains API key)"

# Escape for systemd ExecStart (space-separated argv; quote paths with spaces if any).
EXEC_START="$DSH_BIN web --patch $WEBSERVER_PATCH --patch $LLM_PATCH --no-open --port $DSH_PORT --trusted-host $DSH_TRUSTED_HOST"

SERVICE_USER="$(id -un)"
SERVICE_GROUP="$(id -gn)"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=DeepSeek Harness Web UI ($DSH_SERVICE_NAME)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$DSH_WORKSPACE
EnvironmentFile=$ENV_FILE
ExecStart=$EXEC_START
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
info "wrote $UNIT_FILE"
sed 's/^/      /' "$UNIT_FILE"

log "Step 7/8: summary"
info "listen=0.0.0.0:${DSH_PORT}"
info "LLM base=$DSH_LLM_BASE_URL"
info "model=$DSH_MODEL"
info "contextWindow=$DSH_CONTEXT_WINDOW maxTokens=$DSH_MAX_TOKENS"
info "trusted-host=$DSH_TRUSTED_HOST"
info "workspace=$DSH_WORKSPACE"
info "command: ${CMD[*]}"
warn "no real multi-user auth — anyone with the ?token= URL can run the agent"
warn "Settings→Models is loopback-only; model is already set by overlay"

start_foreground() {
  log "Step 8/8: start dsh in foreground (DSH_FOREGROUND=1)"
  info "cd $DSH_WORKSPACE"
  info "exec: ${CMD[*]}"
  cd "$DSH_WORKSPACE"
  exec "${CMD[@]}"
}

start_systemd() {
  local unit_dst="/etc/systemd/system/${DSH_SERVICE_NAME}.service"
  log "Step 8/8: install and start systemd service ${DSH_SERVICE_NAME}"
  info "copy unit → $unit_dst"
  cp "$UNIT_FILE" "$unit_dst"
  systemctl daemon-reload
  systemctl enable --now "$DSH_SERVICE_NAME"
  sleep 2
  systemctl --no-pager --full status "$DSH_SERVICE_NAME" || true
  echo
  info "logs: journalctl -u $DSH_SERVICE_NAME -f"
  info "stop: systemctl stop $DSH_SERVICE_NAME"
  info "token URL (look for ?token=):"
  journalctl -u "$DSH_SERVICE_NAME" -n 80 --no-pager 2>/dev/null | grep -E 'dsh web:|token=' | sed 's/^/      /' || warn "token line not in logs yet; run: journalctl -u $DSH_SERVICE_NAME -f"
}

start_nohup() {
  log "Step 8/8: start with nohup (no systemd write access)"
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    warn "already running pid=$(cat "$PID_FILE"); stopping it first"
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    sleep 2
  fi
  cd "$DSH_WORKSPACE"
  export DSH_HOME DSH_LLM_BASE_URL DSH_MODEL DSH_LLM_API_KEY DSH_TRUSTED_HOST
  export PATH="$HOME/.npm-global/bin:$PATH"
  nohup "${CMD[@]}" >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 2
  if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    info "started pid=$(cat "$PID_FILE")"
    info "log: $LOG_FILE"
    info "stop: kill \$(cat $PID_FILE)"
    info "token URL:"
    grep -E 'dsh web:|token=' "$LOG_FILE" | tail -n 5 | sed 's/^/      /' || warn "token not in log yet; tail -f $LOG_FILE"
  else
    die "process exited immediately; see $LOG_FILE"
  fi
}

if [[ "$DSH_FOREGROUND" == "1" ]]; then
  start_foreground
fi

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  if [[ "$(id -u)" -eq 0 ]] || sudo -n true 2>/dev/null; then
    if [[ "$(id -u)" -eq 0 ]]; then
      start_systemd
    else
      log "Step 8/8: install systemd unit with sudo"
      sudo cp "$UNIT_FILE" "/etc/systemd/system/${DSH_SERVICE_NAME}.service"
      sudo systemctl daemon-reload
      sudo systemctl enable --now "$DSH_SERVICE_NAME"
      sleep 2
      sudo systemctl --no-pager --full status "$DSH_SERVICE_NAME" || true
      info "logs: sudo journalctl -u $DSH_SERVICE_NAME -f"
      sudo journalctl -u "$DSH_SERVICE_NAME" -n 80 --no-pager 2>/dev/null | grep -E 'dsh web:|token=' | sed 's/^/      /' || true
    fi
  else
    warn "systemd present but no root/sudo rights; falling back to nohup"
    start_nohup
  fi
else
  warn "systemd not available; falling back to nohup"
  start_nohup
fi
