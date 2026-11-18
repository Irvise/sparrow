# 0002 Cryptography from OpenSSL only

Status: accepted. Recorded 2026-11-18 from the project's development history and the code.

## Decision

Every cryptographic primitive and TLS comes from the system's OpenSSL (3.0 or later), through one crate,
sparrow_crypto. Sparrow implements no primitive. OpenSSL is linked the way the platform links it by default,
so operating-system updates patch every Sparrow program.

- Passwords: Argon2id in PHC strings; scrypt where OpenSSL is older than 3.2, upgraded at the next login.
- Encryption: AEAD only (AES-256-GCM, ChaCha20-Poly1305).
- SHA-1 exists only for the WebSocket handshake.

## Why

Sparrow's ancestor had its own proved SHA-256 and bcrypt. Proof of no run-time errors says nothing about side
channels or misuse. OpenSSL is audited and patched by the operating system, and offers far more.

## Consequences

- No build without OpenSSL: every crate that needs cryptography needs libcrypto.
- Proved code (Sparrow.Jwt) calls cryptography through SPARK specs whose bodies are C calls, not proved.

## Checked by

`design/check.py`: `[forbidden_libraries]` lets only sparrow_crypto link `ssl` and `crypto`; `[c_linkage]`
keeps OpenSSL bindings in that crate. Not checked: that no primitive is written in Ada elsewhere (review).
