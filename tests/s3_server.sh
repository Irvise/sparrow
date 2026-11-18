#!/usr/bin/env bash
# Starts a throwaway S3-compatible store (versitygw over a directory; podman or docker) for s3_tests on
# localhost:19000, with the access key "sparrow-test", the secret "sparrow-test-secret" and the bucket "sparrow".
# Stop it with: podman rm -f sparrow-s3-test
set -euo pipefail
cd "$(dirname "$0")"
engine=$(command -v podman || command -v docker)
"$engine" rm -f sparrow-s3-test >/dev/null 2>&1 || true
"$engine" run -d --name sparrow-s3-test -p 127.0.0.1:19000:7070 \
  -e ROOT_ACCESS_KEY=sparrow-test -e ROOT_SECRET_KEY=sparrow-test-secret \
  --entrypoint sh docker.io/versity/versitygw:latest -c 'mkdir -p /tmp/s3 && exec versitygw posix /tmp/s3' >/dev/null
for _ in $(seq 60); do
  # The bucket, made with curl's own Signature V4 so that the store does not depend on the code it tests.
  if curl -sf -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" --user sparrow-test:sparrow-test-secret \
       http://127.0.0.1:19000/sparrow >/dev/null 2>&1 \
     || curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user sparrow-test:sparrow-test-secret \
          http://127.0.0.1:19000/sparrow | grep -q ListBucketResult; then
    exit 0
  fi
  sleep 0.5
done
echo "the S3 store did not start" >&2; exit 1
