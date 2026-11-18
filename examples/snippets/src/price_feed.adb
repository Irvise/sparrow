with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Event_Streams;
with Sparrow.Http.Requests;
with Sparrow.Http.Streams;

package body Price_Feed is

   Watchers : Streams.Group (Capacity => 10_000);

   --  GET /prices. In the browser:
   --    new EventSource("/prices").addEventListener("price", ...)
   procedure Subscribe
     (Request : Http_Request; Response : in out Http_Response)
   is
   begin
      Event_Streams.Begin_Events (Response);
      Streams.Add (Watchers, Requests.Connection (Request));
   end Subscribe;

   procedure Publish (Price : Integer) is
      Data : constant UTF8_String :=
        "{""price"":" & UTF8_String (Price'Image) & "}";
   begin
      Event_Streams.Send (Watchers, Data, Name => "price");
   end Publish;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Get, "/prices", Subscribe'Access, Run => On_Reactor);
   end Register;

end Price_Feed;
