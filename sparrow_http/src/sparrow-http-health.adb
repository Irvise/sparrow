with Sparrow.Http.Responses;
with Sparrow.Http.Servers;
with Sparrow.Metrics;

package body Sparrow.Http.Health is

   procedure Live (Request : Http_Request; Response : in out Http_Response) is
      pragma Unreferenced (Request);
   begin
      Responses.Send (Response, OK, "ok");
      Responses.Set_Header (Response, "Cache-Control", "no-store");
   end Live;

   procedure Metrics (Request : Http_Request; Response : in out Http_Response) is
      pragma Unreferenced (Request);
   begin
      Responses.Begin_Content (Response, OK, Sparrow.Metrics.Text_Media_Type);
      Sparrow.Metrics.Write_Text (Response.Content);
      Responses.Set_Header (Response, "Cache-Control", "no-store");
   end Metrics;

   overriding procedure Handle (This : Readiness; Request : Http_Request; Response : in out Http_Response) is
      function Checked return Boolean is
      begin
         return This.Check = null or else This.Check (Request);
      exception
         when others =>
            return False;
      end Checked;
   begin
      if not Servers.Is_Stopping and then Checked then
         Responses.Send (Response, OK, "ready");
      else
         Responses.Send (Response, Service_Unavailable, "not ready");
      end if;
      Responses.Set_Header (Response, "Cache-Control", "no-store");
   end Handle;

   procedure Add (Routes : in out Router; Check : Readiness_Check := null) is begin
      Routers.Add (Routes, Get, "/healthz", Live'Access, Run => On_Reactor);
      Routers.Add (Routes, Get, "/readyz", Readiness'(Check => Check),
                   Run => (if Check = null then On_Reactor else On_Worker));
      Routers.Add (Routes, Get, "/metrics", Metrics'Access, Run => On_Reactor);
   end Add;

end Sparrow.Http.Health;
