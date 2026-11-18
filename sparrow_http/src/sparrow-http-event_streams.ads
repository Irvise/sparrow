--  Server-Sent Events (text/event-stream): a response that stays open and carries events, which browsers read
--  with EventSource (and htmx with its sse extension). One way only, server to client; it reconnects by itself.
--
--     procedure Updates (Request : Http_Request; Response : in out Http_Response) is
--     begin
--        Event_Streams.Begin_Events (Response);
--        Streams.Add (Watchers, Requests.Connection (Request));
--     end Updates;
--
--     Event_Streams.Send (Watchers, "{""price"": 12}", Name => "price");    --  later, from any task
--
--  A comment line goes out when the stream has been quiet for half the server's Idle_Timeout, so proxies keep
--  it open and a client that has gone is noticed.
with Sparrow.Http.Responses;
with Sparrow.Http.Streams;

package Sparrow.Http.Event_Streams is

   --  Make Response an event stream. Retry (milliseconds, 0 for the browser's default) is how long a client
   --  waits before reconnecting.
   procedure Begin_Events (Response : in out Responses.Response; Retry : Natural := 0);

   --  Data as one event: each of its lines a data line, with an event name and an id when given (line breaks
   --  in those are dropped). Last-Event-ID comes back as a request header when the client reconnects.
   function Event (Data : UTF8_String; Name : String := ""; Id : String := "") return UTF8_String;

   procedure Send (Target : Connection_Id; Data : UTF8_String; Name : String := ""; Id : String := "");
   procedure Send (Audience : in out Streams.Group; Data : UTF8_String; Name : String := ""; Id : String := "");

end Sparrow.Http.Event_Streams;
