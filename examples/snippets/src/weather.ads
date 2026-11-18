with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Weather is
   function Forecast (Request : Http_Request; City : String) return String;
end Weather;
