#!/usr/bin/env bash
# Makes cert.pem and key.pem here, a self-signed certificate for localhost, unless they exist. Then any example
# serves HTTPS, and HTTP/2 to browsers:
#
#   ./make_cert.sh && CERT_FILE=cert.pem KEY_FILE=key.pem PORT=8443 bin/forum     then open https://localhost:8443/
#
# Browsers warn about a self-signed certificate once; accept it for localhost.
set -euo pipefail
cd "$(dirname "$0")"
[ -f cert.pem ] && exit 0
# Git Bash on Windows would rewrite "/CN=localhost" as a path.
MSYS2_ARG_CONV_EXCL='*' openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout key.pem \
  -out cert.pem -days 825 -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1 >/dev/null 2>&1
echo "made cert.pem and key.pem"
