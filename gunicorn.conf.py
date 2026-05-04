# gunicorn.conf.py — production configuration for C64U_Weather
#
# Run with:
#   gunicorn --config gunicorn.conf.py server:application

import os

bind = f"0.0.0.0:{os.environ.get('PORT', '8888')}"
chdir = "/app"     # explicit chdir so gunicorn doesn't try the user home dir

# 2 sync workers: the app is mostly network-bound (Buienradar upstream).
# The radar cache is per-worker — that's fine; each worker fetches
# independently every 15 minutes at most.
workers = 2
worker_class = "sync"

# Radar frame load (12-frame GIF + Koala conversion) can take ~15 s.
timeout = 30
keepalive = 5

# Write heartbeat files to shared memory instead of /tmp so the container
# can run with a read-only root filesystem.
worker_tmp_dir = "/dev/shm"

# Log to stdout/stderr so Docker / container orchestrators pick them up.
accesslog = "-"
errorlog = "-"
loglevel = "info"
access_log_format = '%(h)s "%(r)s" %(s)s %(b)s %(D)sµs'

# Security
limit_request_line = 1024       # C64 requests are tiny; reject oversized lines
limit_request_fields = 20
limit_request_field_size = 512
forwarded_allow_ips = "*"       # trust X-Forwarded-For behind a reverse proxy
