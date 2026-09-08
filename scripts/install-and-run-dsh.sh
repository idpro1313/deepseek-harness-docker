#!/usr/bin/env bash
# Install DeepSeek Harness (dsh) and run the Web UI in the background on 0.0.0.0:3000
# against an OpenAI-compatible (vLLM) gateway. Also installs file/auth plugins into profile web.
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
#   DSH_LLM_API_KEY=sk-local
#   DSH_CONTEXT_WINDOW=16384
#   DSH_MAX_TOKENS=8192
#   DSH_TRUSTED_HOST=77.50.132.85
#   DSH_INSTALL_DIR=~/dsh-app
#   DSH_SERVICE_NAME=dsh-web
#   DSH_FOREGROUND=1
#   DSH_AUTH_TOKEN=...                 # shared login for dsh-auth-gate (auto-generated if empty)
#   DSH_SKIP_PLUGINS=1                 # skip plugin installation
#   DSH_PLUGINS_STRICT=1               # fail the script if any plugin install fails

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
DSH_CONTEXT_WINDOW="${DSH_CONTEXT_WINDOW:-16384}"
DSH_MAX_TOKENS="${DSH_MAX_TOKENS:-8192}"
DSH_SERVICE_NAME="${DSH_SERVICE_NAME:-dsh-web}"
DSH_FOREGROUND="${DSH_FOREGROUND:-0}"
DSH_SKIP_PLUGINS="${DSH_SKIP_PLUGINS:-0}"
DSH_PLUGINS_STRICT="${DSH_PLUGINS_STRICT:-0}"
DSH_PROFILE="${DSH_PROFILE:-web}"

# npm / git install specs (user-facing names → real packages)
# - dsh-document       → @jiaoqsh/dsh-document
# - dsh-auth-gate      → dsh-auth-gate
# - dsh-docs           → dsh-doc  (npm; repo Sqhao-O/dsh-docs — stub package "dsh-docs" is empty)
# - dsh-open-file      → dsh-open-file
# - dsh-chat-files     → github:xzyonline/dsh-file-attachments (not published to npm)
# - DSH-better-sidebar → dsh-better-sidebar
DEFAULT_PLUGINS=(
  "@jiaoqsh/dsh-document"
  "dsh-auth-gate"
  "dsh-doc"
  "dsh-open-file"
  "github:xzyonline/dsh-file-attachments"
  "dsh-better-sidebar"
)

if [[ -z "${DSH_TRUSTED_HOST:-}" ]]; then
  DSH_TRUSTED_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$DSH_TRUSTED_HOST" ]]; then
    DSH_TRUSTED_HOST="77.50.132.85"
  fi
fi

if [[ -z "${DSH_AUTH_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    DSH_AUTH_TOKEN="$(openssl rand -hex 24)"
  else
    DSH_AUTH_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  info "generated DSH_AUTH_TOKEN (length=${#DSH_AUTH_TOKEN})"
fi

log "Step 1/9: check Node.js / git"
if ! command -v node >/dev/null 2>&1; then
  die "Node.js is required (22.19+ or 24+). Install it first."
fi
info "node=$(command -v node) version=$(node -v) npm=$(npm -v 2>/dev/null || echo missing)"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "$NODE_MAJOR" -lt 22 ]]; then
  die "Node.js 22+ required, found $(node -v)"
fi
if ! command -v git >/dev/null 2>&1; then
  die "git is required (needed for github: plugin specs)"
fi
info "git=$(git --version)"

log "Step 2/9: prepare directories"
info "DSH_HOME=$DSH_HOME"
info "workspace=$DSH_WORKSPACE"
info "install_dir=$DSH_INSTALL_DIR"
mkdir -p "$DSH_HOME" "$DSH_WORKSPACE" "$DSH_INSTALL_DIR" "$HOME/.npm-global" "$DSH_INSTALL_DIR/logs" "$DSH_HOME/auth"
npm config set prefix "$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"
if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
fi

