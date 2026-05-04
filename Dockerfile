# ── Build stage: install Python deps into an isolated prefix ─────────────────
FROM python:3.12-slim AS builder

WORKDIR /install

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install/pkg -r requirements.txt


# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM python:3.12-slim

# Create a dedicated non-root user/group; no home directory, no shell.
RUN groupadd --system --gid 1001 c64weather \
 && useradd  --system --uid 1001 --gid c64weather \
             --no-create-home --shell /sbin/nologin c64weather

WORKDIR /app

# Point HOME at /tmp (tmpfs mount) so gunicorn can write its control socket
# there when the root filesystem is read-only.
ENV HOME=/tmp

# Copy installed packages from the build stage.
COPY --from=builder /install/pkg /usr/local

# Copy application files.
COPY server.py gunicorn.conf.py ./

# Switch to non-root before the process starts.
USER c64weather

EXPOSE 8888

# Healthcheck: hit the help endpoint; should return in < 5 s.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python3 -c \
        "import urllib.request; urllib.request.urlopen('http://localhost:8888/', timeout=4)" \
        || exit 1

# Gunicorn reads all configuration from gunicorn.conf.py.
# Pass STATION_ID / PORT as env vars via docker-compose or -e flags.
ENTRYPOINT ["gunicorn", "--config", "gunicorn.conf.py", "server:application"]
