#!/usr/bin/env bash
# Starts a throwaway PostgreSQL 17 with TLS and SCRAM on localhost:15432 (podman or docker), for postgres_tests.
# Stop it with: podman rm -f sparrow-postgres-test
set -euo pipefail
cd "$(dirname "$0")"
./make_cert.sh
engine=$(command -v podman || command -v docker)
"$engine" rm -f sparrow-postgres-test >/dev/null 2>&1 || true
"$engine" run -d --name sparrow-postgres-test -p 127.0.0.1:15432:5432 \
  -e POSTGRES_PASSWORD='sparrow pässword' -e POSTGRES_DB=sparrow \
  -v "$PWD/data:/certs:ro,Z" --entrypoint sh docker.io/library/postgres:17-alpine -c \
  'cp /certs/cert.pem /certs/key.pem /tmp/ && chown postgres /tmp/*.pem && chmod 600 /tmp/key.pem &&
   exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/cert.pem -c ssl_key_file=/tmp/key.pem' >/dev/null
for _ in $(seq 60); do
  "$engine" exec sparrow-postgres-test pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && exit 0
  sleep 0.5
done
echo "postgres did not start" >&2; exit 1
