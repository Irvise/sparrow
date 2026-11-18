with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Health;
with Sparrow.Http.Log;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Metrics;

package body Shop is

   Orders : constant Sparrow.Metrics.Counter :=
     Sparrow.Metrics.New_Counter ("shop_orders_total", "Orders placed.");

   --  /readyz: whether this instance can serve. Ask your database here.
   function Database_Ready (Request : Http_Request) return Boolean is
      pragma Unreferenced (Request);
   begin
      return True;
   end Database_Ready;

   procedure Order
     (Request : Http_Request; Response : in out Http_Response)
   is
      Item : constant String := Requests.Form_Value (Request, "item");
   begin
      Sparrow.Metrics.Add (Orders);
      --  The line carries the request's id, like its access-log line.
      Log.Info (Request, "order placed", Log.Field ("item", Item));
      Responses.Send (Response, Created, "ordered");
   end Order;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Post, "/orders", Order'Access);
      --  /healthz, /readyz, and /metrics for Prometheus
      Health.Add (Routes, Check => Database_Ready'Access);
   end Register;

end Shop;
