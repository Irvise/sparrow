--  Handlers for http_tests, at library level as the router requires.
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Limits;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Streams;
with Sparrow.Http.Websockets;

package Http_Test_Handlers is


   procedure Hello (Request : Http_Request; Response : in out Http_Response);

   --  Long_Text as text/plain: compressed when the client takes gzip; Kept_Text says Cache-Control: no-transform.
   function Long_Text return String;
   procedure Long_Text_Route (Request : Http_Request; Response : in out Http_Response);
   procedure Kept_Text (Request : Http_Request; Response : in out Http_Response);
   procedure Echo (Request : Http_Request; Response : in out Http_Response);
   procedure Who (Request : Http_Request; Response : in out Http_Response);
   procedure Slow (Request : Http_Request; Response : in out Http_Response);
   procedure Boom (Request : Http_Request; Response : in out Http_Response);
   --  Logs "handled" with n=7 and answers with Log.Trace_Headers.
   procedure Traced (Request : Http_Request; Response : in out Http_Response);
   procedure Moved (Request : Http_Request; Response : in out Http_Response);
   procedure Leave (Request : Http_Request; Response : in out Http_Response);

   --  A stream: a first piece in the response, two more sent while (or after) the handler runs, then the end.
   procedure Count_Up (Request : Http_Request; Response : in out Http_Response);

   --  An event stream whose connection joins Watchers.
   Watchers : Sparrow.Http.Streams.Group (8);
   procedure Watch (Request : Http_Request; Response : in out Http_Response);

   --  A WebSocket that echoes, upper-cased for text; "bye" closes it; "boom" fails.
   type Echo_Socket is new Sparrow.Http.Websockets.Endpoint with null record;
   overriding procedure On_Message
     (This : Echo_Socket; Socket : Connection_Id; Message : String; Binary : Boolean; Context : Handler_Context);
   overriding procedure On_Close (This : Echo_Socket; Socket : Connection_Id);

   protected Socket_Events is
      procedure Closed;
      function Closes return Natural;
   private
      Close_Total : Natural := 0;
   end Socket_Events;

   --  Streamed bodies. Upload_Sum reads the body 4 KiB at a time, slowly now and then, and answers
   --  "<bytes> <sum of byte values>"; Upload_Part reads 10 bytes and answers; Upload_All reads it all as one
   --  string (at most 1000 bytes) and echoes it. A Body_Error is counted in Body_Errors.
   procedure Upload_Sum (Request : Http_Request; Response : in out Http_Response);
   procedure Upload_Part (Request : Http_Request; Response : in out Http_Response);
   procedure Upload_All (Request : Http_Request; Response : in out Http_Response);

   --  Multipart.Save_Stream into obj/; moves part "file" to obj/upload-moved.bin, discards the rest, and
   --  answers "<title field> <part count> <file's size> <file's name>", or 400.
   procedure Upload_Form (Request : Http_Request; Response : in out Http_Response);

   protected Body_Errors is
      procedure Add;
      function Total return Natural;
   private
      Count : Natural := 0;
   end Body_Errors;

   --  A limit key that is the same for every request.
   function Any_Key (Request : Http_Request) return String;

   --  Two requests per client, then one every 1000 s.
   Tight : constant Sparrow.Http.Limits.Limit := Sparrow.Http.Limits.Per_Client (Rate => 0.001, Burst => 2);

   procedure Count_Start (Worker : Worker_Id);
   procedure Count_Stop (Worker : Worker_Id);

   protected Counters is
      procedure Started;
      procedure Stopped;
      function Starts return Natural;
      function Stops return Natural;
   private
      Start_Total, Stop_Total : Natural := 0;
   end Counters;

end Http_Test_Handlers;
