# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: dependency builder
# ─────────────────────────────────────────────────────────────────────────────
FROM python:3.10-slim AS builder

# Copy uv from official image
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Copy lock files first for optimal layer caching
COPY pyproject.toml uv.lock ./

# Install all production dependencies into a local .venv (without cache to prevent permission issues)
RUN uv sync --frozen --no-dev --no-install-project --no-cache-dir

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: runtime image
# ─────────────────────────────────────────────────────────────────────────────
FROM python:3.10-slim AS runtime

# Non-root user for security
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

# Copy uv (needed at runtime to resolve entry-points via `uv run`)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Copy the pre-built virtual environment from builder
COPY --from=builder /app/.venv /app/.venv

# Copy application source
COPY server.py main.py pyproject.toml uv.lock ./

# Put the venv on PATH so `python` / installed scripts resolve correctly
ENV PATH="/app/.venv/bin:$PATH" \
    UV_PROJECT_ENVIRONMENT="/app/.venv" \
    UV_CACHE_DIR="/tmp/.uv-cache" \
    # Switch transport to streamable-http for container/ECS use
    MCP_TRANSPORT="streamable-http" \
    HOST="0.0.0.0" \
    PORT="8000" \
    PYTHONUNBUFFERED="1" \
    PYTHONDONTWRITEBYTECODE="1"

EXPOSE 8000

# Docker-native health check (TCP connect to the MCP port)
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "\
import socket, sys; \
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); \
s.settimeout(5); \
result = s.connect_ex(('127.0.0.1', 8000)); \
s.close(); \
sys.exit(result)"

USER appuser

# Run server in streamable-http mode (transport controlled by MCP_TRANSPORT env var)
CMD ["uv", "run", "python", "server.py"]
