--  A JSON REST API over SQLite, with bearer tokens for writes (see Bookmark_Api for the routes).
--
--     cd examples && bin/rest_service
--     curl localhost:8080/api/bookmarks
--     curl -X POST localhost:8080/api/bookmarks -H "Authorization: Bearer $TOKEN" \
--          -H 'Content-Type: application/json' -d '{"url": "https://ada-lang.io", "title": "Ada"}'
--
--  The token is printed at start-up. API_SECRET sets the signing secret (otherwise a random one, so tokens
--  last until a restart); DATABASE the SQLite file; PORT and the rest as for every Sparrow server.
--
--  /healthz, /readyz (the database answers) and /metrics are served too. With OTEL_EXPORTER_OTLP_ENDPOINT set
--  (http://localhost:4318 for a local collector), traces go to it.
with Bookmark_Api;
with Example_Tls;
with Sparrow.Crypto.Random;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Health;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.IO.Process;
with Sparrow.Logs;
with Sparrow.Open_Telemetry;

procedure Rest_Service is
   Routes  : Router (Capacity => 8);
   Secret  : String (1 .. 32);
   Tracing : Boolean;
begin
   if Sparrow.IO.Process.Environment ("API_SECRET")'Length >= 32 then
      Bookmark_Api.Set_Secret (Sparrow.IO.Process.Environment ("API_SECRET"));
   else
      Sparrow.Crypto.Random.Fill (Secret);
      Bookmark_Api.Set_Secret (Secret);
   end if;

   Sparrow.Http.Health.Add (Routes, Check => Bookmark_Api.Database_Ready'Access);
   Add (Routes, Get, "/api/bookmarks", Bookmark_Api.List'Access);
   Add (Routes, Post, "/api/bookmarks", Bookmark_Api.Create'Access);
   Add (Routes, Get, "/api/bookmarks/:id", Bookmark_Api.Show'Access);
   Add (Routes, Put, "/api/bookmarks/:id", Bookmark_Api.Replace'Access);
   Add (Routes, Delete, "/api/bookmarks/:id", Bookmark_Api.Remove'Access);

   Sparrow.Logs.Info ("a token for writes", Sparrow.Logs.Field ("token", Bookmark_Api.Demo_Token ("demo")));
   Sparrow.Open_Telemetry.Start_From_Environment ("bookmarks", Tracing);
   Sparrow.Http.Servers.Run
     (Sparrow.Http.Servers.From_Environment, Routes,
      Hooks    => (On_Start => Bookmark_Api.Open_Connection'Access, On_Stop => Bookmark_Api.Close_Connection'Access),
      Security => Example_Tls.Security);
   Sparrow.Open_Telemetry.Stop;
end Rest_Service;
