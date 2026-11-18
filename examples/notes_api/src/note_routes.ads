--  The routes of notes_api: each user's notes in Postgres, behind tokens that another service signs.
--
--     GET    /api/notes          the caller's notes, newest first
--     POST   /api/notes          {"text": ...}   201
--     GET    /api/notes/:id      one
--     DELETE /api/notes/:id      204
--
--  Every route needs "Authorization: Bearer <token>": an EdDSA, ES256 or RS256 token whose key is in the
--  issuer's JWKS, with iss the issuer, aud "notes" and sub the user. Errors are {"error": "..."}.
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Note_Routes is

   --  Issuer: the issuer's URL, as its tokens name it; its JWKS is Issuer & "/.well-known/jwks.json".
   --  Database: a libpq URL. Applies the schema's migrations and fetches the issuer's keys (when the issuer is
   --  not up yet, they are fetched with the first token).
   procedure Start (Issuer, Database : String);

   --  Worker hooks: a Postgres connection per worker, its statements prepared.
   procedure Open_Connection (Worker : Worker_Id);
   procedure Close_Connection (Worker : Worker_Id);

   procedure List (Request : Http_Request; Response : in out Http_Response);
   procedure Create (Request : Http_Request; Response : in out Http_Response);
   procedure Show (Request : Http_Request; Response : in out Http_Response);
   procedure Remove (Request : Http_Request; Response : in out Http_Response);

   --  For /readyz: whether this worker's connection is up.
   function Database_Ready (Request : Http_Request) return Boolean;

end Note_Routes;
