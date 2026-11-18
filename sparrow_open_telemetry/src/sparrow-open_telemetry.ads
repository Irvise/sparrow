--  Trace export to an OpenTelemetry collector: the spans of Sparrow.Http.Spans (one per request, and the ones
--  handlers start), sent as OTLP over HTTP, in JSON.
--
--     Open_Telemetry.Start (Service => "bookmarks");   --  before Servers.Run
--     Servers.Run (Settings, Routes);
--     Open_Telemetry.Stop;                             --  sends what is left
--
--  Or Open_Telemetry.Start_From_Environment ("bookmarks"), which reads the standard OTEL_* variables. Finished
--  spans wait in a bounded queue, and a task of this package sends them in batches (once a second, or as soon
--  as a batch is full). A full queue or a collector that does not answer costs spans, never request time: they are
--  dropped and counted in sparrow_open_telemetry_spans_dropped_total.
package Sparrow.Open_Telemetry is

   Default_Endpoint : constant String := "http://localhost:4318/v1/traces";

   --  Start exporting (after stopping an exporter already running). Service is the service.name every span
   --  carries. Headers are extra request headers, one per line ("Authorization: Bearer ..." & ASCII.LF & ...).
   --  Sample_Ratio is the share of traces that start here to keep; traces whose caller decided are kept or not
   --  as it said.
   procedure Start
     (Service      : String;
      Endpoint     : String := Default_Endpoint;
      Sample_Ratio : Long_Float := 1.0;
      Headers      : String := "";
      Queue_Limit  : Positive := 4096;
      Batch_Size   : Positive := 512)
     with Pre => Sample_Ratio in 0.0 .. 1.0 and then Batch_Size <= Queue_Limit;

   --  Start with the settings of the environment, when OTEL_EXPORTER_OTLP_TRACES_ENDPOINT or
   --  OTEL_EXPORTER_OTLP_ENDPOINT (to which "/v1/traces" is added) is set; otherwise Started is False and
   --  nothing starts. Also read: OTEL_SERVICE_NAME (else Default_Service), OTEL_TRACES_SAMPLER_ARG (the ratio,
   --  else 1) and OTEL_EXPORTER_OTLP_HEADERS ("name=value,name=value", values percent-encoded).
   procedure Start_From_Environment (Default_Service : String; Started : out Boolean);

   --  Send every span queued so far, then return.
   procedure Flush;

   --  Stop taking spans, send the ones queued, end the task.
   procedure Stop;

   function Is_Running return Boolean;

end Sparrow.Open_Telemetry;
