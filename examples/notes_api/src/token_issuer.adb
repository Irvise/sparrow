--  A token issuer for notes_api: it signs tokens with an Ed25519 key and publishes the public half as a JWKS, as
--  an identity provider would. Anyone may ask for a token under any name: it stands in for a real login, so
--  that notes_api can be tried without one.
--
--     cd examples && PORT=8081 bin/token_issuer
--     curl -X POST localhost:8081/token -H 'Content-Type: application/json' -d '{"user": "ada"}'
--     curl localhost:8081/.well-known/jwks.json
--
--  The key is drawn at start-up, so restarting the issuer rotates it: tokens signed before stop verifying,
--  and notes_api fetches the new key the first time it sees a token naming it. ISSUER_URL is the issuer's
--  name in its tokens (default http://localhost:8081); notes_api must be given the same.
with Example_Tls;
with Issuer_Routes;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;

procedure Token_Issuer is
   Routes : Router (Capacity => 2);
begin
   Issuer_Routes.Start;
   Add (Routes, Get, "/.well-known/jwks.json", Issuer_Routes.Key_Set'Access, On_Reactor);
   Add (Routes, Post, "/token", Issuer_Routes.Token'Access);
   Sparrow.Http.Servers.Run (Sparrow.Http.Servers.From_Environment, Routes, Security => Example_Tls.Security);
end Token_Issuer;
