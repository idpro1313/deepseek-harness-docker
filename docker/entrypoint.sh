#!/bin/sh
set -eu

missing=""
for name in DSH_LLM_BASE_URL DSH_LLM_API_KEY DSH_MODEL DSH_TRUSTED_HOST; do
  eval "value=\${$name-}"
  if [ -z "$value" ]; then
    missing="$missing $name"
  fi
done

if [ -n "$missing" ]; then
  echo "dsh: missing required environment variables:$missing" >&2
  echo "dsh: copy .env.example to .env and set URL, API key, model, and trusted host" >&2
  exit 1
fi

export DSH_HOME="${DSH_HOME:-/data/dsh}"
mkdir -p "$DSH_HOME"

LLM_PATCH=/tmp/llm.cordis.yml
python3 - <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    print("dsh: python3-yaml is required to generate the model overlay", file=sys.stderr)
    sys.exit(1)

base_url = os.environ["DSH_LLM_BASE_URL"]
model = os.environ["DSH_MODEL"]

overlay = [
    {"id": "llm-deepseek", "disabled": True},
    {
        "id": "llm-pi-ai",
        "config": {
            "providers": {
                "docker-gateway": {
                    "displayName": "Docker gateway",
                    "apiKeyEnv": "DSH_LLM_API_KEY",
                    "api": "openai-completions",
                    "baseURL": base_url,
                    "models": [{"id": model, "name": model}],
                }
            }
        },
    },
    {
        "id": "agent-default-model",
        "config": {
            "provider": "docker-gateway",
            "model": model,
        },
    },
]

with open("/tmp/llm.cordis.yml", "w", encoding="utf-8") as fh:
    yaml.safe_dump(overlay, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY

exec dsh web \
  --patch /opt/dsh/webserver.cordis.yml \
  --patch "$LLM_PATCH" \
  --trusted-host "$DSH_TRUSTED_HOST"
