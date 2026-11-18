--  A notes API whose users sign in elsewhere: it trusts tokens signed by an issuer's keys, which it fetches
--  as a JWKS with sparrow_client (again when a token names a key it has not seen), and keeps each user's notes
--  in Postgres, the schema applied by migrations at start-up, one connection per worker.
--
--     cd ../tests && ./postgres_server.sh && cd ../examples
--     podman exec sparrow-postgres-test psql -U postgres -c 'CREATE DATABASE notes'
--     PORT=8081 bin/token_issuer &
--     DATABASE_URL='postgres://postgres:sparrow%20p%C3%A4ssword@localhost:15432/notes' bin/notes_api
--     TOKEN=$(curl -s -X POST localhost:8081/token -d '{"user": "ada"}' -H 'Content-Type: application/json' \
--             | sed 's/.*"token":"\([^"]*\)".*/\1/')
--     curl -X POST localhost:8080/api/notes -H "Authorization: Bearer $TOKEN" \
--          -H 'Content-Type: application/json' -d '{"text": "buy milk"}'
--     curl localhost:8080/api/notes -H "Authorization: Bearer $TOKEN"
--
--  ISSUER_URL names the issuer (default http://localhost:8081), DATABASE_URL the database (a libpq URL);
--  /healthz, /readyz and /metrics are served too. PORT and the rest as for every Sparrow server.
with Example_Tls;
with Note_Routes;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Health;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.IO.Process;

procedure Notes_Api is
   Routes : Router (Capacity => 8);
begin
   Note_Routes.Start
     (Issuer   => Sparrow.IO.Process.Environment ("ISSUER_URL", Default => "http://localhost:8081"),
      Database => Sparrow.IO.Process.Environment
                    ("DATABASE_URL", Default => "postgres://postgres@localhost:5432/notes"));

   Sparrow.Http.Health.Add (Routes, Check => Note_Routes.Database_Ready'Access);
   Add (Routes, Get, "/api/notes", Note_Routes.List'Access);
   Add (Routes, Post, "/api/notes", Note_Routes.Create'Access);
   Add (Routes, Get, "/api/notes/:id", Note_Routes.Show'Access);
   Add (Routes, Delete, "/api/notes/:id", Note_Routes.Remove'Access);

   Sparrow.Http.Servers.Run
     (Sparrow.Http.Servers.From_Environment, Routes,
      Hooks    => (On_Start => Note_Routes.Open_Connection'Access, On_Stop => Note_Routes.Close_Connection'Access),
      Security => Example_Tls.Security);
end Notes_Api;