log "Step 3/9: install @deepseek-ai/dsh@${DSH_VERSION} and pnpm"
npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"
if ! command -v pnpm >/dev/null 2>&1; then
  info "installing pnpm (required by: dsh plugin)"
  npm install -g pnpm
fi
DSH_BIN="$(command -v dsh || true)"
[[ -n "$DSH_BIN" ]] || die "dsh not on PATH after install"
info "dsh=$DSH_BIN ($("$DSH_BIN" --version 2>/dev/null || true))"
info "pnpm=$(command -v pnpm) ($(pnpm --version 2>/dev/null || true))"

CONFIG_DIR="$DSH_INSTALL_DIR/config"
mkdir -p "$CONFIG_DIR"
WEBSERVER_PATCH="$CONFIG_DIR/webserver.cordis.yml"
LLM_PATCH="$CONFIG_DIR/llm.cordis.yml"
AUTH_PATCH="$CONFIG_DIR/auth-gate.cordis.yml"
ENV_FILE="$CONFIG_DIR/dsh.env"
UNIT_FILE="$CONFIG_DIR/${DSH_SERVICE_NAME}.service"
PID_FILE="$DSH_INSTALL_DIR/dsh.pid"
LOG_FILE="$DSH_INSTALL_DIR/logs/dsh.log"
HOME_PATCH="$DSH_HOME/cordis.patch.yml"

export DSH_HOME DSH_LLM_BASE_URL DSH_MODEL DSH_LLM_API_KEY DSH_TRUSTED_HOST
export DSH_CONTEXT_WINDOW DSH_MAX_TOKENS DSH_AUTH_TOKEN

if ! [[ "$DSH_CONTEXT_WINDOW" =~ ^[1-9][0-9]*$ && "$DSH_MAX_TOKENS" =~ ^[1-9][0-9]*$ ]]; then
  die "DSH_CONTEXT_WINDOW and DSH_MAX_TOKENS must be positive integers"
fi
if (( DSH_MAX_TOKENS >= DSH_CONTEXT_WINDOW )); then
  die "DSH_MAX_TOKENS ($DSH_MAX_TOKENS) must be smaller than DSH_CONTEXT_WINDOW ($DSH_CONTEXT_WINDOW)"
fi

log "Step 4/9: write cordis overlays"
cat > "$WEBSERVER_PATCH" <<EOF
- id: webserver
  config:
    host: '0.0.0.0'
    port: !!js ctx.webStartup.port ?? ${DSH_PORT}
EOF
info "wrote $WEBSERVER_PATCH"

python3 - "$LLM_PATCH" <<'PY'
import os, sys
path = sys.argv[1]
base = os.environ["DSH_LLM_BASE_URL"]
model = os.environ["DSH_MODEL"]
context_window = int(os.environ["DSH_CONTEXT_WINDOW"])
max_tokens = int(os.environ["DSH_MAX_TOKENS"])

def write_manual():
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

try:
    import yaml
