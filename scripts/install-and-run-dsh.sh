#!/usr/bin/env bash
# Install DeepSeek Harness (dsh) for the current user and run Web UI on 0.0.0.0:3000
# against a local/remote OpenAI-compatible (vLLM) gateway.
#
# Usage:
#   chmod +x install-and-run-dsh.sh
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

echo "==> Node: $(node -v 2>/dev/null || true)"
if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: Node.js is required (22.19+ or 24+). Install it first." >&2
  exit 1
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "$NODE_MAJOR" -lt 22 ]]; then
  echo "ERROR: Node.js 22+ required, found $(node -v)" >&2
  exit 1
fi

echo "==> Install dirs"
mkdir -p "$DSH_HOME" "$DSH_WORKSPACE" "$DSH_INSTALL_DIR" "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"

# Persist PATH for later shells
if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
fi

echo "==> Installing @deepseek-ai/dsh@${DSH_VERSION} (user prefix, no sudo)"
npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"

if ! command -v dsh >/dev/null 2>&1; then
  echo "ERROR: dsh not on PATH after install. PATH=$PATH" >&2
  exit 1
fi
echo "    $(command -v dsh)"

CONFIG_DIR="$DSH_INSTALL_DIR/config"
mkdir -p "$CONFIG_DIR"

export DSH_HOME DSH_LLM_BASE_URL DSH_MODEL DSH_LLM_API_KEY DSH_TRUSTED_HOST

# Bind all interfaces — CLI rejects --host 0.0.0.0, so patch the webserver row.
cat > "$CONFIG_DIR/webserver.cordis.yml" <<EOF
- id: webserver
  config:
    host: '0.0.0.0'
    port: !!js ctx.webStartup.port ?? ${DSH_PORT}
EOF

# OpenAI-compatible vLLM route. baseURL must be .../v1 (NOT .../v1/models).
# Quote model id — it contains '/'.
python3 - "$CONFIG_DIR/llm.cordis.yml" <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    # Fallback without PyYAML: write carefully escaped YAML by hand.
    path = sys.argv[1]
    base = os.environ["DSH_LLM_BASE_URL"]
    model = os.environ["DSH_MODEL"]
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

path = sys.argv[1]
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
                    "baseURL": os.environ["DSH_LLM_BASE_URL"],
                    "models": [
                        {
                            "id": os.environ["DSH_MODEL"],
                            "name": os.environ["DSH_MODEL"],
                        }
                    ],
                }
            }
        },
    },
    {
        "id": "agent-default-model",
        "config": {
            "provider": "docker-gateway",
            "model": os.environ["DSH_MODEL"],
        },
    },
]
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(overlay, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY

echo "==> Config"
echo "    DSH_HOME=$DSH_HOME"
echo "    workspace=$DSH_WORKSPACE"
echo "    listen=0.0.0.0:${DSH_PORT}"
echo "    LLM base=$DSH_LLM_BASE_URL"
echo "    model=$DSH_MODEL"
echo "    trusted-host=$DSH_TRUSTED_HOST"
echo
echo "WARNING: no real multi-user auth. Anyone who can open the URL and has the"
echo "         ?token= from the log can run the agent on this machine."
echo
echo "==> Starting dsh (Ctrl+C to stop)"
echo "    Open the printed URL that contains ?token=..."
echo "    From another PC use host '$DSH_TRUSTED_HOST' (must match trusted-host)."
echo

cd "$DSH_WORKSPACE"
exec dsh web --no-open --port "$DSH_PORT" \
  --patch "$CONFIG_DIR/webserver.cordis.yml" \
  --patch "$CONFIG_DIR/llm.cordis.yml" \
  --trusted-host "$DSH_TRUSTED_HOST"
