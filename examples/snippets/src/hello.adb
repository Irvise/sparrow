with Hello_Pages;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;

procedure Hello is
   Routes : Router (Capacity => 8);
begin
   Add (Routes, Get, "/hello/:name", Hello_Pages.Greet'Access);
   Servers.Run (Servers.From_Environment, Routes);   --  until Ctrl-C
end Hello;
