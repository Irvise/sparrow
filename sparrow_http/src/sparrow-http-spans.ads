--  Spans: the timed pieces of a trace, handed to an exporter (Sparrow.Open_Telemetry sends them to an OpenTelemetry
--  collector) when their trace is sampled.
--
--  The server makes one span per request, named after its route ("GET /users/:id"). A handler adds its own for
--  work inside the request; a span ends when it leaves scope:
--
--     declare
--        Lookup : constant Spans.Span := Spans.Start (Request, "load user");
--     begin
--        ...
--        Client.Get (Url, Answer, Headers => Log.Trace_Headers (Spans.Context (Lookup)));
--     end;
--
--  Spans.Context (Lookup) is the request's context with Lookup as the current span: start spans from it to nest
--  them, and pass it to Log.Trace_Headers so that a called service's spans hang under this one.
--
--  A trace is sampled when its caller says so (a traceparent header, kept while Servers.Configuration's
--  Trust_Trace is on), or otherwise for Sample_Ratio of traces, chosen by trace id. With no exporter set,
--  nothing is recorded and a span costs a test.
private with Ada.Finalization;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Sparrow.Http.Spans is

   type Unix_Nanoseconds is new Long_Long_Integer;

   function Now return Unix_Nanoseconds;

   type Span_Kind is (Server, Internal);   --  a request the server answered; work inside it

   Max_Text : constant := 200;   --  longer names, routes and paths are cut

   type Finished_Span is record
      Trace         : Trace_Context;   --  its ids: Sparrow.Http.Log's Trace_Id, Span_Id and Parent_Id
      Kind          : Span_Kind := Internal;
      Name          : String (1 .. Max_Text) := [others => ' '];
      Name_Length   : Natural range 0 .. Max_Text := 0;
      Started       : Unix_Nanoseconds := 0;
      Ended         : Unix_Nanoseconds := 0;
      Failed        : Boolean := False;   --  answered with 5xx, or Fail was called
      --  server spans
      Verb          : Method := Get;
      Route         : String (1 .. Max_Text) := [others => ' '];   --  the matched pattern; empty when none
      Route_Length  : Natural range 0 .. Max_Text := 0;
      Path          : String (1 .. Max_Text) := [others => ' '];   --  without the query
      Path_Length   : Natural range 0 .. Max_Text := 0;
      Status        : Natural := 0;
   end record;

   --  Export is called with each finished span of a sampled trace, on reactor and worker tasks, maybe several
   --  at once. It must not block or take long: it should queue the span and return.
   type Exporter is access procedure (Item : Finished_Span);

   --  From now on, hand spans to Export (null: to nobody), and sample Sample_Ratio of the traces that start here.
   procedure Set_Exporter (Export : Exporter; Sample_Ratio : Long_Float := 1.0)
     with Pre => Sample_Ratio in 0.0 .. 1.0;

   --  Whether Trace's spans go to an exporter.
   function Recording (Trace : Trace_Context) return Boolean;

   ---------------------------------------------------------------------------------------------------------------
   --  spans in handlers

   type Span is limited private;

   function Start (Request : Http_Request; Name : String) return Span;
   function Start (Context : Handler_Context; Name : String) return Span;

   --  Mark the span as failed (OpenTelemetry's error status).
   procedure Fail (This : in out Span);

   --  The context the span was started in, with the span as the current one.
   function Context (This : Span) return Handler_Context;

   ---------------------------------------------------------------------------------------------------------------
   --  For the server and Sparrow.Http.Log.

   --  Whether a trace that starts here, with this id (32 hex digits), is sampled: by its last 14 digits, so
   --  every service with the same ratio picks the same traces.
   function Sampled_By_Ratio (Trace_Id : String) return Boolean;

   --  Hand Item to the exporter, if there is one.
   procedure Finish (Item : Finished_Span);

   --  Text cut to Max_Text, into Into, setting Length.
   procedure Put (Into : out String; Length : out Natural; Text : String)
     with Pre => Into'Length = Max_Text;

private

   type Span is new Ada.Finalization.Limited_Controlled with record
      Within  : Call_Context;   --  with this span's trace
      Item    : Finished_Span;
      Records : Boolean := False;
   end record;

   overriding procedure Finalize (This : in out Span);

   --  A span is a scope guard: declaring it is the use.
   pragma Unreferenced_Objects (Span);

end Sparrow.Http.Spans;