except ImportError:
    write_manual()
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
    {"id": "agent-default-model", "config": {"provider": "docker-gateway", "model": model}},
]
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(overlay, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY
info "wrote $LLM_PATCH"

# Plain HTTP deployment: cookieSecure must be false or the browser drops the auth cookie.
cat > "$AUTH_PATCH" <<'EOF'
- id: dsh-auth-gate
  config:
    mode: token
    tokenRef: DSH_AUTH_TOKEN
    cookieSecure: false
    sessionTtl: 604800
EOF
info "wrote $AUTH_PATCH (auth-gate over plain HTTP)"

# Also keep a durable home-level override so auth-gate works even without --patch.
python3 - "$HOME_PATCH" "$AUTH_PATCH" <<'PY'
import sys
from pathlib import Path
home_path = Path(sys.argv[1])
auth_path = Path(sys.argv[2])
auth_rows = []
try:
    import yaml
    auth_rows = yaml.safe_load(auth_path.read_text(encoding="utf-8")) or []
    existing = []
    if home_path.exists():
        existing = yaml.safe_load(home_path.read_text(encoding="utf-8")) or []
    if not isinstance(existing, list):
        existing = []
    kept = [row for row in existing if not (isinstance(row, dict) and row.get("id") == "dsh-auth-gate")]
    kept.extend(auth_rows)
    home_path.write_text(yaml.safe_dump(kept, default_flow_style=False, allow_unicode=True, sort_keys=False), encoding="utf-8")
except ImportError:
    home_path.write_text(auth_path.read_text(encoding="utf-8"), encoding="utf-8")
PY
info "merged auth-gate into $HOME_PATCH"

log "Step 5/9: probe LLM gateway"
MODELS_URL="${DSH_LLM_BASE_URL%/}/models"
info "GET $MODELS_URL"
if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 10 "$MODELS_URL" | sed 's/^/      /' || warn "LLM /models not reachable"
else
  warn "curl missing; skip LLM probe"
fi

log "Step 6/9: install profile plugins"
install_one_plugin() {
  local spec="$1"
  info "add $spec"
  local out
  if out="$("$DSH_BIN" plugin --profile "$DSH_PROFILE" add "$spec" 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^/      /'
    return 0
  fi
  printf '%s\n' "$out" | sed 's/^/      /'
  # pnpm may require allowing prepare/build scripts for git-hosted packages.
  if printf '%s\n' "$out" | grep -qiE 'allowBuilds|Ignored build scripts|pnpm.onlyBuiltDependencies'; then
    local pkg_json="$DSH_HOME/profiles/$DSH_PROFILE/package.json"
    warn "retrying $spec after enabling pnpm build scripts in profile"
    python3 - "$pkg_json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
pnpm = data.setdefault("pnpm", {})
# Broad allow for plugin prepare scripts in this dedicated profile.
pnpm["neverBuiltDependencies"] = []
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
    if out="$("$DSH_BIN" plugin --profile "$DSH_PROFILE" add "$spec" 2>&1)"; then
      printf '%s\n' "$out" | sed 's/^/      /'
      return 0
    fi
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
  return 1
}

PLUGIN_FAILED=()
if [[ "$DSH_SKIP_PLUGINS" == "1" ]]; then
  warn "DSH_SKIP_PLUGINS=1 — skipping plugin installs"
else
  info "initializing profile '$DSH_PROFILE'"
  "$DSH_BIN" --profile "$DSH_PROFILE" --dump-default-config >/dev/null
  for spec in "${DEFAULT_PLUGINS[@]}"; do
    if install_one_plugin "$spec"; then
      info "OK $spec"
    else
      warn "FAILED $spec"
      PLUGIN_FAILED+=("$spec")
    fi
  done
  info "installed bundles in $DSH_HOME/profiles/$DSH_PROFILE:"
  if [[ -f "$DSH_HOME/profiles/$DSH_PROFILE/package.json" ]]; then
    python3 - "$DSH_HOME/profiles/$DSH_PROFILE/package.json" <<'PY' | sed 's/^/      /'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
bundles = (data.get("dsh") or {}).get("profile") or {}
print("bundles:", ", ".join(bundles.get("bundles") or []) or "(none)")
deps = data.get("dependencies") or {}
for name, ver in sorted(deps.items()):
    print(f"{name}@{ver}")
PY
  fi
  if ((${#PLUGIN_FAILED[@]} > 0)); then
    warn "plugin install failures: ${PLUGIN_FAILED[*]}"
    if [[ "$DSH_PLUGINS_STRICT" == "1" ]]; then
      die "DSH_PLUGINS_STRICT=1 and some plugins failed"
    fi
  fi
fi

log "Step 7/9: write service env + unit"
CMD=(
  "$DSH_BIN" web
  --patch "$WEBSERVER_PATCH"
  --patch "$LLM_PATCH"
  --patch "$AUTH_PATCH"
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
DSH_AUTH_TOKEN=$DSH_AUTH_TOKEN
PATH=$HOME/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
chmod 600 "$ENV_FILE"
info "wrote $ENV_FILE (mode 600)"

EXEC_START="$DSH_BIN web --patch $WEBSERVER_PATCH --patch $LLM_PATCH --patch $AUTH_PATCH --no-open --port $DSH_PORT --trusted-host $DSH_TRUSTED_HOST"
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

log "Step 8/9: summary"
info "listen=0.0.0.0:${DSH_PORT}"
info "LLM=$DSH_LLM_BASE_URL model=$DSH_MODEL"
info "tokens: context=$DSH_CONTEXT_WINDOW max=$DSH_MAX_TOKENS"
info "trusted-host=$DSH_TRUSTED_HOST"
info "auth-gate token mode (DSH_AUTH_TOKEN length=${#DSH_AUTH_TOKEN})"
info "save this login token: $DSH_AUTH_TOKEN"
warn "Settings→Models still loopback-only; model comes from overlay"
warn "open URL with dsh ?token= once (auth-gate can bridge it), then use login token/password"

start_foreground() {
  log "Step 9/9: start dsh in foreground (DSH_FOREGROUND=1)"
  cd "$DSH_WORKSPACE"
  exec "${CMD[@]}"
}

print_token_lines() {
  info "startup URLs / tokens from logs:"
  "$@" | grep -E 'dsh web:|\?token=|auth' | sed 's/^/      /' || warn "no token line yet"
}

start_systemd() {
  local unit_dst="/etc/systemd/system/${DSH_SERVICE_NAME}.service"
  log "Step 9/9: install and start systemd service ${DSH_SERVICE_NAME}"
  cp "$UNIT_FILE" "$unit_dst"
  systemctl daemon-reload
  systemctl enable --now "$DSH_SERVICE_NAME"
  # Restart even if already running so new plugins/patches load.
  systemctl restart "$DSH_SERVICE_NAME"
  sleep 3
  systemctl --no-pager --full status "$DSH_SERVICE_NAME" || true
  info "logs: journalctl -u $DSH_SERVICE_NAME -f"
  info "stop: systemctl stop $DSH_SERVICE_NAME"
  print_token_lines journalctl -u "$DSH_SERVICE_NAME" -n 120 --no-pager
  info "auth shared token: $DSH_AUTH_TOKEN"
}

start_nohup() {
  log "Step 9/9: start with nohup"
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    warn "stopping old pid=$(cat "$PID_FILE")"
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    sleep 2
  fi
  cd "$DSH_WORKSPACE"
  export DSH_HOME DSH_LLM_BASE_URL DSH_MODEL DSH_LLM_API_KEY DSH_TRUSTED_HOST DSH_AUTH_TOKEN
  export PATH="$HOME/.npm-global/bin:$PATH"
  : >"$LOG_FILE"
  nohup "${CMD[@]}" >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 3
  if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    info "started pid=$(cat "$PID_FILE") log=$LOG_FILE"
    print_token_lines cat "$LOG_FILE"
    info "auth shared token: $DSH_AUTH_TOKEN"
  else
    die "process exited; see $LOG_FILE"
  fi
}

if [[ "$DSH_FOREGROUND" == "1" ]]; then
  start_foreground
fi

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    start_systemd
  elif sudo -n true 2>/dev/null; then
    log "Step 9/9: install systemd unit with sudo"
    sudo cp "$UNIT_FILE" "/etc/systemd/system/${DSH_SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$DSH_SERVICE_NAME"
    sudo systemctl restart "$DSH_SERVICE_NAME"
    sleep 3
    sudo systemctl --no-pager --full status "$DSH_SERVICE_NAME" || true
    print_token_lines sudo journalctl -u "$DSH_SERVICE_NAME" -n 120 --no-pager
    info "auth shared token: $DSH_AUTH_TOKEN"
  else
    warn "no root/sudo for systemd; using nohup"
    start_nohup
  fi
else
  warn "systemd unavailable; using nohup"
  start_nohup
fi
