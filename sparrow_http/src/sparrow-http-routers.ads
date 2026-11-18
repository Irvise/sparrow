--  Routes: which handler answers which method and path, and on which kind of task it runs.
--
--  A pattern is a path of literal segments, ":name" segments that match any one segment, and optionally a
--  final "*name" that matches the rest:
--
--     /articles                       /articles/:slug/comments/:id                /static/*file
--
--  Routes are tried in the order they were added and the first match wins. A router is built at start-up,
--  then only read: every reactor shares it without locking.
with Sparrow.Buffers;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;

package Sparrow.Http.Routers is

   --  Short names for a handler's parameter types, so a handler package needs only "use Sparrow.Http.Routers":
   --
   --     procedure Show (Request : Http_Request; Response : in out Http_Response);
   --
   --  The worker, the time, the connection and the trace are the request's: Requests.Worker (Request), ...
   subtype Http_Request is Requests.Request;
   subtype Http_Response is Responses.Response;
   subtype Handler_Context is Call_Context;   --  what WebSocket handlers are given in place of a request

   --  A handler fills Response. It must not keep Request, Response or anything inside them after it returns.
   --  An exception that leaves a handler is logged and answered with 500.
   type Handler is access procedure (Request : Requests.Request; Response : in out Responses.Response);

   --  A handler that is an object: for one that carries settings or state, such as a static folder
   --  (Static.Folder), a CORS policy around another handler (Cors.Allow) or a WebSocket endpoint
   --  (Websockets.Serve). Handle may run on several tasks at once.
   type Route_Handler is interface;
   procedure Handle (This : Route_Handler; Request : Http_Request; Response : in out Http_Response) is abstract;

   type Route_Handler_Access is access constant Route_Handler'Class;

   --  Where a handler runs.
   --    On_Reactor: on the event loop, between socket events. For handlers that only compute: they must not
   --                block (no database, no file reads, no bcrypt), or every connection of that reactor waits.
   --    On_Worker:  handed to a worker task, which may block. The default, and the place for database calls.
   type Placement is (On_Reactor, On_Worker);

   --  How a request's body reaches the handler.
   --    Buffered: whole, in Requests.Content, before the handler runs; at most Limits.Max_Body_Length.
   --    Streamed: as it arrives, read with Sparrow.Http.Bodies while the handler runs; at most
   --              Limits.Max_Streamed_Length. For uploads larger than memory should hold. Only On_Worker.
   type Body_Handling is (Buffered, Streamed);

   type Router (Capacity : Positive) is limited private;

   Too_Many_Routes : exception;
   Invalid_Pattern : exception;

   --  Raises Invalid_Pattern for a pattern that does not start with '/', has an empty or repeated name, more
   --  than Requests.Max_Parameters names, or a '*' segment that is not last; Program_Error for a streamed body
   --  on the reactor.
   procedure Add
     (This    : in out Router;
      Verb    : Method;
      Pattern : String;
      Action    : not null Handler;
      Run       : Placement := On_Worker;
      Body_Mode : Body_Handling := Buffered);

   --  The same with a handler object; the router keeps a copy of Action.
   procedure Add
     (This    : in out Router;
      Verb    : Method;
      Pattern : String;
      Action    : Route_Handler'Class;
      Run       : Placement := On_Worker;
      Body_Mode : Body_Handling := Buffered);

   --  Answers what no route matches (the default answers 404, or 405 when the path matches under another
   --  method).
   procedure Set_Fallback (This : in out Router; Action : not null Handler; Run : Placement := On_Reactor);
   procedure Set_Fallback (This : in out Router; Action : Route_Handler'Class; Run : Placement := On_Reactor);

   ---------------------------------------------------------------------------------------------------------------
   --  For the server, and for tests.

   type Route_Match is record
      Action         : Route_Handler_Access;    --  null: nothing matched and there is no fallback
      Run            : Placement := On_Reactor;
      Path_Matched   : Boolean := False;        --  some route has this path, under whatever method
      Index          : Natural := 0;            --  the route's place in the order added; 0: the fallback or none
      Body_Mode      : Body_Handling := Buffered;
   end record;

   --  Find the route for Request's method and path and record its captures in Request.
   procedure Find (This : Router; Request : in out Requests.Request; Result : out Route_Match);

   --  The routes added, for the server's metrics and traces.
   function Route_Count (This : Router) return Natural;
   function Has_Streamed_Body (This : Router) return Boolean;
   function Pattern (This : Router; Index : Positive) return String
     with Pre => Index <= Route_Count (This);
   function Verb (This : Router; Index : Positive) return Method
     with Pre => Index <= Route_Count (This);

   procedure Free (This : in out Router);

private

   --  A handler procedure as a handler object: every route is held as one.
   type Procedure_Route is new Route_Handler with record
      Action : Handler;
   end record;
   overriding procedure Handle (This : Procedure_Route; Request : Http_Request; Response : in out Http_Response);

   type Route is record
      Verb    : Method := Get;
      Pattern : Sparrow.Buffers.String_Access;
      Action  : Route_Handler_Access;
      Run     : Placement := On_Worker;
      Mode    : Body_Handling := Buffered;
   end record;

   type Route_List is array (Positive range <>) of Route;

   type Router (Capacity : Positive) is limited record
      Routes       : Route_List (1 .. Capacity);
      Route_Total  : Natural := 0;
      Fallback     : Route_Handler_Access;
      Fallback_Run : Placement := On_Reactor;
      Any_Streamed : Boolean := False;
   end record;

end Sparrow.Http.Routers;
