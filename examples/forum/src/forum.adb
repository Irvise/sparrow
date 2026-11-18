--  A small forum: register, log in, start threads and reply. Sessions live in sealed cookies (or Valkey), every
--  form carries a CSRF token, passwords are stored as Argon2id hashes, and open pages hear of new posts over
--  Server-Sent Events.
--
--     cd examples && bin/forum           then open http://localhost:8080/
--
--  DATABASE names the SQLite file (default forum.db). SESSION_SECRET (32 bytes or more) keeps sessions valid
--  across restarts; while changing it, SESSION_SECRET_PREVIOUS keeps the old sessions valid too. Logging in
--  and registering are rate limited per client. VALKEY_URL (valkey://:password@host:6379) keeps sessions and
--  those limits in Valkey, shared by every forum server. PORT and the rest as for every Sparrow server.
with Example_Tls;
with Forum_Pages;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Limits;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.Http.Static;
with Sparrow.IO.Process;
with Sparrow.Valkey.Limits;

procedure Forum is
   Routes   : Router (Capacity => 12);
   Shared   : constant String := Sparrow.IO.Process.Environment ("VALKEY_URL", Default => "");
   --  Five tries at once per client, then one every ten seconds: password guessing gets slow. With VALKEY_URL,
   --  every server counts in the same buckets; otherwise each in its own memory.
   Attempts : constant Limits.Limit :=
     Limits.Per_Client
       (Rate  => 0.1,
        Burst => 5,
        Store => (if Shared = "" then null else Sparrow.Valkey.Limits.Buckets (Shared, Name => "attempts")));
begin
   Forum_Pages.Load_Views ("forum/templates");

   Add (Routes, Get, "/", Forum_Pages.Home'Access);
   Add (Routes, Get, "/threads/:id", Forum_Pages.Show_Thread'Access);
   Add (Routes, Post, "/threads", Forum_Pages.New_Thread'Access);
   Add (Routes, Post, "/threads/:id/replies", Forum_Pages.Reply'Access);
   Add (Routes, Get, "/register", Forum_Pages.Register_Form'Access);
   Add (Routes, Post, "/register", Limits.Wrap (Attempts, Forum_Pages.Register'Access));
   Add (Routes, Get, "/login", Forum_Pages.Login_Form'Access);
   Add (Routes, Post, "/login", Limits.Wrap (Attempts, Forum_Pages.Login'Access));
   Add (Routes, Post, "/logout", Forum_Pages.Logout'Access);
   Add (Routes, Get, "/events", Forum_Pages.Events'Access, On_Reactor);
   Add (Routes, Get, "/static/*file", Static.Folder ("forum/public", Max_Age => 3600));

   Sparrow.Http.Servers.Run
     (Sparrow.Http.Servers.From_Environment, Routes,
      Hooks    => (On_Start => Forum_Pages.Open_Connection'Access, On_Stop => Forum_Pages.Close_Connection'Access),
      Security => Example_Tls.Security);
end Forum;
