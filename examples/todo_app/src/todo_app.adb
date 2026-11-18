--  A todo list: server-rendered Mustache templates, htmx for the interactions, SQLite for storage.
--
--     cd examples && bin/todo_app           then open http://localhost:8080/
--
--  DATABASE names the SQLite file (default todos.db); PORT and the rest as for every Sparrow server.
with Example_Tls;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.Http.Static;
with Todo_Pages;

procedure Todo_App is
   Routes : Router (Capacity => 8);
begin
   Todo_Pages.Load_Views ("todo_app/templates");

   Add (Routes, Get, "/", Todo_Pages.Home'Access);
   Add (Routes, Get, "/todos", Todo_Pages.List'Access);
   Add (Routes, Post, "/todos", Todo_Pages.Add'Access);
   Add (Routes, Post, "/todos/clear", Todo_Pages.Clear_Done'Access);
   Add (Routes, Patch, "/todos/:id/toggle", Todo_Pages.Toggle'Access);
   Add (Routes, Delete, "/todos/:id", Todo_Pages.Remove'Access);
   Add (Routes, Get, "/static/*file", Static.Folder ("todo_app/public", Max_Age => 3600));

   Sparrow.Http.Servers.Run
     (Sparrow.Http.Servers.From_Environment, Routes,
      Hooks    => (On_Start => Todo_Pages.Open_Connection'Access, On_Stop => Todo_Pages.Close_Connection'Access),
      Security => Example_Tls.Security);
end Todo_App;
