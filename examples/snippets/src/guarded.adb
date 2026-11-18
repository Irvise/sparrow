with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Cors;
with Sparrow.Http.Limits;
with Sparrow.Http.Responses;

package body Guarded is

   --  Per client address: 5 at once, then one every 5 seconds.
   --  Past that, the route answers 429 with Retry-After.
   Logins : constant Limits.Limit :=
     Limits.Per_Client (Rate => 0.2, Burst => 5);

   --  Pages on https://app.example may call /api/... from the browser.
   Api : constant Cors.Policy := Cors.Allow ("https://app.example");

   procedure Log_In
     (Request : Http_Request; Response : in out Http_Response)
   is
      pragma Unreferenced (Request);
   begin
      Responses.Send (Response, OK, "welcome");
   end Log_In;

   procedure Items
     (Request : Http_Request; Response : in out Http_Response)
   is
      pragma Unreferenced (Request);
   begin
      Responses.Send (Response, OK, "[]", Media_Type => Application_Json);
   end Items;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Post, "/login", Limits.Wrap (Logins, Log_In'Access));
      Add (Routes, Options, "/api/*rest", Cors.Preflight (Api),
           Run => On_Reactor);
      Add (Routes, Get, "/api/items", Cors.Share (Api, Items'Access));
   end Register;

end Guarded;
