--  Cross-origin resource sharing: which other sites' pages may call your API from the browser. Without it a
--  browser lets those pages send simple requests but not read the answers, and refuses the rest outright.
--
--     Api : constant Cors.Policy := Cors.Allow ("https://app.example");
--     ...
--     Routers.Add (Routes, Options, "/api/*rest", Cors.Preflight (Api), Routers.On_Reactor);
--     Routers.Add (Routes, Get, "/api/items", Cors.Share (Api, List'Access));
--
--  CORS loosens what browsers enforce; it protects nothing on its own. Every request still needs its own
--  authentication, and with Credentials the listed origins act as your users: list only sites you trust.
with Sparrow.Buffers;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Sparrow.Http.Cors is

   type Policy is tagged private;

   --  Origins: whole origins separated by spaces ("https://a.example https://b.example"), or "*" for any.
   --  Max_Age: seconds a browser may remember a preflight. Raises Program_Error for "*" with Credentials.
   function Allow
     (Origins     : String;
      Methods     : String := "GET, POST, PUT, PATCH, DELETE";
      Headers     : String := "Content-Type, Authorization";
      Exposed     : String := "";
      Credentials : Boolean := False;
      Max_Age     : Natural := 600) return Policy;

   --  The headers that let Request's origin read Response; nothing for other origins.
   procedure Apply (This : Policy; Request : Http_Request; Response : in out Http_Response);

   --  Route it for OPTIONS on the paths the policy covers: answers browsers' preflight requests.
   type Preflight_Route is new Route_Handler with private;
   overriding procedure Handle (This : Preflight_Route; Request : Http_Request; Response : in out Http_Response);
   function Preflight (This : Policy'Class) return Preflight_Route;

   --  Action, then Apply.
   type Shared_Route is new Route_Handler with private;
   overriding procedure Handle (This : Shared_Route; Request : Http_Request; Response : in out Http_Response);
   function Share (This : Policy'Class; Action : not null Handler) return Shared_Route;

   --  Whether Origin is one of Allowed (as Allow's Origins).
   function Listed (Origin, Allowed : String) return Boolean;

private

   type Policy is tagged record
      Origins     : Sparrow.Buffers.String_Access;
      Methods     : Sparrow.Buffers.String_Access;
      Headers     : Sparrow.Buffers.String_Access;
      Exposed     : Sparrow.Buffers.String_Access;
      Credentials : Boolean := False;
      Max_Age     : Natural := 600;
   end record;

   type Preflight_Route is new Route_Handler with record
      Rules : Policy;
   end record;

   type Shared_Route is new Route_Handler with record
      Rules  : Policy;
      Action : Handler;
   end record;

end Sparrow.Http.Cors;
