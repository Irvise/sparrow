--  WebSockets (RFC 6455): a route that upgrades its connection, then messages both ways until either side
--  closes. The server does the framing, answers pings, pings quiet clients and closes the silent ones.
--
--     type Chat_Room is new Websockets.Endpoint with null record;
--     overriding procedure On_Open (This : Chat_Room; Socket : Connection_Id; Request : Http_Request);
--     overriding procedure On_Message
--       (This : Chat_Room; Socket : Connection_Id; Message : String; Binary : Boolean; Context : Handler_Context);
--     overriding procedure On_Close (This : Chat_Room; Socket : Connection_Id);
--     ...
--     Routers.Add (Routes, Get, "/chat", Websockets.Serve (new Chat_Room));
--
--  Send with Sparrow.Http.Streams: Send (text), Send_Bytes (binary), Close, and Groups for broadcasting.
--
--  A text Message has been checked to be UTF-8; a message is at most Max_Message bytes (larger ones close the
--  socket with 1009). Messages of one socket reach On_Message one at a time, in order; messages of different
--  sockets may reach it at the same time, on different tasks. Run chooses where (On_Reactor only for handlers
--  that never block). An exception that leaves On_Message closes the socket with 1011.
--
--  Browsers let any page open a WebSocket to any site, with the user's cookies: the Origin check is what stops
--  another site's page from talking to yours as your user. By default only pages from the same host may
--  connect; Serve's Allowed_Origins lists others ("https://app.example https://admin.example"), or "*" for any.
--  Clients that send no Origin (not browsers) are let in.
with Sparrow.Buffers;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Sparrow.Http.Websockets is

   --  What an application does with its sockets. One object serves every socket of its route.
   type Endpoint is abstract tagged limited null record;

   procedure On_Message
     (This : Endpoint; Socket : Connection_Id; Message : String; Binary : Boolean; Context : Handler_Context)
   is abstract;
   procedure On_Open (This : Endpoint; Socket : Connection_Id; Request : Http_Request) is null;
   procedure On_Close (This : Endpoint; Socket : Connection_Id) is null;

   type Endpoint_Access is access Endpoint'Class;

   --  The route that upgrades its connection (or answers 400, 403, 426), then calls On_Open: add it for GET.
   type Upgrade is new Route_Handler with private;
   overriding procedure Handle (This : Upgrade; Request : Http_Request; Response : in out Http_Response);

   function Serve
     (Handlers        : not null Endpoint_Access;
      Run             : Placement := On_Worker;
      Max_Message     : Positive := 1_048_576;
      Allowed_Origins : String := "") return Upgrade;

   --  Sec-WebSocket-Accept for a client's Sec-WebSocket-Key.
   function Accept_Key (Key : String) return String;

   --  Whether a browser page from Origin may connect to Host under Allowed (as Endpoint's Allowed_Origins).
   function Origin_Allowed (Origin, Host, Allowed : String) return Boolean;

private

   type Upgrade is new Route_Handler with record
      Handlers        : Endpoint_Access;
      Number          : Positive := 1;                 --  its place among Sparrow.Http.Delivery's endpoints
      Allowed_Origins : Sparrow.Buffers.String_Access;
   end record;

end Sparrow.Http.Websockets;
