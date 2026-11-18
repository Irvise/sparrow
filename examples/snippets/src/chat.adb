with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Streams;
with Sparrow.Http.Websockets;

package body Chat is

   Everyone : Streams.Group (Capacity => 1_000);

   type Room is new Websockets.Endpoint with null record;

   overriding procedure On_Open
     (This : Room; Socket : Connection_Id; Request : Http_Request);
   overriding procedure On_Message
     (This    : Room;
      Socket  : Connection_Id;
      Message : String;
      Binary  : Boolean;
      Context : Handler_Context);
   overriding procedure On_Close (This : Room; Socket : Connection_Id);

   overriding procedure On_Open
     (This : Room; Socket : Connection_Id; Request : Http_Request) is
   begin
      Streams.Add (Everyone, Socket);
   end On_Open;

   overriding procedure On_Message
     (This    : Room;
      Socket  : Connection_Id;
      Message : String;
      Binary  : Boolean;
      Context : Handler_Context) is
   begin
      if not Binary then
         --  The server has checked that a text message is UTF-8.
         Streams.Send (Everyone, UTF8_String (Message));
      end if;
   end On_Message;

   overriding procedure On_Close (This : Room; Socket : Connection_Id) is
   begin
      Streams.Remove (Everyone, Socket);
   end On_Close;

   procedure Register (Routes : in out Router) is
   begin
      --  In the browser: new WebSocket("ws://localhost:8080/chat")
      Add (Routes, Get, "/chat", Websockets.Serve (new Room));
   end Register;

end Chat;
