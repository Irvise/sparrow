#!/usr/bin/env bash
# Makes data/cert.pem and data/key.pem, a self-signed certificate for localhost, unless they exist. Used by the
# TLS tests and by the PostgreSQL test server.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p data
[ -f data/cert.pem ] && exit 0
# Git Bash on Windows would rewrite "/CN=localhost" as a path.
MSYS2_ARG_CONV_EXCL='*' openssl req -x509 -newkey rsa:2048 -nodes -keyout data/key.pem -out data/cert.pem \
  -days 3650 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
