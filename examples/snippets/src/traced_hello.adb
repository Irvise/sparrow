with Greetings;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.Open_Telemetry;

procedure Traced_Hello is
   Routes  : Router (Capacity => 8);
   Started : Boolean;
begin
   Greetings.Register (Routes);
   --  On when OTEL_EXPORTER_OTLP_ENDPOINT is set (http://localhost:4318).
   Sparrow.Open_Telemetry.Start_From_Environment ("greetings", Started);
   Servers.Run (Servers.From_Environment, Routes);
   Sparrow.Open_Telemetry.Stop;   --  sends what is left
end Traced_Hello;
