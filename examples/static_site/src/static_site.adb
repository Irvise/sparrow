--  A static web server: every file under the site folder, at its path. "/" and "/about/" are their folders'
--  index.html; "/about" redirects to "/about/".
--
--     cd examples && bin/static_site         then open http://localhost:8080/
--
--  PORT, HOST, REACTORS and WORKERS configure the server, SITE_ROOT the folder.
with Example_Tls;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.Http.Static;
with Sparrow.IO.Process;

procedure Static_Site is
   Site_Root : constant String := Sparrow.IO.Process.Environment ("SITE_ROOT", Default => "static_site/public");
   Routes    : Sparrow.Http.Routers.Router (Capacity => 1);
begin
   Sparrow.Http.Routers.Add (Routes, Get, "/*file", Static.Folder (Site_Root, Max_Age => 60));
   Sparrow.Http.Servers.Run (Sparrow.Http.Servers.From_Environment, Routes, Security => Example_Tls.Security);
end Static_Site;
