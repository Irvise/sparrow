# sparrow_crypto

Cryptography and TLS for web applications, bound to the system's OpenSSL (3.0 or later). Nothing is
implemented in Ada: every primitive is libcrypto's, TLS is libssl's, so the operating system patches them.
A program built against an older OpenSSL refuses to start and says what to update.

```toml
[[depends-on]]
sparrow_crypto = "~1.0.0"
```

Keys, digests, signatures and ciphertexts are bytes (`String`), indexed from 1.

## Packages

| Package | What it does |
|---|---|
| `Sparrow.Crypto` | `Digest_Algorithm` (SHA-256/384/512, SHA3-256, BLAKE2b-512; SHA-1 for legacy protocols only), `Constant_Time_Equal`, `To_Hex` |
| `.Hashes` | `Hash (Sha256, Data)` |
| `.Macs` | HMAC over any digest; prepared `Hmac_Key` for repeated use |
| `.Key_Derivation` | PBKDF2, HKDF, scrypt, Argon2id |
| `.Passwords` | Stored passwords: Argon2id (scrypt before OpenSSL 3.2) in PHC strings, `Hash`, `Verify`, `Needs_Rehash` |
| `.Ciphers` | AES-256-GCM and ChaCha20-Poly1305 (`Seal`, `Open`) |
| `.Signatures` | Ed25519: key pairs, sign, verify |
| `.Public_Keys` | RSA (RS256), ECDSA P-256 (ES256) and Ed25519 keys from JWK parts or PEM; verify and sign as JWS does |
| `.Random` | Random bytes and URL-safe tokens |
| `Sparrow.Tls` | TLS 1.2 and 1.3 on a connected socket, server or client side |

## Passwords

```ada
Salt : Passwords.Salt_Bytes;
...
Random.Fill (Salt);
Stored := Passwords.Hash (Password, Salt);          --  "$argon2id$v=19$m=19456,t=2,p=1$..."
...
if Passwords.Verify (Attempt, Stored) then ...
```

Argon2id at OWASP's minimum cost (19 MiB, 2 passes) by default. It takes tens of milliseconds, so call it
on a worker, never on a reactor. `Verify` refuses stored hashes that ask for more than `Max_Memory`, so a
planted hash cannot exhaust memory.

Argon2id arrived in OpenSSL 3.2. On 3.0 and 3.1 (Ubuntu 24.04, Debian 12, RHEL 9), `Hash` writes scrypt
instead: `$scrypt$ln=15,r=8,p=3$...`, 32 MiB, one of OWASP's settings.
- `Verify` reads both formats.
- After an upgrade to 3.2, `Needs_Rehash` is true for scrypt hashes, so each one becomes Argon2id at the
  user's next login.
- Moving the other way does not work. An Argon2id hash can't be checked without Argon2id, so `Verify`
  raises `Crypto_Error` for one instead of answering `False`.
- `Key_Derivation.Argon2_Available` says which case a program is in.

## Authenticated encryption

```ada
Random.Fill (Nonce);
Sealed := Ciphers.Seal (Ciphers.Aes_256_Gcm, Key, Nonce, Plain, Associated => "v1");
...
Ciphers.Open (Ciphers.Aes_256_Gcm, Key, Nonce, Sealed, Plain_Out, Last, Valid, Associated => "v1");
```

Never repeat a nonce under one key. With random nonces, rotate the key before about 2³² messages.

## TLS

```ada
Tls.Open_Server (Server, "cert.pem", "key.pem");     --  then Sparrow.Http.Servers.Run (..., Security => ...)
Tls.Open_Client (Trust);                             --  the system's trust store; or Trust_File => "ca.pem"
Tls.Start_Client (Session, Trust, Socket, "db.example.com");
Tls.Handshake (Session, Result);
```

Clients check the certificate chain and the host name. Calls are non-blocking and return `Want_Read` or
`Want_Write` when they need the socket.

A server context offers HTTP/2 and HTTP/1.1 by ALPN (`Offer_Http_2 => False` offers neither, and clients
stay on HTTP/1.1); `Negotiated_Protocol (Session)` says which one the client chose.

MIT licensed.
