--  The routes telemetry_tests serves: a stand-in collector, a readiness check it can turn off, and a handler
--  with spans.
with Ada.Containers.Indefinite_Vectors;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Telemetry_Test_Handlers is

   package Text_Lists is new Ada.Containers.Indefinite_Vectors (Positive, String);

   --  What the collector route received.
   protected Collector is
      procedure Add (Text : String);
      function Bodies return Text_Lists.Vector;
   private
      Received : Text_Lists.Vector;
   end Collector;

   Database_Up : Boolean := True with Atomic;

   function Database_Ready (Request : Http_Request) return Boolean;

   procedure Collect (Request : Http_Request; Response : in out Http_Response);

   --  A span with a nested one; answers with the trace headers the outer span would pass on.
   procedure Work (Request : Http_Request; Response : in out Http_Response);

end Telemetry_Test_Handlers;
