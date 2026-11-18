--  HTTP/1.1: the vocabulary shared by the parser, requests, responses, the router and the server.
--
--  What Sparrow.Http is: an HTTP/1.1 origin server with keep-alive and pipelining, over plain TCP or TLS
--  (Sparrow.Tls), with streamed responses (Streams, Event_Streams), streamed request bodies (Bodies) and
--  WebSockets (Websockets). What it is not: HTTP/2 or compression; put a proxy in front for those.
--
--  Everything a client sends is bytes (String) and stays so: a path, a header or a body becomes text only
--  through a checked conversion (Sparrow.Encoding.To_UTF8) or a parser that checks (Sparrow.Json.Parse).
with Sparrow.Times;

package Sparrow.Http with SPARK_Mode is

   type Status_Code is range 100 .. 599;

   Switching_Protocols     : constant Status_Code := 101;
   OK                      : constant Status_Code := 200;
   Created                 : constant Status_Code := 201;
   Accepted                : constant Status_Code := 202;
   No_Content              : constant Status_Code := 204;
   Partial_Content         : constant Status_Code := 206;
   Moved_Permanently       : constant Status_Code := 301;
   Found                   : constant Status_Code := 302;
   See_Other               : constant Status_Code := 303;
   Not_Modified            : constant Status_Code := 304;
   Temporary_Redirect      : constant Status_Code := 307;
   Permanent_Redirect      : constant Status_Code := 308;
   Bad_Request             : constant Status_Code := 400;
   Unauthorized            : constant Status_Code := 401;
   Forbidden               : constant Status_Code := 403;
   Not_Found               : constant Status_Code := 404;
   Method_Not_Allowed      : constant Status_Code := 405;
   Request_Timeout         : constant Status_Code := 408;
   Conflict                : constant Status_Code := 409;
   Length_Required         : constant Status_Code := 411;
   Payload_Too_Large       : constant Status_Code := 413;
   Unsupported_Media_Type  : constant Status_Code := 415;
   Range_Not_Satisfiable   : constant Status_Code := 416;
   Unprocessable_Content   : constant Status_Code := 422;
   Upgrade_Required        : constant Status_Code := 426;
   Too_Many_Requests       : constant Status_Code := 429;
   Header_Fields_Too_Large : constant Status_Code := 431;
   Internal_Server_Error   : constant Status_Code := 500;
   Not_Implemented         : constant Status_Code := 501;
   Service_Unavailable     : constant Status_Code := 503;

   --  "Not Found" for 404; "Unknown" for a code without a registered phrase.
   function Reason_Phrase (Status : Status_Code) return String
      with Post => Reason_Phrase'Result'First = 1 and then Reason_Phrase'Result'Length in 1 .. 40;

   type Method is (Get, Head, Post, Put, Patch, Delete, Options, Other);

   CRLF : constant String := ASCII.CR & ASCII.LF;

   --  Common Content-Type values.
   Text_Plain       : constant String := "text/plain; charset=utf-8";
   Text_Html        : constant String := "text/html; charset=utf-8";
   Application_Json : constant String := "application/json";

   --  The tasks handlers run on. Worker 0 is "on a reactor"; workers proper are numbered from 1, so an
   --  application can keep one database connection per worker in an array indexed by Worker_Id.
   type Worker_Count is range 0 .. 1024;
   subtype Worker_Id is Worker_Count range 1 .. Worker_Count'Last;
   Reactor_Task : constant Worker_Count := 0;

   --  One client connection, for as long as it is open: what a handler gets from Requests.Connection, to send
   --  to later from any task (Sparrow.Http.Streams). Once that connection closes, the id names nothing, even
   --  when the server reuses its place for another client.
   type Connection_Id is private;
   No_Connection : constant Connection_Id;

   --  Where a request sits in a trace: its request id, and its W3C trace context (trace id, this request's
   --  span, the caller's span), taken from the request's X-Request-Id and traceparent headers when it has
   --  valid ones and made up otherwise. Read it with Sparrow.Http.Log.
   type Trace_Context is private;
   No_Trace : constant Trace_Context;

   --  Where and when a handler runs: the task (index per-worker state with it), the wall clock read once for
   --  the request, the client's connection (to send to later, Sparrow.Http.Streams) and the request's trace
   --  (Sparrow.Http.Log). A request carries its own (Sparrow.Http.Requests.Context); WebSocket handlers,
   --  which have no request, are given one.
   type Call_Context is record
      Worker     : Worker_Count := Reactor_Task;
      Now        : Sparrow.Times.Unix_Seconds := 0;
      Connection : Connection_Id := No_Connection;
      Trace      : Trace_Context := No_Trace;
   end record;

private

   type Connection_Id is record
      Reactor    : Natural := 0;    --  0: none
      Slot       : Natural := 0;
      Generation : Natural := 0;
      Stream     : Natural := 0;    --  an HTTP/2 stream on the connection; 0: the connection itself
   end record;

   No_Connection : constant Connection_Id := (others => 0);

   subtype Request_Id_Text is String (1 .. 64);

   type Trace_Context is record
      Trace_Id   : String (1 .. 32) := [others => '0'];   --  lower-case hex; all zeros: none
      Span_Id    : String (1 .. 16) := [others => '0'];
      Parent_Id  : String (1 .. 16) := [others => '0'];   --  all zeros: the request started the trace
      Sampled    : Boolean := False;                      --  the caller's sampled flag, passed on
      Id         : Request_Id_Text := [others => ' '];
      Id_Length  : Natural range 0 .. Request_Id_Text'Length := 0;
   end record;

   No_Trace : constant Trace_Context := (others => <>);

end Sparrow.Http;
