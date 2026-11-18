--  A server to poke at by hand or load-test: plain HTTP on PORT (default 18476), HTTPS on PORT when TLS=1.
--  Stops on Ctrl-C or SIGTERM, answering what is in flight first.
with Http_Test_Handlers; use Http_Test_Handlers;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.IO.Process;
with Sparrow.Tls;

procedure Demo_Server is
   Routes   : Sparrow.Http.Routers.Router (8);
   Security : aliased Sparrow.Tls.Context;
   Secure   : constant Boolean := Sparrow.IO.Process.Environment ("TLS") = "1";
begin
   Sparrow.Http.Routers.Add (Routes, Get, "/hello", Hello'Access, Sparrow.Http.Routers.On_Reactor);
   Sparrow.Http.Routers.Add (Routes, Get, "/who/:name", Who'Access);
   Sparrow.Http.Routers.Add (Routes, Post, "/echo", Echo'Access);
   if Secure then
      Sparrow.Tls.Open_Server (Security, "data/cert.pem", "data/key.pem");
   end if;
   Sparrow.Http.Servers.Run
     (Sparrow.Http.Servers.From_Environment ((Port => 18_476, others => <>)), Routes,
      Security => (if Secure then Security'Access else null));
   Sparrow.IO.Process.Log ("demo_server: stopped");
end Demo_Server;
