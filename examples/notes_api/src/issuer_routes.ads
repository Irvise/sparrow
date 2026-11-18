--  The routes of token_issuer: its JWKS and its tokens.
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Issuer_Routes is

   --  Draw the signing key; log its name.
   procedure Start;

   --  GET /.well-known/jwks.json: the public key, as a JWKS.
   procedure Key_Set (Request : Http_Request; Response : in out Http_Response);

   --  POST /token {"user": "ada"}: {"token": ..., "expires_in": 3600}.
   procedure Token (Request : Http_Request; Response : in out Http_Response);

end Issuer_Routes;
