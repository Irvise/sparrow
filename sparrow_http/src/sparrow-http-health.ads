--  Health and metrics routes, for load balancers, orchestrators and Prometheus:
--
--     Health.Add (Routes, Check => Database_Ready'Access);
--
--  adds
--
--     GET /healthz   200 "ok" while the process serves requests (liveness)
--     GET /readyz    200 "ready", or 503 once the server is stopping or when Check says no (readiness)
--     GET /metrics   every Sparrow.Metrics metric, in the Prometheus text format
--
--  /metrics tells whoever reads it which routes exist and how busy they are: keep it off the public side
--  (the proxy can refuse it), or route Metrics yourself behind authentication instead of calling Add.
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Sparrow.Http.Health is

   procedure Live (Request : Http_Request; Response : in out Http_Response);

   procedure Metrics (Request : Http_Request; Response : in out Http_Response);

   --  Whether the application can serve, say whether its database answers. It runs on a worker and may block
   --  briefly; an exception from it counts as no.
   type Readiness_Check is access function (Request : Http_Request) return Boolean;

   type Readiness (Check : Readiness_Check) is new Route_Handler with null record;   --  Check may be null
   overriding procedure Handle (This : Readiness; Request : Http_Request; Response : in out Http_Response);

   --  The three routes, at the paths above. Live and Metrics run on the reactor, and so does readiness when
   --  there is no Check. Takes three of Routes' capacity.
   procedure Add (Routes : in out Router; Check : Readiness_Check := null);

end Sparrow.Http.Health;
