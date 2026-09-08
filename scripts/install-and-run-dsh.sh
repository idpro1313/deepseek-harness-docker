#!/usr/bin/env bash
# Install DeepSeek Harness (dsh) for the current user and run Web UI on 0.0.0.0:3000
# against a local/remote OpenAI-compatible (vLLM) gateway.
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
#   DSH_TRUSTED_HOST=77.50.132.85     # host as typed in the browser (no http://)
#   DSH_INSTALL_DIR=~/dsh-app

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

# Host header the browser will send. Default: first non-loopback IPv4, else the LLM host IP.
if [[ -z "${DSH_TRUSTED_HOST:-}" ]]; then
  DSH_TRUSTED_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$DSH_TRUSTED_HOST" ]]; then
    DSH_TRUSTED_HOST="77.50.132.85"
  fi
fi

log "Step 1/7: check Node.js"
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

log "Step 2/7: prepare directories"
info "DSH_HOME=$DSH_HOME"
info "workspace=$DSH_WORKSPACE"
info "install_dir=$DSH_INSTALL_DIR"
info "npm_prefix=$HOME/.npm-global"
mkdir -p "$DSH_HOME" "$DSH_WORKSPACE" "$DSH_INSTALL_DIR" "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"
info "PATH starts with: $(echo "$PATH" | cut -d: -f1-3)"

if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
  info "appending npm-global bin to ~/.bashrc"
  echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
else
  info "~/.bashrc already has npm-global PATH"
fi

log "Step 3/7: install @deepseek-ai/dsh@${DSH_VERSION} (user prefix, no sudo)"
info "npm install -g @deepseek-ai/dsh@${DSH_VERSION}"
npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"
if ! command -v dsh >/dev/null 2>&1; then
  die "dsh not on PATH after install. PATH=$PATH"
fi
info "dsh binary: $(command -v dsh)"
info "dsh version: $(dsh --version 2>/dev/null || true)"
info "dsh web --help (launcher / app flags):"
dsh web --help 2>&1 | sed 's/^/      /' || true

CONFIG_DIR="$DSH_INSTALL_DIR/config"
mkdir -p "$CONFIG_DIR"
WEBSERVER_PATCH="$CONFIG_DIR/webserver.cordis.yml"
LLM_PATCH="$CONFIG_DIR/llm.cordis.yml"

export DSH_HOME DSH_LLM_BASE_URL DSH_MODEL DSH_LLM_API_KEY DSH_TRUSTED_HOST

log "Step 4/7: write cordis overlays"
# Bind all interfaces — CLI rejects --host 0.0.0.0, so patch the webserver row.
cat > "$WEBSERVER_PATCH" <<EOF
- id: webserver
  config:
    host: '0.0.0.0'
    port: !!js ctx.webStartup.port ?? ${DSH_PORT}
EOF
info "wrote $WEBSERVER_PATCH"
sed 's/^/      /' "$WEBSERVER_PATCH"

# OpenAI-compatible vLLM route. baseURL must be .../v1 (NOT .../v1/models).
python3 - "$LLM_PATCH" <<'PY'
import os, sys
path = sys.argv[1]
base = os.environ["DSH_LLM_BASE_URL"]
model = os.environ["DSH_MODEL"]

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
        models:
          - id: {q(model)}
            name: {q(model)}

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
                    "models": [{"id": model, "name": model}],
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

log "Step 5/7: probe LLM gateway"
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

log "Step 6/7: summary"
info "listen=0.0.0.0:${DSH_PORT}"
info "LLM base=$DSH_LLM_BASE_URL"
info "model=$DSH_MODEL"
info "apiKeyEnv=DSH_LLM_API_KEY (value length=${#DSH_LLM_API_KEY})"
info "trusted-host=$DSH_TRUSTED_HOST"
info "working_directory=$DSH_WORKSPACE"
warn "no real multi-user auth — anyone with the ?token= URL can run the agent"
warn "open the printed URL with ?token=... ; host must match trusted-host"

# IMPORTANT: launcher --patch flags MUST come before web-app flags (--port/--no-open/--trusted-host).
# Otherwise commander pass-through treats --patch as an unknown app option.
CMD=(
  dsh web
  --patch "$WEBSERVER_PATCH"
  --patch "$LLM_PATCH"
  --no-open
  --port "$DSH_PORT"
  --trusted-host "$DSH_TRUSTED_HOST"
)

log "Step 7/7: start dsh (Ctrl+C to stop)"
info "cd $DSH_WORKSPACE"
info "exec: ${CMD[*]}"
echo

cd "$DSH_WORKSPACE"
exec "${CMD[@]}"
