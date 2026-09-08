FROM node:22-bookworm-slim

ARG DSH_VERSION=0.1.0-rc.7
ARG DSH_LLM_BASE_URL=
ARG DSH_MODEL=

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    python3 \
    python3-yaml \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
  && npm cache clean --force

COPY docker/webserver.cordis.yml /opt/dsh/webserver.cordis.yml
COPY docker/entrypoint.sh /opt/dsh/entrypoint.sh

RUN chmod +x /opt/dsh/entrypoint.sh \
  && mkdir -p /data/dsh /workspace \
  && chown -R node:node /data/dsh /workspace /opt/dsh

ENV DSH_HOME=/data/dsh \
    DSH_LLM_BASE_URL=${DSH_LLM_BASE_URL} \
    DSH_MODEL=${DSH_MODEL}

USER node
WORKDIR /workspace
EXPOSE 3080

ENTRYPOINT ["/opt/dsh/entrypoint.sh"]
