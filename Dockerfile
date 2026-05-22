# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: dependency builder
# ─────────────────────────────────────────────────────────────────────────────
FROM python:3.10-slim AS builder

# Copy uv binary
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Copy dependency files first for Docker layer caching
COPY pyproject.toml uv.lock ./

# Create virtual environment with production dependencies
RUN uv sync --frozen --no-dev --no-install-project --no-cache

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: runtime image
# ─────────────────────────────────────────────────────────────────────────────
FROM python:3.10-slim AS runtime

# Create non-root user with real home directory
# NOTE: adduser --system does NOT create the home dir for system users in Debian.
# We must create /home/appuser explicitly to prevent uv/HOME resolving to /nonexistent.
RUN addgroup --system appgroup && \
    adduser --system --ingroup appgroup --home /home/appuser appuser && \
    mkdir -p /home/appuser && \
    chown appuser:appgroup /home/appuser

WORKDIR /app

# Copy virtual environment from builder
COPY --from=builder /app/.venv /app/.venv

# Copy application source
COPY server.py main.py pyproject.toml uv.lock ./

# Create writable cache/temp directories
RUN mkdir -p /tmp/.uv-cache && \
    chmod -R 777 /tmp/.uv-cache && \
    chown -R appuser:appgroup /app

# Environment variables
ENV PATH="/app/.venv/bin:$PATH" \
    VIRTUAL_ENV="/app/.venv" \
    HOME="/home/appuser" \
    UV_CACHE_DIR="/tmp/.uv-cache" \
    UV_NO_CACHE=1 \
    MCP_TRANSPORT="streamable-http" \
    HOST="0.0.0.0" \
    PORT="8000" \
    PYTHONUNBUFFERED="1" \
    PYTHONDONTWRITEBYTECODE="1"

EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "\
import socket, sys; \
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); \
s.settimeout(5); \
result = s.connect_ex(('127.0.0.1', 8000)); \
s.close(); \
sys.exit(result)"

# Run as non-root user
USER appuser

# Start application directly from venv
CMD ["python", "server.py"]