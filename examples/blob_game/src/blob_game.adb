--  Gobble: a multiplayer arena of blobs that eat pellets and each other. The server owns the world (Arena),
--  steps it 30 times a second and pushes each player its view over a WebSocket; browsers send where their
--  pointer is and draw what comes back.
--
--     cd examples && bin/blob_game          then open http://localhost:8080/ in a few windows
--
--  To play across a network: HOST=:: bin/blob_game.
with Arena;
with Example_Tls;
with Game_Api;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.Http.Static;
with Sparrow.Http.Websockets;

procedure Blob_Game is
   Routes : Router (Capacity => 2);
begin
   Add (Routes, Get, "/api/play",
        Websockets.Serve (new Game_Api.Players, Run => On_Reactor, Max_Message => 64), On_Reactor);
   Add (Routes, Get, "/*file", Static.Folder ("blob_game/public"));

   Arena.Start;
   Sparrow.Http.Servers.Run (Sparrow.Http.Servers.From_Environment, Routes, Security => Example_Tls.Security);
   Arena.Stop;
end Blob_Game;
