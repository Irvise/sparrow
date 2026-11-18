#!/usr/bin/env bash
# Starts a throwaway Valkey 9 for valkey_tests (podman or docker): plain TCP on localhost:16379 and TLS on
# localhost:16380, both behind the password "sparrow pässword". Stop it with: podman rm -f sparrow-valkey-test
set -euo pipefail
cd "$(dirname "$0")"
./make_cert.sh
engine=$(command -v podman || command -v docker)
"$engine" rm -f sparrow-valkey-test >/dev/null 2>&1 || true
"$engine" run -d --name sparrow-valkey-test -p 127.0.0.1:16379:6379 -p 127.0.0.1:16380:6380 \
  -v "$PWD/data:/certs:ro,Z" --entrypoint sh docker.io/valkey/valkey:9-alpine -c \
  'cp /certs/cert.pem /certs/key.pem /tmp/ &&
   exec valkey-server --requirepass "sparrow pässword" --save "" --appendonly no \
     --tls-port 6380 --tls-cert-file /tmp/cert.pem --tls-key-file /tmp/key.pem --tls-auth-clients no' >/dev/null
for _ in $(seq 60); do
  "$engine" exec sparrow-valkey-test valkey-cli -a 'sparrow pässword' --no-auth-warning ping >/dev/null 2>&1 && exit 0
  sleep 0.5
done
echo "valkey did not start" >&2; exit 1
