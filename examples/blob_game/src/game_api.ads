--  The game's one connection: a WebSocket at /api/play?name=..., whose handlers only touch the Arena's
--  protected object, so they run on the reactors.
--
--     client -> server   "x y"        where the pointer is, in world units (about 20 times a second)
--                        "respawn"    back in after being eaten
--     server -> client   the player's view, 30 times a second (see Arena.Join)
with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Websockets;

package Game_Api is

   type Players is new Sparrow.Http.Websockets.Endpoint with null record;

   overriding procedure On_Open (This : Players; Socket : Connection_Id; Request : Http_Request);
   overriding procedure On_Message
     (This : Players; Socket : Connection_Id; Message : String; Binary : Boolean; Context : Handler_Context);
   overriding procedure On_Close (This : Players; Socket : Connection_Id);

end Game_Api;
