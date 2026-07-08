ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install system packages and development tools
RUN apk add --no-cache \
    bash \
    curl \
    nano \
    nodejs \
    npm \
    python3 \
    py3-pip \
    py3-requests \
    py3-aiohttp \
    py3-yaml \
    py3-beautifulsoup4 \
    git \
    vim \
    wget \
    jq \
    tree \
    tmux \
    yq

# Keep npm's cache out of the persistent /data volume at runtime. HOME is
# pointed at /data/home for auth persistence (see run.sh), so without this
# any npm invocation defaults its cache to $HOME/.npm and that cache is
# then swept into every Home Assistant backup (see issue #103).
ENV npm_config_cache=/tmp/npm-cache

# Install Claude Code CLI via npm (avoids musl binary compatibility issues)
RUN npm install -g @anthropic-ai/claude-code@latest \
    && npm cache clean --force

# Install uv for running ha-mcp (Python package manager/runner)
# ha-mcp requires Python 3.13+, uv handles this automatically
RUN apk add --no-cache uv

# Create directory for Claude configuration and set working directory
RUN mkdir -p /config/claude-config
WORKDIR /config

# Copy startup script and modular scripts
COPY run.sh /run.sh
COPY scripts/ /opt/scripts/
RUN chmod +x /run.sh \
    && chmod +x /opt/scripts/*.sh

# Use exec form for better signal handling
CMD ["/run.sh"]