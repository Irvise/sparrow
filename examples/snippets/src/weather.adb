with Sparrow.Client; use Sparrow.Client;
with Sparrow.Http.Log;

package body Weather is

   function Forecast (Request : Http_Request; City : String) return String
   is
      Url    : constant String :=
        "https://weather.example/v1/forecast?city=" & Url_Encode (City);
      Answer : Sparrow.Client.Response;
   begin
      --  Trace_Headers carries the request's trace on to the other service.
      Get (Url, Answer,
           Headers => "Accept: application/json" & ASCII.LF
                      & Sparrow.Http.Log.Trace_Headers (Request));
      if Status (Answer) /= 200 then
         return "";
      end if;
      return Content (Answer);
   end Forecast;

end Weather;
