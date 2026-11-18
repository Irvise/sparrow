# Writes src/jwt_vectors.ads: test keys, a JWKS and tokens signed by another implementation (Python cryptography).
# Run from tests/: python3 jwt_vectors.py && mv jwt_vectors.ads src/
import base64, json
from cryptography.hazmat.primitives.asymmetric import rsa, ec, ed25519, padding, utils
from cryptography.hazmat.primitives import hashes, serialization

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def num(n): return n.to_bytes((n.bit_length() + 7) // 8, 'big')

rsa_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ec_key = ec.generate_private_key(ec.SECP256R1())
ed_key = ed25519.Ed25519PrivateKey.generate()
small_rsa = rsa.generate_private_key(public_exponent=65537, key_size=1024)

rp = rsa_key.public_key().public_numbers()
ep = ec_key.public_key().public_numbers()
ed_raw = ed_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
sp = small_rsa.public_key().public_numbers()

jwks = {"keys": [
  {"kty": "RSA", "kid": "rsa1", "use": "sig", "alg": "RS256", "n": b64(num(rp.n)), "e": b64(num(rp.e))},
  {"kty": "EC", "kid": "ec1", "crv": "P-256", "x": b64(ep.x.to_bytes(32, 'big')), "y": b64(ep.y.to_bytes(32, 'big'))},
  {"kty": "OKP", "kid": "ed1", "crv": "Ed25519", "x": b64(ed_raw)},
  {"kty": "RSA", "kid": "enc1", "use": "enc", "n": b64(num(rp.n)), "e": b64(num(rp.e))},
  {"kty": "RSA", "kid": "small", "n": b64(num(sp.n)), "e": b64(num(sp.e))},
  {"kty": "oct", "kid": "secret", "k": "c2VjcmV0"},
]}

claims = {"sub": "42", "iss": "https://issuer.test", "aud": "client", "exp": 4102444800, "iat": 1700000000, "nonce": "n1"}

def token(alg, kid, sign):
    head = b64(json.dumps({"alg": alg, "kid": kid, "typ": "JWT"}, separators=(',', ':')).encode())
    body = b64(json.dumps(claims, separators=(',', ':')).encode())
    signing = (head + '.' + body).encode()
    return head + '.' + body + '.' + b64(sign(signing))

def es(data):
    r, s = utils.decode_dss_signature(ec_key.sign(data, ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, 'big') + s.to_bytes(32, 'big')

tokens = {
  "Rs256_Token": token("RS256", "rsa1", lambda d: rsa_key.sign(d, padding.PKCS1v15(), hashes.SHA256())),
  "Es256_Token": token("ES256", "ec1", es),
  "Eddsa_Token": token("EdDSA", "ed1", ed_key.sign),
  "Small_Rsa_Token": token("RS256", "small", lambda d: small_rsa.sign(d, padding.PKCS1v15(), hashes.SHA256())),
  "Wrong_Kid_Token": token("RS256", "ec1", lambda d: rsa_key.sign(d, padding.PKCS1v15(), hashes.SHA256())),
}

def pem_private(k): return k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
def pem_public(k): return k.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()

def ada(s):
    parts = []
    for line in s.split('\n'):
        parts.append(line)
    out = []
    for i, line in enumerate(parts):
        piece = '"' + line.replace('"', '""') + '"'
        if i < len(parts) - 1:
            piece += ' & ASCII.LF'
        out.append(piece)
    return '\n     & '.join(out)

def chunks(s, width=70):
    return '\n     & '.join('"' + s[i:i+width].replace('"', '""') + '"' for i in range(0, len(s), width))

lines = ["--  Keys, a JWKS and tokens made with Python's cryptography package by tests/jwt_vectors.py, for checking",
         "--  Sparrow's signatures against another implementation. Test keys only; run it again to make new ones.",
         "package Jwt_Vectors is", ""]
lines.append("   Jwks : constant String :=\n     " + chunks(json.dumps(jwks, separators=(',', ':'))) + ";\n")
for name, value in tokens.items():
    lines.append(f"   {name} : constant String :=\n     " + chunks(value) + ";\n")
lines.append("   Rsa_Private_Pem : constant String :=\n     " + ada(pem_private(rsa_key)) + ";\n")
lines.append("   Ec_Private_Pem : constant String :=\n     " + ada(pem_private(ec_key)) + ";\n")
lines.append("   Ed25519_Private_Pem : constant String :=\n     " + ada(pem_private(ed_key)) + ";\n")
lines.append("   Rsa_Public_Pem : constant String :=\n     " + ada(pem_public(rsa_key)) + ";\n")
lines.append("end Jwt_Vectors;")
open('jwt_vectors.ads', 'w').write('\n'.join(lines) + '\n')
