# sparrow_jwt

JSON Web Tokens (RFC 7519): HS256 with a shared secret, and RS256, ES256 and EdDSA with public keys. Signs any
JSON claims. On the way back it checks the signature, `alg`, `exp` and `nbf` before any claim is read. The
HS256 path and the claim checks are proved free of run-time errors (SPARK silver): no token, however
malformed, makes `Verify` raise.

```toml
[[depends-on]]
sparrow_jwt = "~0.1.0-dev"
```

```ada
Signing : constant Jwt.Key := Jwt.To_Key (Secret);       --  once; Secret: 32 random bytes or more
...
Token := Jwt.Sign_Subject (Signing, Subject => "user-42", Now => Requests.Now (Request), Lifetime => 3600);
...
Jwt.Verify (Signing, Jwt.Bearer_Token (Requests.Header (Request, "Authorization")), Requests.Now (Request),
           Claims, Valid);
if Valid then
   User := Json.Value (Claims, Json.Member (Claims, Json.Root, "sub"));
end if;
```

- `Sign` takes any claims object (build it with `Sparrow.Json.Writers`); put `iat` and `exp` in it.
- `exp` is required unless `Require_Expiry => False`.

## Public keys: `Jwt.Key_Sets`

For tokens from someone else (an identity provider, another service), signed with RS256, ES256 or EdDSA.
The keys usually come as a JWKS, the JSON a provider publishes at its `jwks_uri`:

```ada
Keys : constant Key_Sets.Key_Set := Key_Sets.Parse_Jwks (Client.Content (Answer));   --  fetched at start-up
...
Key_Sets.Verify (Keys, Jwt.Bearer_Token (Requests.Header (Request, "Authorization")), Requests.Now (Request),
                 Claims, Valid);
```

- The token's `kid` picks the key, and the key decides the algorithm: an RSA key checks only RS256, so a
  token cannot ask for a weaker check (no `none`, no HS256 signed with the public key).
- `Parse_Jwks` keeps the keys that sign: RSA of 2048 bits or more, EC P-256, Ed25519. It leaves out
  encryption keys, shared secrets and anything malformed.
- Check the claims your issuer promises yourself: `iss`, `aud`, and any nonce.
- When a token names a `kid` the set lacks (`Key_Id_Of`), the issuer has rotated its keys: fetch the JWKS
  again, at most every minute or so.
- `Add` takes single keys: `Crypto.Public_Keys.From_Pem`, or `Rsa_Key`, `Ec_P256_Key`, `Ed25519_Key`.
- `Key_Sets.Sign (Private_From_Pem (Pem), Key_Id, Claims)` issues tokens that others check with the public
  key alone.

Signing in with a third-party identity provider (OpenID Connect) is not part of the stack. Put a proxy such
as oauth2-proxy in front of the application, or write the flow with these pieces. The ID token's checks
are then `Key_Sets.Verify` plus `iss`, `aud` (and `azp` when there are several audiences) and the `nonce`
you sent.

MIT licensed.
