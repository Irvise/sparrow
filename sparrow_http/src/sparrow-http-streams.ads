--  Sending to a connection after its handler has returned: the pieces of a streamed response
--  (Responses.Begin_Stream), or the messages of a WebSocket (Sparrow.Http.Websockets). Any task may send, at
--  any time; what one task sends to one connection arrives in order.
--
--     procedure Subscribe (Request : Http_Request; Response : in out Http_Response) is
--     begin
--        Event_Streams.Begin_Events (Response);
--        Streams.Add (Watchers, Requests.Connection (Request));
--     end Subscribe;
--     ...
--     Event_Streams.Send (Watchers, "price changed");   --  from anywhere
--
--  Sending is fire and forget: to a connection that has closed it does nothing. A client that falls 8 MiB
--  behind is disconnected rather than buffered without end.
package Sparrow.Http.Streams is

   --  A stream: Text as the next piece. A socket: a text message.
   procedure Send (Target : Connection_Id; Text : UTF8_String);

   --  A stream: Data as the next piece. A socket: a binary message.
   procedure Send_Bytes (Target : Connection_Id; Data : String);

   --  End a stream, or close a socket (code 1000), once what was sent before is out.
   procedure Close (Target : Connection_Id);

   --  Whether Target is still an open stream or socket. It may close the moment after: use it to forget
   --  clients, not to decide whether sending is safe (it always is).
   function Is_Open (Target : Connection_Id) return Boolean;

   ---------------------------------------------------------------------------------------------------------------
   --  Groups: the clients watching one thing (a room, a feed, a game), safe to use from any task.

   type Group (Capacity : Positive) is limited private;

   --  Added is False when the group is full.
   procedure Add (This : in out Group; Member : Connection_Id; Added : out Boolean);
   procedure Add (This : in out Group; Member : Connection_Id);   --  ignores a full group
   procedure Remove (This : in out Group; Member : Connection_Id);

   --  To every member still open; members that have closed are dropped from the group.
   procedure Send (This : in out Group; Text : UTF8_String);
   procedure Send_Bytes (This : in out Group; Data : String);

   --  The members still open (and the group forgets the rest).
   function Count (This : Group) return Natural;

private

   type Member_Array is array (Positive range <>) of Connection_Id;

   protected type Member_List (Capacity : Positive) is
      procedure Add (Member : Connection_Id; Added : out Boolean);
      procedure Remove (Member : Connection_Id);
      procedure Prune;                         --  drop the closed
      function Members return Member_Array;
   private
      Items : Member_Array (1 .. Capacity);
      Total : Natural := 0;
   end Member_List;

   type Group (Capacity : Positive) is limited record
      List : Member_List (Capacity);
   end record;

end Sparrow.Http.Streams;
