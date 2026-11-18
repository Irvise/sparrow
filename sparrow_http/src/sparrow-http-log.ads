--  Logging from handlers, with every line carrying the request's id (and trace id), so one request can be
--  followed through everything it logged, its access-log line, and the services it called.
--
--     Log.Info (Request, "bookmark saved", Log.Field ("id", Id), Log.Field ("tags", Tag_Count));
--
--     2026-11-17T14:21:55.123Z INFO    bookmark saved request_id=4bf92f3577b34da6a3ce929d0e0e4736 id=7 tags=2
--
--  The server logs one line per request by itself (see Servers.Configuration.Access_Log), with the same
--  request_id, and sends it back to the client as X-Request-Id. When a request arrives with an X-Request-Id or
--  a W3C traceparent header (from a proxy, a gateway, another service), those ids are kept, so the trail
--  continues across services; Trace_Headers passes it on to the next one:
--
--     Client.Get (Billing_Url, Answer, Headers => Log.Trace_Headers (Request));
--
--  Output, level and format: Sparrow.Logs (LOG_LEVEL, LOG_FORMAT).
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Logs;

package Sparrow.Http.Log is

   subtype Fields is Logs.Fields;
   No_Fields : Fields renames Logs.No_Fields;

   function "&" (Left, Right : Fields) return Fields renames Logs."&";
   function Field (Name : String; Value : String) return Fields renames Logs.Field;
   function Field (Name : String; Value : Long_Long_Integer) return Fields renames Logs.Field;
   function Field (Name : String; Value : Boolean) return Fields renames Logs.Field;
   function Field (Name : String; Value : Duration) return Fields renames Logs.Field;

   --  Message with the request's ids and up to six fields (join more with "&").
   procedure Debug
     (Request : Http_Request;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);
   procedure Info
     (Request : Http_Request;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);
   procedure Warning
     (Request : Http_Request;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);
   procedure Error
     (Request : Http_Request;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);

   --  The same in a WebSocket handler, which is given a context in place of a request.
   procedure Debug
     (Context : Handler_Context;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);
   procedure Info
     (Context : Handler_Context;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);
   procedure Warning
     (Context : Handler_Context;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);
   procedure Error
     (Context : Handler_Context;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);

   --  The request_id (and, when it differs, trace_id) fields of Trace: for lines logged elsewhere, such as
   --  from a task the handler handed work to.
   function Trace_Fields (Trace : Trace_Context) return Fields;

   function Request_Id (Request : Http_Request) return String;
   function Request_Id (Context : Handler_Context) return String;
   function Request_Id (Trace : Trace_Context) return String;
   function Trace_Id (Trace : Trace_Context) return String;      --  32 hex digits
   function Span_Id (Trace : Trace_Context) return String;       --  16 hex digits
   function Parent_Id (Trace : Trace_Context) return String;     --  16 hex digits; zeros when none

   --  Request headers carrying the trace to a service this request calls: traceparent (this request's span
   --  as the parent) and X-Request-Id, one per line, as Sparrow.Client's Headers takes them.
   function Trace_Headers (Request : Http_Request) return String;
   function Trace_Headers (Context : Handler_Context) return String;

   --  For the server: a trace for a request with these headers (either may be ""). Trust_Callers False
   --  ignores them and starts a new trace.
   function Start_Trace (Request_Id_Header, Traceparent_Header : String; Trust_Callers : Boolean := True)
     return Trace_Context;

   --  Whether Text could be a traceparent header / a request id (1 .. 64 of letters, digits, - _ . : @ /).
   function Valid_Traceparent (Text : String) return Boolean;
   function Valid_Request_Id (Text : String) return Boolean;

end Sparrow.Http.Log;
