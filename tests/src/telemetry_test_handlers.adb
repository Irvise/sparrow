with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Log;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Http.Spans;

package body Telemetry_Test_Handlers is

   protected body Collector is
      procedure Add (Text : String) is begin
         Received.Append (Text);
      end Add;
      function Bodies return Text_Lists.Vector is (Received);
   end Collector;

   function Database_Ready (Request : Http_Request) return Boolean is (Database_Up);

   procedure Collect (Request : Http_Request; Response : in out Http_Response) is begin
      Collector.Add (Requests.Content (Request));
      Responses.Send (Response, OK, "{}", Media_Type => "application/json");
   end Collect;

   procedure Work (Request : Http_Request; Response : in out Http_Response) is
      Outer : constant Spans.Span := Spans.Start (Request, "inner work");
   begin
      declare
         Inner : Spans.Span := Spans.Start (Spans.Context (Outer), "nested step");
      begin
         Spans.Fail (Inner);
      end;
      Responses.Send (Response, OK, UTF8_String (Log.Trace_Headers (Spans.Context (Outer))));
   end Work;

end Telemetry_Test_Handlers;
