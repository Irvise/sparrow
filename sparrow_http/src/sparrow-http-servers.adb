--  Outside SPARK: tasks, protected queues, access-to-subprogram handlers and the exceptions they may raise.
--  What can be proved lives in the parser, the requests and the responses this body is built on.
with Ada.Characters.Handling;
with Ada.Containers.Hashed_Maps;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Chunked;
with Sparrow.Http.Compression;
with Sparrow.Http.Delivery; use Sparrow.Http.Delivery;
with Sparrow.Http.Frames;
with Sparrow.Http.Http_2;
with Sparrow.Http.Log;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Http.Spans;
with Sparrow.IO.Addresses;
with Sparrow.IO.Events; use Sparrow.IO.Events;
with Sparrow.IO.Process;
with Sparrow.Encoding;
with Sparrow.Logs;
with Sparrow.Metrics;

package body Sparrow.Http.Servers is

   use Sparrow.IO;
   use Sparrow.IO.Sockets;
   use type Times.Milliseconds;
   use type Parser.Parse_Outcome;
   use type Chunked.Decoder_State;
   use type Routers.Body_Handling;
   use type Routers.Route_Handler_Access;
   use type Routers.Placement;
   use type Tls.Outcome;
   use all type Responses.Response_Mode;
   use type Logs.Fields;
   use type Spans.Unix_Nanoseconds;
   use type Http_2.Event_Kind;
   use type Http_2.Stream_Id;

   subtype Milliseconds is Times.Milliseconds;

   First_Input_Capacity : constant := 4096;
   Stream_Input_Capacity : constant := 65_536;   --  input held for a streamed body, besides the pipe
   Keep_Output_Capacity : constant := 65_536;   --  larger output buffers are freed once sent
   Shutdown_Grace       : constant Milliseconds := 30_000;
   Sweep_Interval       : constant Milliseconds := 1_000;
   Pause_On_Exhaustion  : constant Milliseconds := 100;
   Max_Pending_Output   : constant := 8 * 1024 * 1024;   --  a stream or socket this far behind is dropped

   type Router_Access is access constant Routers.Router;
   type Context_Access is access constant Tls.Context;

   ---------------------------------------------------------------------------------------------------------------
   --  What one Run shares among its tasks. One server per process, so these are package state.

   Active_Settings : Configuration;
   Active_Routes   : Router_Access;
   Active_Hooks    : Worker_Hooks;
   Active_Security : Context_Access;
   Stopping        : Boolean := False with Atomic;
   Parse_Limits    : Parser.Limits;     --  Active_Settings.Limits, streaming only when a route streams
   Route_Bodies    : Boolean := False;  --  some route streams its body: route a body before it arrives

   Termination : Waker;           --  signalled by the system's termination requests

   ---------------------------------------------------------------------------------------------------------------
   --  metrics (Sparrow.Metrics); Run declares them

   type Class_Counters is array (1 .. 5) of Metrics.Counter;   --  by status class: 1xx .. 5xx

   type Route_Metrics is record
      Requests : Class_Counters;
      Latency  : Metrics.Histogram;
   end record;

   --  By route index; 0 is for requests no route took (404, 405, the fallback, malformed requests).
   type Route_Metrics_Array is array (Natural range <>) of Route_Metrics;
   type Route_Metrics_Access is access Route_Metrics_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Route_Metrics_Array, Route_Metrics_Access);

   By_Route         : Route_Metrics_Access;
   Queue_Depth      : Metrics.Gauge;
   Rejected         : Metrics.Counter;   --  requests and messages refused because the queue was full
   Refused          : Metrics.Counter;   --  connections refused because every slot was taken
   Slow_Dropped     : Metrics.Counter;
   Messages_In      : Metrics.Counter;
   Messages_Out     : Metrics.Counter;

   ---------------------------------------------------------------------------------------------------------------
   --  jobs (Sparrow.Http.Delivery): requests and socket messages handed to workers, and what comes back

   --  The requests waiting for a worker, oldest first.
   protected Work_Queue is
      procedure Reset;
      procedure Push (Item : in out Job_Access; Accepted : out Boolean);
      entry Take (Item : out Job_Access);   --  null once closed and empty
      procedure Close;
   private
      First, Last : Job_Access;
      Count       : Natural := 0;
      Closed      : Boolean := False;
   end Work_Queue;

   protected body Work_Queue is

      procedure Reset is begin
         First  := null;
         Last   := null;
         Count  := 0;
         Closed := False;
      end Reset;

      procedure Push (Item : in out Job_Access; Accepted : out Boolean) is begin
         Accepted := not Closed and then Count < Active_Settings.Queue_Limit;
         if Accepted then
            Item.Next := null;
            if Last = null then
               First := Item;
            else
               Last.Next := Item;
            end if;
            Last  := Item;
            Count := Count + 1;
            Item  := null;
            Metrics.Set (Queue_Depth, Long_Long_Integer (Count));
         end if;
      end Push;

      entry Take (Item : out Job_Access) when Count > 0 or else Closed is begin
         Item := First;
         if Item /= null then
            First     := Item.Next;
            Item.Next := null;
            Count     := Count - 1;
            Metrics.Set (Queue_Depth, Long_Long_Integer (Count));
            if First = null then
               Last := null;
            end if;
         end if;
      end Take;

      procedure Close is begin
         Closed := True;
      end Close;

   end Work_Queue;

   --  Workers report how their On_Start went; Run waits for all of them.
   protected Startup is
      procedure Reset (Expected : Natural);
      procedure Report (Started : Boolean);
      entry Wait (All_Started : out Boolean);
   private
      Waiting : Natural := 0;
      Failed  : Boolean := False;
   end Startup;

   protected body Startup is

      procedure Reset (Expected : Natural) is begin
         Waiting := Expected;
         Failed  := False;
      end Reset;

      procedure Report (Started : Boolean) is begin
         Failed  := Failed or else not Started;
         Waiting := (if Waiting > 0 then Waiting - 1 else 0);
      end Report;

      entry Wait (All_Started : out Boolean) when Waiting = 0 is begin
         All_Started := not Failed;
      end Wait;

   end Startup;

   ---------------------------------------------------------------------------------------------------------------
   --  handlers

   --  An exception that left application code (or the server's own), with the request it happened in.
   procedure Log_Failure
     (Where      : String;
      Occurrence : Ada.Exceptions.Exception_Occurrence;
      Trace      : Trace_Context := No_Trace;
      Details    : Logs.Fields := Logs.No_Fields)
   is begin
      Logs.Error (Where & " failed",
                  Log.Trace_Fields (Trace) & Details
                  & Logs.Field ("exception", Ada.Exceptions.Exception_Name (Occurrence))
                  & Logs.Field ("error", Ada.Exceptions.Exception_Message (Occurrence))
                  & Logs.Field ("detail", Ada.Exceptions.Exception_Information (Occurrence)));
   end Log_Failure;

   --  Run Action; an exception that leaves it becomes a 500.
   procedure Call
     (Action   : not null Routers.Route_Handler_Access;
      Request  : in out Requests.Request;
      Response : in out Responses.Response;
      Worker   : Worker_Count;
      Client   : Connection_Id;
      Trace    : Trace_Context)
   is
      Now : Times.Unix_Seconds;
   begin
      IO.Process.Read_Clock (Now);
      Requests.Set_Context (Request, (Worker => Worker, Now => Now, Connection => Client, Trace => Trace));
      Action.Handle (Request, Response);
      if Active_Settings.Compression then
         begin
            Compression.Apply (Request, Response);
         exception
            when Occurrence : others =>   --  the response goes out as the handler made it
               Log_Failure ("compression", Occurrence, Trace, Logs.Field ("path", Requests.Path (Request)));
         end;
      end if;
   exception
      when Occurrence : others =>
         Log_Failure ("handler", Occurrence, Trace, Logs.Field ("path", Requests.Path (Request)));
         Responses.Clear (Response);
         Responses.Fail (Response, Internal_Server_Error);
   end Call;

   function Context_For (Worker : Worker_Count; Client : Connection_Id; Trace : Trace_Context)
     return Call_Context
   is
      Now : Times.Unix_Seconds;
   begin
      IO.Process.Read_Clock (Now);
      return (Worker => Worker, Now => Now, Connection => Client, Trace => Trace);
   end Context_For;

   --  A WebSocket endpoint's handlers; an exception that leaves them is logged. False when one did.
   function Deliver_Message (Item : Job; Worker : Worker_Count) return Boolean is begin
      Endpoints (Item.Endpoint).Handlers.On_Message
        (Id_Of (Item), Content (Item.Data), Item.Binary, Context_For (Worker, Id_Of (Item), Item.Trace));
      return True;
   exception
      when Occurrence : others =>
         Log_Failure ("WebSocket message handler", Occurrence, Item.Trace);
         return False;
   end Deliver_Message;

   procedure Deliver_Close (Endpoint : Positive; Client : Connection_Id) is begin
      Endpoints (Endpoint).Handlers.On_Close (Client);
   exception
      when Occurrence : others =>
         Log_Failure ("WebSocket close handler", Occurrence);
   end Deliver_Close;

   ---------------------------------------------------------------------------------------------------------------
   --  workers

   task type Worker is
      entry Start (Id : Worker_Id);
   end Worker;

   task body Worker is
      Self    : Worker_Id;
      Started : Boolean := True;
      Go      : Boolean;
      Item    : Job_Access;
   begin
      accept Start (Id : Worker_Id) do
         Self := Id;
      end Start;

      if Active_Hooks.On_Start /= null then
         begin
            Active_Hooks.On_Start (Self);
         exception
            when Occurrence : others =>
               Log_Failure ("worker" & Self'Image & " did not start", Occurrence);
               Started := False;
         end;
      end if;
      Startup.Report (Started);
      Startup.Wait (Go);

      if Go then
         loop
            Work_Queue.Take (Item);
            exit when Item = null;
            case Item.Kind is
               when Handle_Request =>
                  Call (Item.Action, Item.Request, Item.Response, Self, Id_Of (Item.all), Item.Trace);
                  Post (Item);
               when Socket_Message =>
                  Item.Binary := not Deliver_Message (Item.all, Self);   --  back: True means close it
                  Post (Item);
               when Socket_Closed =>
                  Deliver_Close (Item.Endpoint, Id_Of (Item.all));
                  Free (Item);
               when Push_Data | Push_Close | Body_Wanted =>
                  Free (Item);   --  never queued for workers
            end case;
         end loop;
      end if;

      if Started and then Active_Hooks.On_Stop /= null then
         begin
            Active_Hooks.On_Stop (Self);
         exception
            when Occurrence : others =>
               Log_Failure ("worker" & Self'Image & " On_Stop", Occurrence);
         end;
      end if;
   exception
      when Occurrence : others =>
         Log_Failure ("worker", Occurrence);
         Stop;
   end Worker;

   ---------------------------------------------------------------------------------------------------------------
   --  reactors

   type Connection_Mode is (Http_Mode, Stream_Mode, Socket_Mode, Http_2_Mode);

   --  One request's tracing and access-log state, from its head to its answer: a connection's current request,
   --  or one HTTP/2 stream's.
   type Exchange is record
      Trace         : Trace_Context := No_Trace;
      Pending_Log   : Boolean := False;      --  a request whose access-log line is not written yet
      Parsed        : Boolean := False;      --  it got as far as a method and a path
      Log_Verb      : Method := Get;
      Log_Path      : String (1 .. 200) := [others => ' '];
      Path_Length   : Natural := 0;
      Client        : String (1 .. 45) := [others => ' '];   --  the client's address (IPv6 when a proxy says so)
      Client_Length : Natural := 0;
      Started       : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Route_Index   : Natural := 0;          --  the matched route; 0: none
      Span_Started  : Spans.Unix_Nanoseconds := 0;   --  0: the request's span is not recorded
      --  for debug lines: which connection the request came on (its reactor, and its number there; 0: not
      --  known), and how many requests that connection has begun
      Link_Reactor  : Natural := 0;
      Link_Number   : Natural := 0;
      Requests_Seen : Natural := 0;
   end record;

   --  What the server keeps for one HTTP/2 lane beside the session's own: its request's log, and what it is owed.
   type Lane_State is record
      Stream      : Http_2.Stream_Id := 0;   --  0: nothing is owed here
      Log         : Exchange;
      Busy        : Boolean := False;        --  its response is being made (by a worker, or by the reactor)
      Is_Head     : Boolean := False;
      Streaming   : Boolean := False;        --  answered as an event stream, open for pushes
      Heartbeat   : Boolean := False;
      Last_Output : Milliseconds := 0;
      Body_Open   : Boolean := False;        --  its body goes into the lane's pipe
      Held_First  : Job_Access;              --  pushes that came while its response was being made
      Held_Last   : Job_Access;
   end record;

   type Lane_State_Array is array (Http_2.Lane) of Lane_State;

   type Http_2_State is limited record
      Session : Http_2.Session;
      Lanes   : Lane_State_Array;
   end record;

   type Http_2_Access is access Http_2_State;
   procedure Free is new Ada.Unchecked_Deallocation (Http_2_State, Http_2_Access);

   type Connection is limited record
      Socket        : Descriptor := No_Descriptor;
      Open          : Boolean := False;
      Fresh         : Boolean := False;      --  nothing read yet: it may start with HTTP/2's preface
      Busy          : Boolean := False;      --  a request of this connection is with a worker
      Close_After   : Boolean := False;      --  close once the current response is out
      Peer_Done     : Boolean := False;      --  the client sent its last byte
      Handshaking   : Boolean := False;
      Wants_Write   : Boolean := False;      --  the socket refused a write (or TLS wants one): wait to write
      Continue_Sent : Boolean := False;      --  "100 Continue" went out for the request being received
      --  a request body on its way: a chunked one being decoded, or one streamed to its handler
      Streaming     : Boolean := False;      --  its bytes go to the slot's pipe (Body_Mode => Streamed)
      Body_Blocked  : Boolean := False;      --  the pipe is full: wait for the handler (a Body_Wanted job)
      Body_Left     : Parser.Body_Size := 0;   --  Streaming, with a Content-Length: bytes still to come
      Body_Routed   : Boolean := False;      --  its route was looked up, and buffers it
      Decoding      : Boolean := False;      --  chunked: Input (.. Chunk_Kept) ends with the body decoded so far
      Chunk         : Chunked.Decoder;
      Chunk_Kept    : Natural := 0;
      Watched       : Interest := (Readable => True, Writable => False);
      Generation    : Natural := 0;
      Channel       : Tls.Session;
      Input         : Buffer;                --  received bytes not yet handled
      Output        : Buffer;                --  a response not yet all sent
      Output_Sent   : Natural := 0;
      Opened_At     : Milliseconds := 0;
      Last_Activity : Milliseconds := 0;     --  the last request or frame received (or response begun)
      --  streams and sockets
      Mode          : Connection_Mode := Http_Mode;
      Heartbeat     : Boolean := False;      --  Stream_Mode: send an empty event when quiet
      Endpoint      : Natural := 0;          --  Socket_Mode
      Last_Output   : Milliseconds := 0;
      Ping_Sent     : Boolean := False;
      Held_First    : Job_Access;            --  pushes that came while the response was being made
      Held_Last     : Job_Access;
      Message       : Buffer;                --  a WebSocket message arriving in fragments
      Message_Open  : Boolean := False;
      Message_Kind  : Boolean := False;      --  binary
      --  tracing and the access log
      Peer          : IP_Address := Any_IPv4;
      Current       : Exchange;              --  the request in flight (HTTP/1.1); a socket keeps its upgrade's
      Link          : Http_2_Access;         --  Http_2_Mode; made the first time the slot serves HTTP/2, and kept
   end record;

   Open_Connections : array (Connection_Mode) of Metrics.Gauge;

   --  This leaves Mode for To_Mode.
   procedure Change_Mode (This : in out Connection; To_Mode : Connection_Mode) is begin
      Metrics.Add (Open_Connections (This.Mode), -1);
      Metrics.Add (Open_Connections (To_Mode), 1);
      This.Mode := To_Mode;
   end Change_Mode;

   function Output_Pending (This : Connection) return Boolean is (This.Output_Sent < This.Output.Length);

   --  A slot's connection is allocated the first time the slot is used, and kept for the next connection that
   --  takes the slot: memory follows the most connections ever open, not Max_Connections.
   type Connection_Access is access Connection;
   type Connection_Array is array (Positive range <>) of Connection_Access;
   type Connection_Array_Access is access Connection_Array;
   type Slot_Array is array (Positive range <>) of Natural;
   type Slot_Array_Access is access Slot_Array;

   function Hash (Item : Descriptor) return Ada.Containers.Hash_Type is (Ada.Containers.Hash_Type'Mod (Item));

   package Slot_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type => Descriptor, Element_Type => Positive, Hash => Hash, Equivalent_Keys => "=");

   procedure Free is new Ada.Unchecked_Deallocation (Connection_Array, Connection_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Connection, Connection_Access);

   --  Per slot, whether used or not: its place in the slot table, the free-slot stack and the live table.
   Slot_Table_Bytes : constant := (Standard'Address_Size + Integer'Size + Live_Value'Size) / 8;
   procedure Free is new Ada.Unchecked_Deallocation (Slot_Array, Slot_Array_Access);

   type Listener_Array is array (Reactor_Index range <>) of Descriptor;
   type Listener_Array_Access is access Listener_Array;
   Listeners : Listener_Array_Access;   --  Listeners (Id) is reactor Id's; all the same where ports are not shared

   --  One reactor's state, owned by its task.
   type Reactor_State is limited record
      Id           : Reactor_Index := 1;
      Events       : Poller;
      Listener     : Descriptor := No_Descriptor;
      Listening    : Boolean := False;
      Paused_Until : Milliseconds := 0;
      Slots        : Connection_Array_Access;
      Free_Slots   : Slot_Array_Access;     --  a stack of unused slots, 1 .. Free_Total
      Free_Total   : Natural := 0;
      By_Socket    : Slot_Maps.Map;
      Active       : Natural := 0;
      Accepted     : Natural := 0;          --  connections taken so far, numbering them for debug lines
      Now          : Milliseconds := 0;
   end record;

   Edge_Triggered : constant Boolean := Reports_Changes;

   --  Keep the poller's interest in line with what the connection waits for, where reports are of states.
   procedure Update_Interest (Owner : in out Reactor_State; This : in out Connection) is
      Wanted : Interest;
   begin
      if Edge_Triggered or else not This.Open then
         return;
      end if;
      Wanted := (Readable => This.Handshaking or else not (This.Busy or else Output_Pending (This))
                               or else (This.Streaming and then not This.Body_Blocked),
                 Writable => This.Wants_Write);
      if Wanted /= This.Watched then
         Rewatch (Owner.Events, This.Socket, Wanted);
         This.Watched := Wanted;
      end if;
   end Update_Interest;

   ---------------------------------------------------------------------------------------------------------------
   --  tracing and the access log

   function Method_Name (Verb : Method) return String is
     (case Verb is
         when Get => "GET", when Head => "HEAD", when Post => "POST", when Put => "PUT", when Patch => "PATCH",
         when Delete => "DELETE", when Options => "OPTIONS", when Other => "OTHER");

   --  The connection's name in debug lines: its reactor and its number there ("3-17").
   function Link_Name (Reactor, Number : Natural) return String is
     (Reactor'Image (2 .. Reactor'Image'Last) & "-" & Number'Image (2 .. Number'Image'Last));

   --  Connections open now, of every kind, and those of them that are event streams.
   function Total_Open return Long_Long_Integer is
     (Metrics.Value (Open_Connections (Http_Mode)) + Metrics.Value (Open_Connections (Stream_Mode))
      + Metrics.Value (Open_Connections (Socket_Mode)) + Metrics.Value (Open_Connections (Http_2_Mode)));

   procedure Set_Client (This : in out Exchange; Text : String) is begin
      This.Client_Length := Natural'Min (Text'Length, This.Client'Length);
      This.Client (1 .. This.Client_Length) := Text (Text'First .. Text'First + This.Client_Length - 1);
   end Set_Client;

   --  The address a proxy put last in X-Forwarded-For; "" when it does not look like one.
   function Forwarded_Client (Header : String) return String is
      First : Positive := Header'First;
      Last  : Natural := Header'Last;
   begin
      for Index in reverse Header'Range loop
         if Header (Index) = ',' then
            First := Index + 1;
            exit;
         end if;
      end loop;
      while First <= Last and then Header (First) = ' ' loop
         First := First + 1;
      end loop;
      while Last >= First and then Header (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      if Last - First + 1 not in 2 .. 64 then
         return "";
      end if;
      declare
         Candidate : String renames Header (First .. Last);
         Address   : IP_Address;
         Valid     : Boolean;
         Colon     : Natural := 0;
         Colons    : Natural := 0;
      begin
         Parse_Address (Candidate, Address, Valid);
         if not Valid then   --  some proxies add the port: "[2001:db8::1]:443", "192.0.2.1:443"
            for Index in Candidate'Range loop
               if Candidate (Index) = ':' then
                  Colon  := Index;
                  Colons := Colons + 1;
               end if;
            end loop;
            if Colon > Candidate'First + 1 and then Candidate (Candidate'First) = '['
              and then Candidate (Colon - 1) = ']'
            then
               Parse_Address (Candidate (Candidate'First .. Colon - 1), Address, Valid);
            elsif Colons = 1 and then Colon > Candidate'First then
               Parse_Address (Candidate (Candidate'First .. Colon - 1), Address, Valid);
               Valid := Valid and then Family_Of (Address) = Version_4;
            end if;
         end if;
         return (if Valid then Image (IO.Addresses.Unmapped (Address)) else "");
      end;
   end Forwarded_Client;

   --  A request has been read: give it its trace and note what the access log will say.
   procedure Begin_Request (This : in out Exchange; Peer : IP_Address; Request : Requests.Request) is
      Path : constant String := Requests.Path (Request);
   begin
      This.Trace := Log.Start_Trace (Requests.Header (Request, "X-Request-Id"),
                                     Requests.Header (Request, "traceparent"),
                                     Trust_Callers => Active_Settings.Trust_Trace);
      This.Pending_Log := True;
      This.Parsed      := True;
      This.Route_Index := 0;
      This.Requests_Seen := (if This.Requests_Seen = Natural'Last then 1 else This.Requests_Seen + 1);
      This.Log_Verb    := Requests.Verb (Request);
      This.Path_Length := Natural'Min (Path'Length, This.Log_Path'Length);
      This.Log_Path (1 .. This.Path_Length) := Path (Path'First .. Path'First + This.Path_Length - 1);
      This.Started     := Ada.Real_Time.Clock;
      This.Span_Started := (if Spans.Recording (This.Trace) then Spans.Now else 0);
      Set_Client (This, Image (Peer));
      if Active_Settings.Behind_Proxy then
         declare
            Forwarded : constant String := Forwarded_Client (Requests.Header (Request, "X-Forwarded-For"));
         begin
            if Forwarded'Length > 0 then
               Set_Client (This, Forwarded);
            end if;
         end;
      end if;
   end Begin_Request;

   --  Bytes that never made a request (refused with 400, 413, 431): logged all the same.
   procedure Begin_Unparsed (This : in out Exchange; Peer : IP_Address) is begin
      This.Trace       := Log.Start_Trace ("", "", Trust_Callers => False);
      This.Pending_Log := True;
      This.Parsed      := False;
      This.Path_Length := 0;
      This.Route_Index := 0;
      This.Started     := Ada.Real_Time.Clock;
      This.Span_Started := (if Spans.Recording (This.Trace) then Spans.Now else 0);
      Set_Client (This, Image (Peer));
   end Begin_Unparsed;

   --  The request's metrics, and its span when it is recorded.
   procedure Record_Request (This : in out Exchange; Status : Status_Code; Elapsed : Duration) is
      Routes : constant Route_Metrics_Access := By_Route;
   begin
      if Routes /= null and then This.Route_Index in Routes'Range then
         Metrics.Add (Routes (This.Route_Index).Requests (Natural (Status) / 100));
         Metrics.Observe (Routes (This.Route_Index).Latency, Elapsed);
      end if;
      if This.Span_Started /= 0 then
         declare
            Item  : Spans.Finished_Span;
            Route : constant String :=
              (if This.Route_Index > 0 and then Active_Routes /= null
               then Routers.Pattern (Active_Routes.all, This.Route_Index) else "");
            Verb  : constant String := (if This.Parsed then Method_Name (This.Log_Verb) else "HTTP");
         begin
            Item.Trace   := This.Trace;
            Item.Kind    := Spans.Server;
            Item.Started := This.Span_Started;
            Item.Ended   := This.Span_Started + Spans.Unix_Nanoseconds (Long_Float (Elapsed) * 1.0E9);
            Item.Failed  := Status >= 500 and then Status /= 499;
            Item.Verb    := This.Log_Verb;
            Item.Status  := Natural (Status);
            Spans.Put (Item.Name, Item.Name_Length, (if Route'Length > 0 then Verb & " " & Route else Verb));
            Spans.Put (Item.Route, Item.Route_Length, Route);
            Spans.Put (Item.Path, Item.Path_Length, This.Log_Path (1 .. This.Path_Length));
            This.Span_Started := 0;
            Spans.Finish (Item);
         end;
      end if;
   end Record_Request;

   procedure Access_Log (This : in out Exchange; Status : Status_Code; Bytes : Natural; Kind : String := "") is
      use type Ada.Real_Time.Time;
      Elapsed : constant Duration := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - This.Started);
      Level   : constant Logs.Level := (if Status >= 500 and then Status /= 499 then Logs.Error else Logs.Info);
   begin
      This.Pending_Log := False;
      Record_Request (This, Status, Elapsed);
      if not Active_Settings.Access_Log or else not Logs.Enabled (Level) then
         return;
      end if;
      --  Built in place: this runs for every request.
      declare
         Line       : Logs.Line_Builder (Capacity => 2048);
         Request_Id : constant String := Log.Request_Id (This.Trace);
      begin
         Logs.Start (Line, Level, "request");
         if Request_Id'Length > 0 then
            Logs.Add (Line, "request_id", Request_Id);
            if Request_Id /= Log.Trace_Id (This.Trace) then
               Logs.Add (Line, "trace_id", Log.Trace_Id (This.Trace));
            end if;
         end if;
         Logs.Add (Line, "method", (if This.Parsed then Method_Name (This.Log_Verb) else "-"));
         Logs.Add (Line, "path", (if This.Parsed then This.Log_Path (1 .. This.Path_Length) else "-"));
         Logs.Add (Line, "status", Long_Long_Integer (Status));
         Logs.Add (Line, "bytes", Long_Long_Integer (Bytes));
         Logs.Add (Line, "ms", Elapsed);
         Logs.Add (Line, "client", This.Client (1 .. This.Client_Length));
         if Kind'Length > 0 then
            Logs.Add (Line, "kind", Kind);
         end if;
         if This.Link_Number > 0 and then Logs.Enabled (Logs.Debug) then
            Logs.Add (Line, "connection", Link_Name (This.Link_Reactor, This.Link_Number));
            Logs.Add (Line, "nth", Long_Long_Integer (This.Requests_Seen));
         end if;
         Logs.Write (Line);
      end;
   end Access_Log;

   procedure Drop_Held (This : in out Connection) is
      Item : Job_Access := This.Held_First;
      Next : Job_Access;
   begin
      while Item /= null loop
         Next := Item.Next;
         Free (Item);
         Item := Next;
      end loop;
      This.Held_First := null;
      This.Held_Last  := null;
   end Drop_Held;

   procedure Set_Live (Owner : Reactor_State; Slot : Positive; Live_Now : Boolean) is begin
      Live (Owner.Id) (Slot) := Live_Value (if Live_Now then Owner.Slots (Slot).Generation + 1 else 0);
   end Set_Live;

   ---------------------------------------------------------------------------------------------------------------
   --  HTTP/2 lanes

   Http_2_Fill : constant := 65_536;   --  response data moved into a connection's output at a time

   procedure Set_Lane_Live
     (Owner : Reactor_State; Slot : Positive; Place : Http_2.Lane; Stream : Http_2.Stream_Id) is
   begin
      Lanes (Owner.Id) (Slot).Streams (Place) := Lane_Stream (Stream);
   end Set_Lane_Live;

   procedure Drop_Held (Item : in out Lane_State) is
      Held : Job_Access := Item.Held_First;
      Next : Job_Access;
   begin
      while Held /= null loop
         Next := Held.Next;
         Free (Held);
         Held := Next;
      end loop;
      Item.Held_First := null;
      Item.Held_Last  := null;
   end Drop_Held;

   --  The server owes the lane nothing more. Abandoned: its request was not answered (the client reset the
   --  stream, or left).
   procedure End_Lane (Owner : in out Reactor_State; Slot : Positive; Place : Http_2.Lane; Abandoned : Boolean) is
      Item : Lane_State renames Owner.Slots (Slot).Link.Lanes (Place);
   begin
      if Abandoned and then Item.Log.Pending_Log then
         Access_Log (Item.Log, 499, 0, "abandoned");
      end if;
      if Item.Body_Open then
         Lanes (Owner.Id) (Slot).Pipes (Place).Break (Client_Closed);   --  the handler reading it gets Body_Error
      end if;
      Drop_Held (Item);
      Set_Lane_Live (Owner, Slot, Place, 0);
      Item.Stream          := 0;
      Item.Busy            := False;
      Item.Streaming       := False;
      Item.Heartbeat       := False;
      Item.Body_Open       := False;
      Item.Log.Pending_Log := False;
   end End_Lane;

   procedure Close_Connection (Owner : in out Reactor_State; Slot : Positive) is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      if not This.Open then
         return;
      end if;
      if This.Mode = Http_2_Mode then
         for Place in Http_2.Lane loop
            if This.Link.Lanes (Place).Stream /= 0 then
               End_Lane (Owner, Slot, Place, Abandoned => True);
            end if;
         end loop;
         Http_2.Free (This.Link.Session);
      end if;
      This.Fresh := False;
      Set_Live (Owner, Slot, False);
      if This.Current.Pending_Log then
         Access_Log (This.Current, 499, 0, "abandoned");   --  the client left before its answer (nginx's 499)
      end if;
      if This.Mode = Socket_Mode and then This.Endpoint > 0 then
         --  Tell the endpoint, where its handlers run.
         declare
            Client : constant Connection_Id :=
              (Reactor => Owner.Id, Slot => Slot, Generation => This.Generation, Stream => 0);
         begin
            if Endpoints (This.Endpoint).Run = Routers.On_Reactor then
               Deliver_Close (This.Endpoint, Client);
            else
               declare
                  Item     : Job_Access := new Job;
                  Accepted : Boolean;
               begin
                  Item.Kind       := Socket_Closed;
                  Item.Endpoint   := This.Endpoint;
                  Item.Reactor    := Owner.Id;
                  Item.Slot       := Slot;
                  Item.Generation := This.Generation;
                  Work_Queue.Push (Item, Accepted);
                  if not Accepted then
                     Deliver_Close (Item.Endpoint, Client);
                     Free (Item);
                  end if;
               end;
            end if;
         end;
      end if;
      if This.Streaming then
         Pipes (Owner.Id) (Slot).Break (Client_Closed);   --  the handler reading it gets Body_Error
      end if;
      This.Streaming    := False;
      This.Decoding     := False;
      This.Body_Routed  := False;
      This.Body_Blocked := False;
      Metrics.Add (Open_Connections (This.Mode), -1);
      if Logs.Enabled (Logs.Debug) then
         declare
            Line : Logs.Line_Builder (Capacity => 512);
         begin
            Logs.Start (Line, Logs.Debug, "connection closed");
            Logs.Add (Line, "connection", Link_Name (This.Current.Link_Reactor, This.Current.Link_Number));
            Logs.Add (Line, "mode", (case This.Mode is
                                        when Http_Mode   => "http",      when Stream_Mode => "event stream",
                                        when Socket_Mode => "websocket", when Http_2_Mode => "http/2"));
            Logs.Add (Line, "by", (if This.Peer_Done then "client"
                                   elsif Owner.Now - This.Last_Activity >= Active_Settings.Idle_Timeout then "idle"
                                   else "server"));
            Logs.Add (Line, "requests", Long_Long_Integer (This.Current.Requests_Seen));
            Logs.Add (Line, "open_ms", Long_Long_Integer (Owner.Now - This.Opened_At));
            Logs.Add (Line, "open", Total_Open);
            Logs.Add (Line, "streams", Metrics.Value (Open_Connections (Stream_Mode)));
            Logs.Write (Line);
         end;
      end if;
      This.Mode         := Http_Mode;
      This.Endpoint     := 0;
      This.Heartbeat    := False;
      This.Message_Open := False;
      Free (This.Message);
      Drop_Held (This);
      Unwatch (Owner.Events, This.Socket);
      Tls.Free (This.Channel);
      Close (This.Socket);
      Owner.By_Socket.Exclude (This.Socket);
      This.Socket      := No_Descriptor;
      This.Open        := False;
      This.Busy        := False;
      This.Generation  := This.Generation + 1;   --  a job still out for it is dropped when it comes back
      This.Output_Sent := 0;
      Free (This.Input);
      Free (This.Output);
      Owner.Free_Total := Owner.Free_Total + 1;
      Owner.Free_Slots (Owner.Free_Total) := Slot;
      Owner.Active := Owner.Active - 1;
   end Close_Connection;

   --  Send what Output holds until it is all out or the socket refuses more.
   procedure Flush_Output (Owner : in out Reactor_State; Slot : Positive) is
      This    : Connection renames Owner.Slots (Slot).all;
      Count   : Integer;
      Done    : Natural;
      Result  : Tls.Outcome;
      Failure : Error;
   begin
      This.Wants_Write := False;
      <<Refill>>
      while This.Open and then Output_Pending (This) loop
         declare
            Rest : String renames This.Output.Data (This.Output_Sent + 1 .. This.Output.Length);
         begin
            if Tls.Is_Active (This.Channel) then
               Tls.Send (This.Channel, Rest, Done, Result);
               case Result is
                  when Tls.Done =>
                     This.Output_Sent := This.Output_Sent + Done;
                  when Tls.Want_Write | Tls.Want_Read =>
                     This.Wants_Write := Result = Tls.Want_Write;
                     exit;
                  when Tls.Closed | Tls.Failed =>
                     Close_Connection (Owner, Slot);
                     return;
               end case;
            else
               Send (This.Socket, Rest, Count, Failure);
               if Count >= 0 then
                  This.Output_Sent := This.Output_Sent + Count;
               elsif Failure.Kind = Would_Block then
                  This.Wants_Write := True;
                  exit;
               elsif Failure.Kind /= Interrupted then
                  Close_Connection (Owner, Slot);
                  return;
               end if;
            end if;
         end;
      end loop;

      if not Output_Pending (This) then
         This.Output_Sent := 0;
         if Capacity (This.Output) > Keep_Output_Capacity then
            Free (This.Output);
         else
            Clear (This.Output);
         end if;
         if This.Mode = Http_2_Mode and then not This.Close_After then
            --  More of the responses' bodies, as far as the client's windows allow.
            Http_2.Fill (This.Link.Session, This.Output, Http_2_Fill);
            if This.Output.Length > 0 then
               goto Refill;
            end if;
         end if;
         if This.Close_After and then not This.Busy then
            Close_Connection (Owner, Slot);
            return;
         end if;
      end if;
      Update_Interest (Owner, This);
   end Flush_Output;

   ---------------------------------------------------------------------------------------------------------------
   --  framing for streams (chunked) and sockets (RFC 6455)

   function Hex_Image (Value : Natural) return String is
      Digits_Of : constant String := "0123456789abcdef";
      Result    : String (1 .. 16);
      First     : Positive := Result'Last + 1;
      Rest      : Natural := Value;
   begin
      loop
         First := First - 1;
         Result (First) := Digits_Of (Rest mod 16 + 1);
         Rest := Rest / 16;
         exit when Rest = 0;
      end loop;
      return Result (First .. Result'Last);
   end Hex_Image;

   procedure Append_Chunk (Into : in out Buffer; Data : String) is begin
      if Data'Length > 0 then   --  an empty chunk would end the stream
         Append (Into, Hex_Image (Data'Length) & CRLF);
         Append (Into, Data);
         Append (Into, CRLF);
      end if;
   end Append_Chunk;

   --  One whole, unmasked frame (servers never mask).
   procedure Append_Frame (Into : in out Buffer; Opcode : Natural; Data : String) is
      Length : constant Natural := Data'Length;
   begin
      Append (Into, Character'Val (16#80# + Opcode));
      if Length < 126 then
         Append (Into, Character'Val (Length));
      elsif Length < 65_536 then
         Append (Into, Character'Val (126));
         Append_Big_Endian (Into, Unsigned_16 (Length));
      else
         Append (Into, Character'Val (127));
         Append_Big_Endian (Into, Unsigned_64 (Length));
      end if;
      Append (Into, Data);
   end Append_Frame;

   function Close_Payload (Code : Natural) return String is
     [Character'Val (Code / 256), Character'Val (Code mod 256)];

   --  Start closing a socket: the close frame, then the connection once it is out.
   procedure Close_Socket (Owner : in out Reactor_State; Slot : Positive; Code : Natural) is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      if not This.Close_After then
         Append_Frame (This.Output, Frames.Close, Close_Payload (Code));
         This.Close_After := True;
         Set_Live (Owner, Slot, False);
      end if;
      Flush_Output (Owner, Slot);
   end Close_Socket;

   --  End a stream: the last, empty chunk, then the connection.
   procedure End_Stream (Owner : in out Reactor_State; Slot : Positive) is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      if not This.Close_After then
         Append (This.Output, "0" & CRLF & CRLF);
         This.Close_After := True;
         Set_Live (Owner, Slot, False);
      end if;
      Flush_Output (Owner, Slot);
   end End_Stream;

   --  Data or a close for a live stream or socket.
   procedure Deliver_Push (Owner : in out Reactor_State; Slot : Positive; Item : Job) is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      if not This.Open or else This.Close_After then
         return;
      end if;
      case This.Mode is
         when Http_Mode | Http_2_Mode =>   --  HTTP/2 streams get theirs by Deliver_Lane_Push
            null;
         when Stream_Mode =>
            if Item.Kind = Push_Close then
               End_Stream (Owner, Slot);
               return;
            end if;
            Append_Chunk (This.Output, Content (Item.Data));
         when Socket_Mode =>
            if Item.Kind = Push_Close then
               Close_Socket (Owner, Slot, 1000);
               return;
            end if;
            Append_Frame (This.Output, (if Item.Binary then Frames.Binary else Frames.Text), Content (Item.Data));
            Metrics.Add (Messages_Out);
      end case;
      if This.Output.Overflowed or else This.Output.Length - This.Output_Sent > Max_Pending_Output then
         Metrics.Add (Slow_Dropped);
         Close_Connection (Owner, Slot);   --  a client that does not keep up
         return;
      end if;
      This.Last_Output := Owner.Now;
      Flush_Output (Owner, Slot);
   end Deliver_Push;

   --  Queue Response on the connection and start sending it.
   procedure Respond
     (Owner      : in out Reactor_State;
      Slot       : Positive;
      Response   : in out Responses.Response;
      Keep_Alive : Boolean;
      Is_Head    : Boolean)
   is
      This   : Connection renames Owner.Slots (Slot).all;
      Now    : Times.Unix_Seconds;
      Status : Status_Code := Response.Status;
      Bytes  : Natural := (if Is_Head then 0 else Response.Content.Length);
      Kind   : constant String :=
        (if Response.Mode = Stream and then not Is_Head then "stream"
         elsif Response.Mode = Upgrade and then Response.Status = 101 then "websocket" else "");
   begin
      if This.Current.Pending_Log and then This.Current.Trace.Id_Length > 0 and then Responses.Valid (Response) then
         Responses.Set_Header (Response, "X-Request-Id", Log.Request_Id (This.Current.Trace));
      end if;
      This.Close_After := This.Close_After or else not Keep_Alive or else Response.Close or else Stopping
                          or else not Responses.Valid (Response);
      IO.Process.Read_Clock (Now);
      if not Responses.Valid (Response) or else Response.Headers.Overflowed or else Response.Content.Overflowed then
         declare
            Failed : Responses.Response;
         begin
            Responses.Fail (Failed, Internal_Server_Error);
            Responses.Write_Head (Failed, This.Output, Now, Keep_Alive => False);
            Append (This.Output, Content (Failed.Content));
            Status := Internal_Server_Error;
            Bytes  := Failed.Content.Length;
            Responses.Free (Failed);
         end;
         Logs.Error ("a response was too large or malformed", Log.Trace_Fields (This.Current.Trace));
         Set_Live (Owner, Slot, False);
      elsif Response.Mode = Stream and then not Is_Head then
         Responses.Write_Head (Response, This.Output, Now, Keep_Alive => True);
         Append_Chunk (This.Output, Content (Response.Content));
         Change_Mode (This, Stream_Mode);
         if Logs.Enabled (Logs.Debug) then
            declare
               Line : Logs.Line_Builder (Capacity => 512);
            begin
               Logs.Start (Line, Logs.Debug, "event stream opened");
               Logs.Add (Line, "connection", Link_Name (This.Current.Link_Reactor, This.Current.Link_Number));
               Logs.Add (Line, "open", Total_Open);
               Logs.Add (Line, "streams", Metrics.Value (Open_Connections (Stream_Mode)));
               Logs.Write (Line);
            end;
         end if;
         This.Heartbeat   := Response.Heartbeat;
         This.Close_After := False;
         Set_Live (Owner, Slot, True);
      elsif Response.Mode = Upgrade and then Response.Status = 101
        and then Response.Endpoint in 1 .. Endpoint_Total
      then
         Responses.Write_Head (Response, This.Output, Now, Keep_Alive => True);
         Change_Mode (This, Socket_Mode);
         This.Endpoint    := Response.Endpoint;
         This.Close_After := False;
         This.Ping_Sent   := False;
         Set_Live (Owner, Slot, True);
      else
         Responses.Write_Head (Response, This.Output, Now, Keep_Alive => not This.Close_After);
         if not Is_Head then
            Append (This.Output, Content (Response.Content));
         end if;
         if This.Mode = Http_Mode then
            Set_Live (Owner, Slot, False);   --  a whole response: nothing more will be sent to it
         end if;
      end if;

      if This.Current.Pending_Log then
         Access_Log (This.Current, Status, Bytes, Kind);
      end if;
      if This.Output.Overflowed then
         Close_Connection (Owner, Slot);
         return;
      end if;
      This.Last_Activity := Owner.Now;
      This.Last_Output   := Owner.Now;

      --  What was sent to this connection while its response was being made: delivered now that it is a
      --  stream or socket, dropped if it is not.
      declare
         Item : Job_Access := This.Held_First;
         Next : Job_Access;
      begin
         This.Held_First := null;
         This.Held_Last  := null;
         while Item /= null loop
            Next := Item.Next;
            if This.Open and then This.Mode /= Http_Mode then
               Deliver_Push (Owner, Slot, Item.all);
            end if;
            Free (Item);
            Item := Next;
         end loop;
      end;
      if This.Open then
         Flush_Output (Owner, Slot);
      end if;
   end Respond;

   --  A response with only a status, for requests that never reach a handler.
   procedure Respond_Status (Owner : in out Reactor_State; Slot : Positive; Status : Status_Code; Close : Boolean) is
      Answer : Responses.Response;
   begin
      Responses.Fail (Answer, Status);
      Answer.Close := Close;
      Respond (Owner, Slot, Answer, Keep_Alive => not Close, Is_Head => False);
      Responses.Free (Answer);
   end Respond_Status;

   ---------------------------------------------------------------------------------------------------------------
   --  HTTP/2: the connection's session takes the bytes in and gives the requests out, and each lane's request
   --  goes the way an HTTP/1.1 request goes (routed, run here or on a worker, logged).

   procedure Begin_Http_2 (Owner : in out Reactor_State; Slot : Positive) is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      if This.Link = null then
         This.Link := new Http_2_State;
      end if;
      if Lanes (Owner.Id) = null then
         Lanes (Owner.Id) := new Lane_Slots'(Owner.Slots'Range => null);
      end if;
      if Lanes (Owner.Id) (Slot) = null then
         Lanes (Owner.Id) (Slot) := new Lane_Record;
      end if;
      This.Fresh := False;
      Change_Mode (This, Http_2_Mode);
      Set_Live (Owner, Slot, True);   --  pushes to its streams check the lanes too
      Http_2.Start (This.Link.Session, Parse_Limits, This.Output);
   end Begin_Http_2;

   --  The lane's pipe, made the first time the lane streams a body.
   function Lane_Pipe (Owner : Reactor_State; Slot : Positive; Place : Http_2.Lane) return Pipe_Access is
      Lane_Pipes : Lane_Record renames Lanes (Owner.Id) (Slot).all;
   begin
      if Lane_Pipes.Pipes (Place) = null then
         Lane_Pipes.Pipes (Place) := new Body_Pipe;
      end if;
      return Lane_Pipes.Pipes (Place);
   end Lane_Pipe;

   --  More for an event stream, or its end.
   procedure Deliver_Lane_Push (Owner : in out Reactor_State; Slot : Positive; Place : Http_2.Lane; Item : Job) is
      This : Connection renames Owner.Slots (Slot).all;
      Lane : Lane_State renames This.Link.Lanes (Place);
   begin
      if not Lane.Streaming then
         return;
      end if;
      if Item.Kind = Push_Close then
         Http_2.Finish (This.Link.Session, Place);
         End_Lane (Owner, Slot, Place, Abandoned => False);
         return;
      end if;
      Http_2.Push (This.Link.Session, Place, Content (Item.Data));
      Lane.Last_Output := Owner.Now;
      if Http_2.Pending_Data (This.Link.Session) > Max_Pending_Output then
         Metrics.Add (Slow_Dropped);
         Close_Connection (Owner, Slot);   --  a client that does not keep up
      end if;
   end Deliver_Lane_Push;

   --  Answer the lane's request with Response.
   procedure Respond_Http_2
     (Owner    : in out Reactor_State;
      Slot     : Positive;
      Place    : Http_2.Lane;
      Response : in out Responses.Response)
   is
      This      : Connection renames Owner.Slots (Slot).all;
      Lane      : Lane_State renames This.Link.Lanes (Place);
      Now       : Times.Unix_Seconds;
      Status    : Status_Code := Response.Status;
      Streaming : Boolean := Response.Mode = Stream and then not Lane.Is_Head;
      Lines     : Buffer;
      Length    : Long_Long_Integer;
      Bytes     : Natural;
   begin
      if Lane.Log.Pending_Log and then Lane.Log.Trace.Id_Length > 0 and then Responses.Valid (Response) then
         Responses.Set_Header (Response, "X-Request-Id", Log.Request_Id (Lane.Log.Trace));
      end if;
      if not Responses.Valid (Response) or else Response.Headers.Overflowed or else Response.Content.Overflowed
        or else (Response.Mode = Upgrade and then Response.Status = 101)   --  HTTP/2 has no upgrades
      then
         Logs.Error ("a response was too large or malformed, or an upgrade over HTTP/2",
                     Log.Trace_Fields (Lane.Log.Trace));
         Responses.Free (Response);
         Responses.Fail (Response, Internal_Server_Error);
         Status    := Internal_Server_Error;
         Streaming := False;
      end if;

      IO.Process.Read_Clock (Now);
      Append (Lines, "Date: ");
      Append (Lines, Times.Http_Date (Now));
      Append (Lines, CRLF);
      Append (Lines, Content (Response.Headers));
      Bytes  := (if Lane.Is_Head then 0 else Response.Content.Length);
      Length := (if Streaming or else Status < 200 or else Status in No_Content | Not_Modified then -1
                 else Long_Long_Integer (Response.Content.Length));
      if Lane.Is_Head then
         Clear (Response.Content);
      end if;
      Http_2.Respond (This.Link.Session, Place, Status, Content (Lines), Response.Content, Length,
                      Finished => not Streaming, Output => This.Output);
      Free (Lines);
      if Lane.Log.Pending_Log then
         Access_Log (Lane.Log, Status, Bytes, (if Streaming then "stream" else ""));
      end if;
      This.Last_Activity := Owner.Now;
      Lane.Busy := False;

      if Streaming then
         Lane.Streaming   := True;
         Lane.Heartbeat   := Response.Heartbeat;
         Lane.Last_Output := Owner.Now;
         declare
            Held : Job_Access := Lane.Held_First;
            Next : Job_Access;
         begin
            Lane.Held_First := null;
            Lane.Held_Last  := null;
            while Held /= null loop
               Next := Held.Next;
               if This.Open and then Lane.Streaming then
                  Deliver_Lane_Push (Owner, Slot, Place, Held.all);
               end if;
               Free (Held);
               Held := Next;
            end loop;
         end;
      else
         End_Lane (Owner, Slot, Place, Abandoned => False);
      end if;
   end Respond_Http_2;

   procedure Respond_Http_2_Status (Owner : in out Reactor_State; Slot : Positive; Place : Http_2.Lane;
                                    Status : Status_Code) is
      Answer : Responses.Response;
   begin
      Responses.Fail (Answer, Status);
      Respond_Http_2 (Owner, Slot, Place, Answer);
      Responses.Free (Answer);
   end Respond_Http_2_Status;

   --  Move a streamed body's bytes into its pipe, as many as it takes; finish or break it at the end.
   procedure Feed_Lane (Owner : in out Reactor_State; Slot : Positive; Place : Http_2.Lane) is
      This  : Connection renames Owner.Slots (Slot).all;
      Lane  : Lane_State renames This.Link.Lanes (Place);
      Pipe  : Body_Pipe renames Lanes (Owner.Id) (Slot).Pipes (Place).all;
      Taken : Natural;
   begin
      declare
         Data : constant String := Http_2.Received (This.Link.Session, Place);
      begin
         if Data'Length > 0 then
            Pipe.Put (Data, Taken);
            Http_2.Take_Body (This.Link.Session, Place, Taken, This.Output);
         end if;
      end;
      if Http_2.Body_Too_Long (This.Link.Session, Place) then
         Pipe.Break (Payload_Too_Large);
         Lane.Body_Open := False;
      elsif Http_2.Body_Ended (This.Link.Session, Place) then
         Pipe.Finish;
         Lane.Body_Open := False;
      end if;
   end Feed_Lane;

   --  A lane's request is read: its trace and log line begin.
   procedure Start_Lane
     (This : in out Connection; Place : Http_2.Lane; Stream : Http_2.Stream_Id; Request : in out Requests.Request)
   is
      Lane : Lane_State renames This.Link.Lanes (Place);
   begin
      Lane.Stream  := Stream;
      Lane.Is_Head := Requests.Verb (Request) = Head;
      Begin_Request (Lane.Log, This.Peer, Request);
      Requests.Set_Client_Address (Request, Lane.Log.Client (1 .. Lane.Log.Client_Length));
   end Start_Lane;

   --  Run the lane's handler: here, or on a worker.
   procedure Run_Lane
     (Owner : in out Reactor_State;
      Slot  : Positive;
      Place : Http_2.Lane;
      Item  : in out Job_Access;
      Route : Routers.Route_Match)
   is
      This     : Connection renames Owner.Slots (Slot).all;
      Lane     : Lane_State renames This.Link.Lanes (Place);
      Client   : constant Connection_Id :=
        (Reactor => Owner.Id, Slot => Slot, Generation => This.Generation, Stream => Natural (Lane.Stream));
      Accepted : Boolean;
   begin
      Lane.Busy := True;
      Set_Lane_Live (Owner, Slot, Place, Lane.Stream);   --  the handler may start a stream and add it to groups
      if Route.Run = Routers.On_Reactor then
         Call (Route.Action, Item.Request, Item.Response, Reactor_Task, Client, Lane.Log.Trace);
         Respond_Http_2 (Owner, Slot, Place, Item.Response);
         Free (Item);
         return;
      end if;
      Item.Action     := Route.Action;
      Item.Reactor    := Owner.Id;
      Item.Slot       := Slot;
      Item.Generation := This.Generation;
      Item.Stream     := Natural (Lane.Stream);
      Item.Trace      := Lane.Log.Trace;
      Work_Queue.Push (Item, Accepted);
      if not Accepted then
         Free (Item);
         Metrics.Add (Rejected);
         Respond_Http_2_Status (Owner, Slot, Place, Service_Unavailable);
      end if;
   end Run_Lane;

   --  A whole request on a lane.
   procedure Dispatch_Http_2 (Owner : in out Reactor_State; Slot : Positive; Place : Http_2.Lane;
                              Stream : Http_2.Stream_Id) is
      This  : Connection renames Owner.Slots (Slot).all;
      Lane  : Lane_State renames This.Link.Lanes (Place);
      Item  : Job_Access := new Job;
      Bytes : Buffer;
      Valid : Boolean;
      Route : Routers.Route_Match;
   begin
      Lane := (others => <>);
      Lane.Stream := Stream;
      Http_2.Take_Request (This.Link.Session, Place, Bytes);
      Requests.Load (Item.Request, Bytes, Valid);
      Free (Bytes);
      if not Valid then
         Free (Item);
         Begin_Unparsed (Lane.Log, This.Peer);
         Respond_Http_2_Status (Owner, Slot, Place, Bad_Request);
         return;
      end if;
      Start_Lane (This, Place, Stream, Item.Request);
      Routers.Find (Active_Routes.all, Item.Request, Route);
      Lane.Log.Route_Index := Route.Index;
      if Route.Action = null then
         Free (Item);
         Respond_Http_2_Status (Owner, Slot, Place, (if Route.Path_Matched then Method_Not_Allowed else Not_Found));
         return;
      end if;
      if Route.Body_Mode = Routers.Streamed then
         --  A request without a body to a route that streams: its handler reads an empty one.
         Requests.Set_Streamed (Item.Request);
         declare
            Pipe : constant Pipe_Access := Lane_Pipe (Owner, Slot, Place);
         begin
            Pipe.Open (This.Generation, Natural (Stream));
            Pipe.Finish;
         end;
      end if;
      Run_Lane (Owner, Slot, Place, Item, Route);
   end Dispatch_Http_2;

   --  A request's head, its body still coming, when some route streams: a streamed route gets the request now,
   --  a buffered one the whole request later.
   procedure Route_Http_2_Body
     (Owner : in out Reactor_State; Slot : Positive; Place : Http_2.Lane; Stream : Http_2.Stream_Id)
   is
      This  : Connection renames Owner.Slots (Slot).all;
      Lane  : Lane_State renames This.Link.Lanes (Place);
      Item  : Job_Access := new Job;
      Bytes : Buffer;
      Valid : Boolean;
      Route : Routers.Route_Match;
   begin
      Append (Bytes, Http_2.Head (This.Link.Session, Place));
      Append (Bytes, CRLF);
      Requests.Load_Head (Item.Request, Bytes, Valid);
      Free (Bytes);
      if Valid then
         Routers.Find (Active_Routes.all, Item.Request, Route);
      end if;
      if not Valid or else Route.Action = null or else Route.Body_Mode = Routers.Buffered then
         Free (Item);
         Http_2.Buffer_Body (This.Link.Session, Place, This.Output);
         return;
      end if;

      Http_2.Stream_Body (This.Link.Session, Place);
      Lane := (others => <>);
      Start_Lane (This, Place, Stream, Item.Request);
      Lane.Log.Route_Index := Route.Index;
      Lane_Pipe (Owner, Slot, Place).Open (This.Generation, Natural (Stream));
      Lane.Body_Open := True;
      Route.Run := Routers.On_Worker;   --  its handler waits for the body: never on the reactor
      Run_Lane (Owner, Slot, Place, Item, Route);
      if This.Open and then Lane.Body_Open and then Http_2.Holds (This.Link.Session, Place, Stream) then
         Feed_Lane (Owner, Slot, Place);   --  what came with the head
      end if;
   end Route_Http_2_Body;

   --  Act on what the session has seen, in order.
   procedure Handle_Http_2_Events (Owner : in out Reactor_State; Slot : Positive) is
      This : Connection renames Owner.Slots (Slot).all;
      Item : Http_2.Event;
   begin
      while This.Open loop
         Http_2.Next_Event (This.Link.Session, Item);
         exit when Item.Kind = Http_2.No_Event;
         declare
            Lane : Lane_State renames This.Link.Lanes (Item.Place);
            Held : constant Boolean := Http_2.Holds (This.Link.Session, Item.Place, Item.Stream);
         begin
            case Item.Kind is
               when Http_2.No_Event =>
                  null;
               when Http_2.Head_Ready =>
                  if Held then
                     if Route_Bodies then
                        Route_Http_2_Body (Owner, Slot, Item.Place, Item.Stream);
                     else
                        Http_2.Buffer_Body (This.Link.Session, Item.Place, This.Output);
                     end if;
                  end if;
               when Http_2.Request_Ready =>
                  if Held then
                     Dispatch_Http_2 (Owner, Slot, Item.Place, Item.Stream);
                  end if;
               when Http_2.Refused =>
                  if Held then
                     Lane := (others => <>);
                     Lane.Stream := Item.Stream;
                     Begin_Unparsed (Lane.Log, This.Peer);
                     Respond_Http_2_Status (Owner, Slot, Item.Place, Item.Status);
                  end if;
               when Http_2.Body_Ready =>
                  if Held and then Lane.Stream = Item.Stream and then Lane.Body_Open then
                     Feed_Lane (Owner, Slot, Item.Place);
                  end if;
               when Http_2.Stream_Reset =>
                  if Lane.Stream = Item.Stream then
                     End_Lane (Owner, Slot, Item.Place, Abandoned => True);
                  end if;
            end case;
         end;
      end loop;
   end Handle_Http_2_Events;

   --  After the session has changed: close a connection it is done with, and send what it has.
   procedure Settle_Http_2 (Owner : in out Reactor_State; Slot : Positive) is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      if not This.Open then
         return;
      end if;
      if Http_2.Failed (This.Link.Session) then
         This.Close_After := True;   --  once the GOAWAY is out
         Clear (This.Input);
      elsif This.Peer_Done
        or else (Http_2.Going_Away (This.Link.Session) and then Http_2.Open_Streams (This.Link.Session) = 0)
      then
         This.Close_After := True;
      end if;
      Flush_Output (Owner, Slot);
   end Settle_Http_2;

   procedure Process_Http_2 (Owner : in out Reactor_State; Slot : Positive) is
      This : Connection renames Owner.Slots (Slot).all;
      Used : Natural;
   begin
      if This.Input.Length > 0 and then not This.Close_After then
         Http_2.Receive (This.Link.Session, This.Input.Data (1 .. This.Input.Length), Owner.Now, Used, This.Output);
         if Used > 0 then
            Consume (This.Input, Used);
            This.Last_Activity := Owner.Now;
         end if;
      end if;
      Handle_Http_2_Events (Owner, Slot);
      Settle_Http_2 (Owner, Slot);
   end Process_Http_2;

   --  Hand a whole WebSocket message to its endpoint: here, or on a worker (reading pauses until it is done,
   --  so messages are handled in order).
   procedure Dispatch_Message (Owner : in out Reactor_State; Slot : Positive) is
      This : Connection renames Owner.Slots (Slot).all;
      Item : Job_Access := new Job;
   begin
      Item.Kind       := Socket_Message;
      Item.Endpoint   := This.Endpoint;
      Item.Binary     := This.Message_Kind;
      Item.Data       := This.Message;          --  the buffer moves to the job
      This.Message    := (others => <>);
      Item.Reactor    := Owner.Id;
      Item.Slot       := Slot;
      Item.Generation := This.Generation;
      Item.Trace      := This.Current.Trace;
      Metrics.Add (Messages_In);
      if Endpoints (This.Endpoint).Run = Routers.On_Reactor then
         if not Deliver_Message (Item.all, Reactor_Task) then
            Close_Socket (Owner, Slot, 1011);
         end if;
         Free (Item);
      else
         declare
            Accepted : Boolean;
         begin
            Work_Queue.Push (Item, Accepted);
            if Accepted then
               This.Busy := True;
               Update_Interest (Owner, This);
            else
               Free (Item);
               Metrics.Add (Rejected);
               Close_Socket (Owner, Slot, 1013);   --  try again later
            end if;
         end;
      end if;
   end Dispatch_Message;

   --  Read the frames in the input buffer (RFC 6455 5): answer pings and closes, gather messages.
   procedure Process_Frames (Owner : in out Reactor_State; Slot : Positive) is
      This    : Connection renames Owner.Slots (Slot).all;
      Largest : constant Natural :=
        Natural'Min (Endpoints (This.Endpoint).Max_Message,
                     Active_Settings.Limits.Max_Head_Length + Active_Settings.Limits.Max_Body_Length - 14);
   begin
      while This.Open and then not This.Busy and then not This.Close_After and then This.Input.Length >= 2 loop
         declare
            Data : String renames This.Input.Data (1 .. This.Input.Length);
            Head : constant Frames.Frame_Head := Frames.Read_Head (Data, Largest);
         begin
            case Head.Outcome is
               when Frames.Short =>
                  exit;
               when Frames.Refused =>
                  Close_Socket (Owner, Slot, Head.Close_Code);
                  return;
               when Frames.Whole_Head =>
                  null;
            end case;
            if This.Message_Open and then Head.Kind = Frames.Continuation
              and then Long_Long_Integer (This.Message.Length) + Long_Long_Integer (Head.Payload_Length)
                       > Long_Long_Integer (Largest)
            then
               Close_Socket (Owner, Slot, 1009);   --  the message so far is too big
               return;
            end if;

            declare
               Total  : constant Positive := Frames.Total_Length (Head);
               Final  : constant Boolean := Head.Final;
               Opcode : constant Natural := Head.Kind;
            begin
               if Data'Length < Total then
                  Reserve (This.Input, Total - This.Input.Length);
                  exit;
               end if;
               declare
                  Payload : constant String := Frames.Unmasked (Data, Head);
               begin
                  Consume (This.Input, Total);
                  This.Last_Activity := Owner.Now;
                  This.Ping_Sent     := False;

                  case Opcode is
                     when Frames.Continuation | Frames.Text | Frames.Binary =>
                        if (Opcode = 0) /= This.Message_Open then
                           Close_Socket (Owner, Slot, 1002);   --  a continuation of nothing, or a new message
                           return;                             --  inside one
                        end if;
                        if Opcode /= 0 then
                           This.Message_Open := True;
                           This.Message_Kind := Opcode = Frames.Binary;
                           Clear (This.Message);
                        end if;
                        Append (This.Message, Payload);
                        if Final then
                           This.Message_Open := False;
                           if not This.Message_Kind and then not Encoding.Valid_Utf8 (Content (This.Message)) then
                              Close_Socket (Owner, Slot, 1007);   --  a text message that is not UTF-8
                              return;
                           end if;
                           Dispatch_Message (Owner, Slot);
                        end if;
                     when Frames.Close =>
                        --  Answer with the same code (or none), then close.
                        Close_Socket (Owner, Slot, (if Payload'Length >= 2
                                                    then Character'Pos (Payload (1)) * 256
                                                         + Character'Pos (Payload (2))
                                                    else 1000));
                        return;
                     when Frames.Ping =>
                        Append_Frame (This.Output, Frames.Pong, Payload);
                        Flush_Output (Owner, Slot);
                     when Frames.Pong =>
                        null;
                     when others =>
                        Close_Socket (Owner, Slot, 1002);
                        return;
                  end case;
               end;
            end;
         end;
      end loop;
   end Process_Frames;

   --  Handle the requests in the input buffer while the connection is idle.
   ---------------------------------------------------------------------------------------------------------------
   --  request bodies

   --  How many bytes of chunk sizes, extensions and trailers a body of at most Limit bytes may come with.
   function Framing_For (Limit : Parser.Body_Size) return Natural is
     (Natural (Parser.Body_Size'Min (Parser.Body_Size (Natural'Last / 2),
                                     Parser.Body_Size (Active_Settings.Limits.Max_Head_Length) + Limit / 16)));

   --  Decode what has come of a chunked body, in place: Input (.. Chunk_Kept) ends with the body decoded so far,
   --  and is followed by nothing but, once the body is complete, what came after it (a pipelined request).
   procedure Decode_Chunks (This : in out Connection) is
      Scan     : Positive := This.Chunk_Kept + 1;
      Consumed : Natural;
      Content  : Encoding.Span;
      Size     : Natural;
   begin
      while Scan <= This.Input.Length and then This.Chunk.State not in Chunked.Done | Chunked.Failed loop
         Chunked.Decode (This.Chunk, This.Input.Data (Scan .. This.Input.Length), Consumed, Content);
         Size := Encoding.Length (Content);
         if Size > 0 then
            This.Input.Data (This.Chunk_Kept + 1 .. This.Chunk_Kept + Size) :=
              This.Input.Data (Content.First .. Content.Last);
            This.Chunk_Kept := This.Chunk_Kept + Size;
         end if;
         Scan := Scan + Consumed;
      end loop;
      if Scan > This.Chunk_Kept + 1 then   --  close the gap the framing left
         declare
            Rest : constant Natural := This.Input.Length - Scan + 1;
         begin
            This.Input.Data (This.Chunk_Kept + 1 .. This.Chunk_Kept + Rest) :=
              This.Input.Data (Scan .. This.Input.Length);
            Truncate (This.Input, This.Chunk_Kept + Rest);
         end;
      end if;
   end Decode_Chunks;

   --  A client that asked first ("Expect: 100-continue") is told to send its body.
   procedure Send_Continue (Owner : in out Reactor_State; Slot : Positive; Head : Parser.Request_Head) is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      if not This.Continue_Sent
        and then Encoding.Equal_Ignoring_Case
                   (Encoding.Slice (This.Input.Data (1 .. This.Input.Length),
                                    Parser.Header_Value (This.Input.Data (1 .. This.Input.Length), Head, "Expect")),
                    "100-continue")
      then
         This.Continue_Sent := True;
         Append (This.Output, "HTTP/1.1 100 Continue" & CRLF & CRLF);
         Flush_Output (Owner, Slot);
      end if;
   end Send_Continue;

   --  The slot's pipe, made the first time the slot streams a body, readied for this connection.
   procedure Open_Pipe (Owner : in out Reactor_State; Slot : Positive) is begin
      if Pipes (Owner.Id) = null then
         Pipes (Owner.Id) := new Pipe_Array'(Owner.Slots'Range => null);
      end if;
      if Pipes (Owner.Id) (Slot) = null then
         Pipes (Owner.Id) (Slot) := new Body_Pipe;
      end if;
      Pipes (Owner.Id) (Slot).Open (Owner.Slots (Slot).Generation);
   end Open_Pipe;

   --  Give a request to the workers; when they are all busy and the queue full, Accepted is False and the
   --  request is freed.
   procedure Hand_To_Worker
     (Owner      : in out Reactor_State;
      Slot       : Positive;
      Item       : in out Job_Access;
      Route      : Routers.Route_Match;
      Keep_Alive : Boolean;
      Accepted   : out Boolean)
   is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      Item.Action      := Route.Action;
      Item.Reactor     := Owner.Id;
      Item.Slot        := Slot;
      Item.Generation  := This.Generation;
      Item.Trace       := This.Current.Trace;
      This.Close_After := not Keep_Alive;
      Set_Live (Owner, Slot, True);
      Work_Queue.Push (Item, Accepted);
      if Accepted then
         This.Busy := True;
         Update_Interest (Owner, This);
      else
         Free (Item);
         Metrics.Add (Rejected);
      end if;
   end Hand_To_Worker;

   --  Move the body bytes that have arrived into the pipe, as many as it takes; finish or break it at the end.
   procedure Feed_Body (Owner : in out Reactor_State; Slot : Positive) is
      This  : Connection renames Owner.Slots (Slot).all;
      Pipe  : Body_Pipe renames Pipes (Owner.Id) (Slot).all;
      Ready : Natural;          --  body bytes at the start of Input
      Taken : Natural := 0;
   begin
      if This.Decoding then
         Decode_Chunks (This);
         Ready := This.Chunk_Kept;
      else
         Ready := Natural (Parser.Body_Size'Min (This.Body_Left, Parser.Body_Size (This.Input.Length)));
      end if;
      if Ready > 0 then
         Pipe.Put (This.Input.Data (1 .. Ready), Taken);
         Consume (This.Input, Taken);
         This.Last_Activity := Owner.Now;
         if This.Decoding then
            This.Chunk_Kept := This.Chunk_Kept - Taken;
         else
            This.Body_Left := This.Body_Left - Parser.Body_Size (Taken);
         end if;
      end if;
      This.Body_Blocked := Taken < Ready;

      if This.Decoding and then This.Chunk.State = Chunked.Failed then
         Pipe.Break (if This.Chunk.Too_Large then Payload_Too_Large else Bad_Request);
         This.Close_After := True;
         Clear (This.Input);
      elsif (if This.Decoding then This.Chunk.State = Chunked.Done and then This.Chunk_Kept = 0
             else This.Body_Left = 0)
      then
         Pipe.Finish;   --  what follows in Input is the next request
      elsif This.Peer_Done then
         Pipe.Break (Client_Closed);
         This.Close_After := True;
      else
         return;
      end if;
      This.Streaming    := False;
      This.Decoding     := False;
      This.Body_Blocked := False;
   end Feed_Body;

   --  A request with a body, when some route streams: look its route up before the body comes. A streamed
   --  route gets the request now (Handled); a buffered one waits for the whole body, refused (Handled) when it
   --  is longer than Max_Body_Length.
   procedure Route_Body
     (Owner   : in out Reactor_State;
      Slot    : Positive;
      Head    : Parser.Request_Head;
      Handled : out Boolean)
   is
      This     : Connection renames Owner.Slots (Slot).all;
      Bytes    : Buffer;
      Item     : Job_Access := new Job;
      Valid    : Boolean;
      Route    : Routers.Route_Match;
      Accepted : Boolean;
   begin
      Handled := False;
      Allocate (Bytes, Head.Head_Length);
      Append (Bytes, This.Input.Data (1 .. Head.Head_Length));
      Requests.Load_Head (Item.Request, Bytes, Valid);
      if Valid then
         Routers.Find (Active_Routes.all, Item.Request, Route);
      end if;
      if not Valid or else Route.Action = null or else Route.Body_Mode = Routers.Buffered then
         Free (Item);
         This.Body_Routed := True;
         if not Head.Chunked
           and then Head.Body_Length > Parser.Body_Size (Active_Settings.Limits.Max_Body_Length)
         then
            Handled := True;
            Begin_Unparsed (This.Current, This.Peer);
            Respond_Status (Owner, Slot, Payload_Too_Large, Close => True);
         end if;
         return;
      end if;

      Handled := True;
      Begin_Request (This.Current, This.Peer, Item.Request);
      Requests.Set_Client_Address (Item.Request, This.Current.Client (1 .. This.Current.Client_Length));
      This.Current.Route_Index := Route.Index;
      Send_Continue (Owner, Slot, Head);
      if not This.Open then
         Free (Item);
         return;
      end if;
      Open_Pipe (Owner, Slot);
      Consume (This.Input, Head.Head_Length);
      if Capacity (This.Input) < Stream_Input_Capacity then   --  read the body in large pieces
         Reserve (This.Input, Stream_Input_Capacity - This.Input.Length);
      end if;
      This.Continue_Sent := False;
      This.Streaming     := True;
      This.Body_Blocked  := False;
      This.Decoding      := Head.Chunked;
      This.Chunk_Kept    := 0;
      if Head.Chunked then
         declare
            Limit : constant Parser.Body_Size :=
              Parser.Body_Size'Min (Chunked.Largest_Body,
                                    Parser.Body_Size'Max (Parser.Body_Size (Active_Settings.Limits.Max_Body_Length),
                                                          Active_Settings.Limits.Max_Streamed_Length));
         begin
            This.Chunk := Chunked.New_Decoder (Limit, Framing_For (Limit));
         end;
      else
         This.Body_Left := Head.Body_Length;
      end if;

      Hand_To_Worker (Owner, Slot, Item, Route, Head.Keep_Alive, Accepted);
      if Accepted then
         Feed_Body (Owner, Slot);   --  what came with the head
      else
         This.Streaming := False;
         This.Decoding  := False;
         Respond_Status (Owner, Slot, Service_Unavailable, Close => True);
      end if;
   end Route_Body;

   procedure Process (Owner : in out Reactor_State; Slot : Positive) is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      case This.Mode is
         when Socket_Mode =>
            Process_Frames (Owner, Slot);
            return;
         when Stream_Mode =>
            Clear (This.Input);   --  a stream's client has nothing more to say; only its leaving matters
            if This.Peer_Done then
               Close_Connection (Owner, Slot);
            end if;
            return;
         when Http_2_Mode =>
            Process_Http_2 (Owner, Slot);
            return;
         when Http_Mode =>
            if This.Streaming then
               Feed_Body (Owner, Slot);
               return;
            end if;
            if This.Fresh and then This.Input.Length > 0 then
               --  HTTP/2 with prior knowledge (RFC 9113 3.3): the connection starts with the preface.
               declare
                  Seen : constant Natural := Natural'Min (This.Input.Length, Http_2.Preface'Length);
               begin
                  if Active_Settings.Http_2
                    and then This.Input.Data (1 .. Seen) = Http_2.Preface (1 .. Seen)
                  then
                     if Seen < Http_2.Preface'Length then
                        return;   --  the rest of it is coming
                     end if;
                     Begin_Http_2 (Owner, Slot);
                     Process_Http_2 (Owner, Slot);
                     return;
                  end if;
                  This.Fresh := False;
               end;
            end if;
      end case;

      while This.Open and then not This.Busy and then not Output_Pending (This) and then This.Input.Length > 0
        and then not This.Close_After and then This.Mode = Http_Mode
      loop
         declare
            Head  : constant Parser.Request_Head :=
              Parser.Parse_Head (This.Input.Data (1 .. This.Input.Length), Parse_Limits);
            Total : Positive;   --  the request's bytes at the start of Input, its body decoded
         begin
            case Head.Outcome is
               when Parser.Incomplete =>
                  return;
               when Parser.Invalid =>
                  Begin_Unparsed (This.Current, This.Peer);
                  Respond_Status (Owner, Slot, Head.Status, Close => True);
                  return;
               when Parser.Complete =>
                  null;
            end case;

            if Route_Bodies and then not This.Body_Routed and then (Head.Chunked or else Head.Body_Length > 0) then
               declare
                  Handled : Boolean;
               begin
                  Route_Body (Owner, Slot, Head, Handled);
                  if Handled then
                     return;
                  end if;
               end;
            end if;

            if Head.Chunked then
               if not This.Decoding then
                  This.Decoding   := True;
                  This.Chunk_Kept := Head.Head_Length;
                  This.Chunk      :=
                    Chunked.New_Decoder (Parser.Body_Size (Active_Settings.Limits.Max_Body_Length),
                                        Framing_For (Parser.Body_Size (Active_Settings.Limits.Max_Body_Length)));
                  Send_Continue (Owner, Slot, Head);
                  if not This.Open then
                     return;
                  end if;
               end if;
               Decode_Chunks (This);
               case This.Chunk.State is
                  when Chunked.Done =>
                     This.Decoding := False;
                     Total         := This.Chunk_Kept;
                  when Chunked.Failed =>
                     This.Decoding := False;
                     Begin_Unparsed (This.Current, This.Peer);
                     Respond_Status (Owner, Slot, (if This.Chunk.Too_Large then Payload_Too_Large else Bad_Request),
                                     Close => True);
                     return;
                  when others =>
                     return;   --  more to come: Read_Input makes room
               end case;
            elsif Head.Body_Length > Parser.Body_Size (This.Input.Length - Head.Head_Length) then
               --  The body is still coming.
               Send_Continue (Owner, Slot, Head);
               if This.Open then
                  Reserve (This.Input, Natural (Head.Body_Length) - (This.Input.Length - Head.Head_Length));
               end if;
               return;
            else
               Total := Head.Head_Length + Natural (Head.Body_Length);
            end if;

            declare
               Bytes      : Buffer;
               Item       : Job_Access := new Job;
               Valid      : Boolean;
               Route      : Routers.Route_Match;
               Keep_Alive : constant Boolean := Head.Keep_Alive;
               Is_Head    : constant Boolean := Head.Verb = Http.Head;
               Accepted   : Boolean;
            begin
               This.Continue_Sent := False;
               This.Body_Routed   := False;
               Allocate (Bytes, Total);
               Append (Bytes, This.Input.Data (1 .. Total));
               Consume (This.Input, Total);
               if This.Input.Length = 0 then
                  Free (This.Input);
               end if;

               Requests.Load (Item.Request, Bytes, Valid);
               if not Valid then   --  cannot happen: Total is exactly what the parser framed
                  Free (Item);
                  Begin_Unparsed (This.Current, This.Peer);
                  Respond_Status (Owner, Slot, Internal_Server_Error, Close => True);
                  return;
               end if;

               Begin_Request (This.Current, This.Peer, Item.Request);
               Requests.Set_Client_Address (Item.Request, This.Current.Client (1 .. This.Current.Client_Length));
               Routers.Find (Active_Routes.all, Item.Request, Route);
               This.Current.Route_Index := Route.Index;
               if Route.Action /= null and then Route.Body_Mode = Routers.Streamed then
                  --  A request without a body to a route that streams: its handler reads an empty one.
                  Requests.Set_Streamed (Item.Request);
                  Open_Pipe (Owner, Slot);
                  Pipes (Owner.Id) (Slot).Finish;
               end if;
               if Route.Action = null then
                  Free (Item);
                  Respond_Status (Owner, Slot, (if Route.Path_Matched then Method_Not_Allowed else Not_Found),
                                  Close => not Keep_Alive);
               elsif Route.Run = Routers.On_Reactor then
                  Set_Live (Owner, Slot, True);   --  the handler may start a stream and add it to groups
                  Call (Route.Action, Item.Request, Item.Response, Reactor_Task,
                        (Reactor => Owner.Id, Slot => Slot, Generation => This.Generation, Stream => 0),
                        This.Current.Trace);
                  Respond (Owner, Slot, Item.Response, Keep_Alive, Is_Head);
                  Free (Item);
               else
                  Hand_To_Worker (Owner, Slot, Item, Route, Keep_Alive, Accepted);
                  if not Accepted then
                     Respond_Status (Owner, Slot, Service_Unavailable, Close => not Keep_Alive);
                  end if;
               end if;
            end;
         end;
      end loop;

      if This.Open and then This.Peer_Done and then not This.Busy and then not Output_Pending (This) then
         Close_Connection (Owner, Slot);   --  the client is finished and nothing is owed
      end if;
   end Process;

   --  Read what the socket has, handling requests as they complete.
   procedure Read_Input (Owner : in out Reactor_State; Slot : Positive) is
      This      : Connection renames Owner.Slots (Slot).all;
      --  A little over a head and a body, for a chunked body's last framing.
      Max_Input : constant Natural :=
        Natural'Min (Buffers.Max_Capacity,
                     Active_Settings.Limits.Max_Head_Length + Active_Settings.Limits.Max_Body_Length + 64);
      Got       : Integer;
      Count     : Natural;
      Result    : Tls.Outcome;
      Failure   : Error;
   begin
      while This.Open and then not This.Peer_Done loop
         if Capacity (This.Input) = 0 then
            Allocate (This.Input, First_Input_Capacity);
         elsif This.Input.Length = Capacity (This.Input) then
            if This.Streaming then
               Feed_Body (Owner, Slot);
            end if;
         end if;
         if This.Input.Length < Capacity (This.Input) then
            null;
         elsif This.Streaming and then not This.Body_Blocked and then Capacity (This.Input) < Stream_Input_Capacity
         then
            Reserve (This.Input, Stream_Input_Capacity - Capacity (This.Input));
         else
            --  Full: wait for the request in flight (or the handler reading its body), or refuse a head that
            --  never ends.
            exit when This.Busy or else Output_Pending (This);
            if Capacity (This.Input) >= Max_Input then
               Process (Owner, Slot);   --  answers 431 or 413
               exit;
            end if;
            Reserve (This.Input, Natural'Min (Capacity (This.Input), Max_Input - Capacity (This.Input)));
         end if;
         exit when This.Input.Length >= Capacity (This.Input);

         declare
            Into : String renames This.Input.Data (This.Input.Length + 1 .. Capacity (This.Input));
         begin
            if Tls.Is_Active (This.Channel) then
               Tls.Receive (This.Channel, Into, Count, Result);
               case Result is
                  when Tls.Done                       => Got := Count;
                  when Tls.Want_Read | Tls.Want_Write => exit;
                  when Tls.Closed                     => Got := 0;
                  when Tls.Failed                     => Got := -1;
               end case;
               Failure := (Kind => (if Got < 0 then Other else None), Code => 0);
            else
               Receive (This.Socket, Into, Got, Failure);
            end if;
         end;

         if Got > 0 then
            Extend (This.Input, Got);
            Process (Owner, Slot);
         elsif Got = 0 then
            This.Peer_Done := True;
         elsif Failure.Kind = Would_Block then
            exit;
         elsif Failure.Kind /= Interrupted then
            Close_Connection (Owner, Slot);
            return;
         end if;
      end loop;

      if This.Open then
         Process (Owner, Slot);
      end if;
      if This.Open then
         if This.Input.Length = 0 then
            Free (This.Input);
         end if;
         Update_Interest (Owner, This);
      end if;
   end Read_Input;

   procedure Advance_Handshake (Owner : in out Reactor_State; Slot : Positive) is
      This   : Connection renames Owner.Slots (Slot).all;
      Result : Tls.Outcome;
   begin
      Tls.Handshake (This.Channel, Result);
      case Result is
         when Tls.Done =>
            This.Handshaking := False;
            This.Wants_Write := False;
            This.Last_Activity := Owner.Now;
            if Tls.Negotiated_Protocol (This.Channel) = "h2" then
               Begin_Http_2 (Owner, Slot);   --  the client chose HTTP/2 by ALPN
            end if;
         when Tls.Want_Read | Tls.Want_Write =>
            This.Wants_Write := Result = Tls.Want_Write;
         when Tls.Closed | Tls.Failed =>
            Close_Connection (Owner, Slot);
            return;
      end case;
      Update_Interest (Owner, This);
   end Advance_Handshake;

   procedure On_Client_Event (Owner : in out Reactor_State; Slot : Positive; Item : Event) is
      This : Connection renames Owner.Slots (Slot).all;
   begin
      if This.Handshaking then
         Advance_Handshake (Owner, Slot);
         if not This.Open or else This.Handshaking then
            return;
         end if;
      end if;

      if Output_Pending (This) then
         Flush_Output (Owner, Slot);
      end if;
      if This.Open and then not Output_Pending (This) then
         Read_Input (Owner, Slot);
      end if;

      if This.Open and then Item.Closed and then not Item.Readable and then not This.Busy then
         Close_Connection (Owner, Slot);   --  an error or hang-up with nothing left to read
      end if;
   end On_Client_Event;

   --  The reactor's mail: responses and finished messages back from workers, and what other tasks send to
   --  streams and sockets, in the order it was posted.
   procedure On_Mail (Owner : in out Reactor_State) is
      Item : Job_Access;
      Next : Job_Access;
   begin
      Mailboxes (Owner.Id).Take_All (Item);
      while Item /= null loop
         Next      := Item.Next;
         Item.Next := null;
         declare
            Slot    : constant Positive := Item.Slot;
            This    : Connection renames Owner.Slots (Slot).all;
            Current : constant Boolean := This.Open and then This.Generation = Item.Generation;
         begin
            case Item.Kind is
               when Handle_Request =>
                  if Current and then This.Mode = Http_2_Mode then
                     declare
                        Stream : constant Http_2.Stream_Id := Http_2.Stream_Id (Item.Stream);
                        Place  : constant Natural := Http_2.Place_Of (This.Link.Session, Stream);
                     begin
                        if Place /= 0 and then This.Link.Lanes (Place).Stream = Stream
                          and then This.Link.Lanes (Place).Busy
                        then
                           Respond_Http_2 (Owner, Slot, Place, Item.Response);
                           Settle_Http_2 (Owner, Slot);
                        end if;   --  otherwise the client reset the stream meanwhile
                     end;
                  elsif Current and then This.Busy then
                     This.Busy := False;
                     if This.Streaming then   --  answered before reading the whole body: close after
                        Pipes (Owner.Id) (Slot).Break (Client_Closed);
                        This.Streaming    := False;
                        This.Decoding     := False;
                        This.Body_Blocked := False;
                        This.Close_After  := True;
                        Clear (This.Input);
                     end if;
                     Respond (Owner, Slot, Item.Response, Keep_Alive => not This.Close_After,
                              Is_Head => Requests.Verb (Item.Request) = Head);
                     if This.Open and then not Output_Pending (This) then
                        Read_Input (Owner, Slot);
                     end if;
                  end if;   --  otherwise the client went away meanwhile
               when Socket_Message =>
                  if Current and then This.Busy then
                     This.Busy := False;
                     if Item.Binary then   --  the handler failed
                        Close_Socket (Owner, Slot, 1011);
                     elsif This.Close_After then   --  the handler closed it
                        Flush_Output (Owner, Slot);
                     elsif This.Open and then not Output_Pending (This) then
                        Read_Input (Owner, Slot);
                     end if;
                  end if;
               when Push_Data | Push_Close =>
                  if Current and then This.Mode = Http_2_Mode then
                     declare
                        Stream : constant Http_2.Stream_Id := Http_2.Stream_Id (Item.Stream);
                        Place  : constant Natural := Http_2.Place_Of (This.Link.Session, Stream);
                     begin
                        if Stream /= 0 and then Place /= 0 and then This.Link.Lanes (Place).Stream = Stream then
                           declare
                              Lane : Lane_State renames This.Link.Lanes (Place);
                           begin
                              if Lane.Busy then
                                 --  Its response is still being made: hold on to it.
                                 if Lane.Held_Last = null then
                                    Lane.Held_First := Item;
                                 else
                                    Lane.Held_Last.Next := Item;
                                 end if;
                                 Lane.Held_Last := Item;
                                 Item := null;
                              else
                                 Deliver_Lane_Push (Owner, Slot, Place, Item.all);
                                 Settle_Http_2 (Owner, Slot);
                              end if;
                           end;
                        end if;
                     end;
                  elsif Current and then This.Mode = Http_Mode and then This.Busy then
                     --  The response that makes it a stream or socket is still being made: hold on to it.
                     if This.Held_Last = null then
                        This.Held_First := Item;
                     else
                        This.Held_Last.Next := Item;
                     end if;
                     This.Held_Last := Item;
                     Item := null;
                  elsif Current then
                     Deliver_Push (Owner, Slot, Item.all);
                  end if;
               when Body_Wanted =>
                  if Current and then This.Mode = Http_2_Mode then
                     declare
                        Place : constant Natural :=
                          Http_2.Place_Of (This.Link.Session, Http_2.Stream_Id (Item.Stream));
                     begin
                        if Place /= 0 and then This.Link.Lanes (Place).Body_Open then
                           Feed_Lane (Owner, Slot, Place);
                           Settle_Http_2 (Owner, Slot);
                        end if;
                     end;
                  elsif Current and then This.Streaming then
                     This.Body_Blocked  := False;
                     This.Last_Activity := Owner.Now;
                     Feed_Body (Owner, Slot);
                     if This.Open and then not This.Body_Blocked then
                        Read_Input (Owner, Slot);
                     else
                        Update_Interest (Owner, This);
                     end if;
                  end if;
               when Socket_Closed =>
                  null;
            end case;
         end;
         Free (Item);
         Item := Next;
      end loop;
   end On_Mail;

   procedure Accept_All (Owner : in out Reactor_State) is
      Socket  : Descriptor;
      Peer    : IP_Address;
      Failure : Error;
      Slot    : Positive;
   begin
      loop
         Accept_Client (Owner.Listener, Socket, Peer, Failure);
         if Socket = No_Descriptor then
            if Failure.Kind in Out_Of_Descriptors | Out_Of_Memory then
               --  Out of descriptors: stop listening for a moment instead of spinning on the listener.
               Unwatch (Owner.Events, Owner.Listener);
               Owner.Listening    := False;
               Owner.Paused_Until := Owner.Now + Pause_On_Exhaustion;
            end if;
            return;
         elsif Owner.Free_Total = 0 then
            Close (Socket);   --  full: refuse
            Metrics.Add (Refused);
         else
            Slot             := Owner.Free_Slots (Owner.Free_Total);
            Owner.Free_Total := Owner.Free_Total - 1;
            Owner.Active     := Owner.Active + 1;
            if Owner.Slots (Slot) = null then
               Owner.Slots (Slot) := new Connection;
            end if;
            declare
               This : Connection renames Owner.Slots (Slot).all;
            begin
               This.Socket        := Socket;
               This.Open          := True;
               This.Fresh         := True;
               This.Busy          := False;
               This.Close_After   := False;
               This.Peer_Done     := False;
               This.Wants_Write   := False;
               This.Continue_Sent := False;
               This.Streaming     := False;
               This.Decoding      := False;
               This.Body_Routed   := False;
               This.Body_Blocked  := False;
               This.Output_Sent   := 0;
               This.Mode          := Http_Mode;
               Metrics.Add (Open_Connections (Http_Mode), 1);
               This.Peer          := Peer;
               This.Current.Trace         := No_Trace;
               This.Current.Pending_Log   := False;
               Owner.Accepted := (if Owner.Accepted = Natural'Last then 1 else Owner.Accepted + 1);
               This.Current.Link_Reactor  := Natural (Owner.Id);
               This.Current.Link_Number   := Owner.Accepted;
               This.Current.Requests_Seen := 0;
               if Logs.Enabled (Logs.Debug) then
                  declare
                     Line : Logs.Line_Builder (Capacity => 512);
                  begin
                     Logs.Start (Line, Logs.Debug, "connection opened");
                     Logs.Add (Line, "connection", Link_Name (Natural (Owner.Id), Owner.Accepted));
                     Logs.Add (Line, "client", Image (Peer));
                     Logs.Add (Line, "open", Total_Open);
                     Logs.Add (Line, "streams", Metrics.Value (Open_Connections (Stream_Mode)));
                     Logs.Write (Line);
                  end;
               end if;
               This.Opened_At     := Owner.Now;
               This.Last_Activity := Owner.Now;
               This.Handshaking   := Active_Security /= null;
               This.Watched       := (Readable => True, Writable => Edge_Triggered);
               Owner.By_Socket.Include (Socket, Slot);
               Watch (Owner.Events, Socket, This.Watched);
               if This.Handshaking then
                  Tls.Start_Server (This.Channel, Active_Security.all, Tls.Socket_Handle (Socket));
                  if not Tls.Is_Active (This.Channel) then
                     Close_Connection (Owner, Slot);
                  else
                     Advance_Handshake (Owner, Slot);
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Accept_All;

   --  Close what has waited too long: a handshake past Handshake_Timeout, a connection with nothing in flight
   --  past Idle_Timeout.
   procedure Sweep (Owner : in out Reactor_State) is begin
      for Slot in Owner.Slots'Range loop
         exit when Owner.Slots (Slot) = null;   --  slots are taken in order, so the rest were never used
         declare
            This : Connection renames Owner.Slots (Slot).all;
            Idle : constant Milliseconds := Owner.Now - This.Last_Activity;
         begin
            if This.Open and then This.Streaming and then not This.Body_Blocked
              and then Idle > Active_Settings.Idle_Timeout
            then
               Close_Connection (Owner, Slot);   --  an upload that stalled: its handler gets Body_Error
            elsif This.Open and then not This.Busy then
               case This.Mode is
                  when Http_Mode =>
                     if (This.Handshaking and then Owner.Now - This.Opened_At > Active_Settings.Handshake_Timeout)
                       or else Idle > Active_Settings.Idle_Timeout
                       or else (Stopping and then not Output_Pending (This))
                     then
                        Close_Connection (Owner, Slot);
                     end if;
                  when Stream_Mode =>
                     --  Streams stay open while the client does; a heartbeat finds out when it has gone.
                     if Stopping then
                        End_Stream (Owner, Slot);
                     elsif This.Heartbeat and then Owner.Now - This.Last_Output > Active_Settings.Idle_Timeout / 2
                     then
                        Append_Chunk (This.Output, ":" & ASCII.LF & ASCII.LF);
                        This.Last_Output := Owner.Now;
                        Flush_Output (Owner, Slot);
                     end if;
                  when Http_2_Mode =>
                     declare
                        Link : Http_2_State renames This.Link.all;
                     begin
                        if Stopping
                          or else (Http_2.Open_Streams (Link.Session) = 0 and then Idle > Active_Settings.Idle_Timeout)
                        then
                           Http_2.Go_Away (Link.Session, This.Output);
                        end if;
                        for Place in Http_2.Lane loop
                           declare
                              Lane : Lane_State renames Link.Lanes (Place);
                           begin
                              if Lane.Streaming and then Stopping then
                                 Http_2.Finish (Link.Session, Place);
                                 End_Lane (Owner, Slot, Place, Abandoned => False);
                              elsif Lane.Streaming and then Lane.Heartbeat
                                and then Owner.Now - Lane.Last_Output > Active_Settings.Idle_Timeout / 2
                              then
                                 Http_2.Push (Link.Session, Place, ":" & ASCII.LF & ASCII.LF);
                                 Lane.Last_Output := Owner.Now;
                              end if;
                           end;
                        end loop;
                        Settle_Http_2 (Owner, Slot);
                     end;
                  when Socket_Mode =>
                     --  Quiet for half the idle timeout: ping; quiet for all of it: gone.
                     if Stopping then
                        Close_Socket (Owner, Slot, 1001);
                     elsif Idle > Active_Settings.Idle_Timeout then
                        Close_Connection (Owner, Slot);
                     elsif Idle > Active_Settings.Idle_Timeout / 2 and then not This.Ping_Sent then
                        This.Ping_Sent := True;
                        Append_Frame (This.Output, Frames.Ping, "");
                        Flush_Output (Owner, Slot);
                     end if;
               end case;
            end if;
         end;
      end loop;
   end Sweep;

   task type Reactor is
      entry Start (Id : Reactor_Index);
   end Reactor;

   task body Reactor is
      Owner      : Reactor_State;
      Found      : Event_Array (1 .. 256);
      Count      : Natural;
      Failure    : Error;
      Next_Sweep : Milliseconds := 0;
      Deadline   : Milliseconds := 0;   --  when stopping: give up on what is still in flight
      Max        : constant Positive := Active_Settings.Max_Connections;
   begin
      accept Start (Id : Reactor_Index) do
         Owner.Id := Id;
      end Start;

      Owner.Listener   := Listeners (Owner.Id);
      Owner.Slots      := new Connection_Array'(1 .. Max => null);
      Owner.Free_Slots := new Slot_Array'(1 .. Max => 0);
      for Slot in 1 .. Max loop
         Owner.Free_Slots (Slot) := Max - Slot + 1;   --  slot 1 is taken first
      end loop;
      Owner.Free_Total := Max;

      Open (Owner.Events, Failure);
      if not Succeeded (Failure) then
         raise Program_Error with "cannot open a poller: " & Message (Failure);   --  logged below
      end if;
      Watch (Owner.Events, Owner.Listener);
      Owner.Listening := True;
      Watch (Owner.Events, Watched_End (Wakers (Owner.Id)));
      if Owner.Id = 1 and then Is_Open (Termination) then
         Watch (Owner.Events, Watched_End (Termination));
      end if;

      loop
         Wait (Owner.Events, Found, (if Owner.Paused_Until > 0 or else Stopping then 100 else 1000), Count);
         IO.Process.Read_Monotonic (Owner.Now);

         for Index in 1 .. Count loop
            declare
               Item : constant Event := Found (Index);
            begin
               if Item.Item = Owner.Listener then
                  if Owner.Listening and then not Stopping then
                     Accept_All (Owner);
                  end if;
               elsif Item.Item = Watched_End (Wakers (Owner.Id)) then
                  Drain (Wakers (Owner.Id));
                  On_Mail (Owner);
               elsif Is_Open (Termination) and then Item.Item = Watched_End (Termination) then
                  Drain (Termination);
                  Stop;
               else
                  declare
                     Position : constant Slot_Maps.Cursor := Owner.By_Socket.Find (Item.Item);
                  begin
                     if Slot_Maps.Has_Element (Position) then
                        On_Client_Event (Owner, Slot_Maps.Element (Position), Item);
                     end if;
                  end;
               end if;
            end;
         end loop;

         if Owner.Paused_Until > 0 and then Owner.Now >= Owner.Paused_Until and then not Stopping then
            Owner.Paused_Until := 0;
            Watch (Owner.Events, Owner.Listener);
            Owner.Listening := True;
            Accept_All (Owner);
         end if;

         if Stopping then
            if Deadline = 0 then
               Deadline := Owner.Now + Shutdown_Grace;
               if Owner.Listening then
                  Unwatch (Owner.Events, Owner.Listener);
                  Owner.Listening := False;
               end if;
               On_Mail (Owner);
               Sweep (Owner);
            end if;
            Sweep (Owner);
            exit when Owner.Active = 0 or else Owner.Now >= Deadline;
         elsif Owner.Now >= Next_Sweep then
            Next_Sweep := Owner.Now + Sweep_Interval;
            Sweep (Owner);
         end if;
      end loop;

      for Slot in Owner.Slots'Range loop
         exit when Owner.Slots (Slot) = null;
         Close_Connection (Owner, Slot);
         Free (Owner.Slots (Slot).Link);
         Free (Owner.Slots (Slot));
      end loop;
      Close (Owner.Events);
      Free (Owner.Slots);
      Free (Owner.Free_Slots);
   exception
      when Occurrence : others =>
         Log_Failure ("reactor" & Owner.Id'Image, Occurrence);
         Stop;
   end Reactor;

   ---------------------------------------------------------------------------------------------------------------
   --  Run

   procedure Free is new Ada.Unchecked_Deallocation (Waker_Array, Waker_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Mailbox_Array, Mailbox_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Listener_Array, Listener_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Body_Pipe, Pipe_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Pipe_Array, Pipe_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Pipe_Table, Pipe_Table_Access);

   --  The server's metrics, sparrow_http_*: declared on the first Run, found again on later ones.
   procedure Declare_Metrics (Routes : Routers.Router) is
      use Metrics;
      Class_Names : constant array (Class_Counters'Range) of String (1 .. 3) := ["1xx", "2xx", "3xx", "4xx", "5xx"];
      Table       : constant Route_Metrics_Access := new Route_Metrics_Array (0 .. Routers.Route_Count (Routes));
   begin
      for Index in Table'Range loop
         declare
            Route : constant Labels :=
              (if Index = 0 then Label ("method", "") & Label ("route", "")
               else Label ("method", Method_Name (Routers.Verb (Routes, Index)))
                    & Label ("route", Routers.Pattern (Routes, Index)));
         begin
            for Class in Class_Counters'Range loop
               Table (Index).Requests (Class) :=
                 New_Counter ("sparrow_http_requests_total", "Requests answered, by route and status class.",
                              Route & Label ("status", Class_Names (Class)));
            end loop;
            Table (Index).Latency :=
              New_Histogram ("sparrow_http_request_duration_seconds",
                             "Time from a request's last byte to its response's first, by route.",
                             With_Labels => Route);
         end;
      end loop;
      Open_Connections :=
        [Http_Mode   => New_Gauge ("sparrow_http_connections", "Open connections, by mode.", Label ("mode", "http")),
         Stream_Mode => New_Gauge ("sparrow_http_connections", "Open connections, by mode.", Label ("mode", "stream")),
         Socket_Mode => New_Gauge ("sparrow_http_connections", "Open connections, by mode.",
                                   Label ("mode", "websocket")),
         Http_2_Mode => New_Gauge ("sparrow_http_connections", "Open connections, by mode.", Label ("mode", "http2"))];
      Queue_Depth  := New_Gauge ("sparrow_http_queue_depth", "Requests and messages waiting for a worker.");
      Rejected     := New_Counter ("sparrow_http_rejected_total",
                                   "Requests (503) and WebSocket messages (1013) refused: the queue was full.");
      Refused      := New_Counter ("sparrow_http_refused_connections_total",
                                   "Connections refused: every connection slot was taken.");
      Slow_Dropped := New_Counter ("sparrow_http_slow_clients_dropped_total",
                                   "Streams and WebSockets closed for falling too far behind.");
      Messages_In  := New_Counter ("sparrow_http_websocket_messages_total", "WebSocket messages, by direction.",
                                   Label ("direction", "in"));
      Messages_Out := New_Counter ("sparrow_http_websocket_messages_total", "WebSocket messages, by direction.",
                                   Label ("direction", "out"));
      By_Route := Table;
   end Declare_Metrics;

   procedure Run
     (Settings : Configuration;
      Routes   : Routers.Router;
      Hooks    : Worker_Hooks := No_Hooks;
      Security : access constant Tls.Context := null)
   is
      Reactor_Total : constant Positive :=
        (if Settings.Reactors = 0 then IO.Process.Processor_Count else Settings.Reactors);
      Shared        : constant Boolean := Reactor_Total = 1 or else not Shares_Ports;
      Failure       : Error;
      Ready         : Boolean;
      All_Started   : Boolean;

      procedure Release is begin
         if Listeners /= null then
            for Index in Listeners'Range loop
               if Listeners (Index) /= No_Descriptor and then (not Shared or else Index = Listeners'First) then
                  Close (Listeners (Index));
               end if;
            end loop;
            Free (Listeners);
         end if;
         if Wakers /= null then
            for Item of Wakers.all loop
               Close (Item);
            end loop;
            Free (Wakers);
         end if;
         if Is_Open (Termination) then
            Close (Termination);
         end if;
         Live := null;   --  its arrays (a few words per connection slot) are left: GNAT will not free atomics
         Lanes := null;  --  the same; a lane's pipes (made only for streamed bodies) with it
         Free (Mailboxes);
         if Pipes /= null then   --  every task that could read them has ended
            for Each of Pipes.all loop
               if Each /= null then
                  for Pipe of Each.all loop
                     Free (Pipe);
                  end loop;
                  Free (Each);
               end if;
            end loop;
            Free (Pipes);
         end if;
      end Release;

   begin
      if Security /= null and then not Tls.Is_Open (Security.all) then
         raise Start_Error with "the TLS context is not open";
      end if;

      Active_Settings := Settings;
      Route_Bodies    := Routers.Has_Streamed_Body (Routes);
      Parse_Limits    := Settings.Limits;
      if not Route_Bodies then
         Parse_Limits.Max_Streamed_Length := 0;
      end if;
      Active_Routes   := Routes'Unrestricted_Access;
      Active_Hooks    := Hooks;
      --  Run returns only after every task that reads these has ended, so the caller's objects outlive them.
      Active_Security := (if Security = null then null else Security.all'Unrestricted_Access);
      Stopping        := False;
      Declare_Metrics (Routes);
      Work_Queue.Reset;

      IO.Process.Prepare_Networking (Ready);
      if not Ready then
         raise Start_Error with "the system's networking cannot be started";
      end if;

      Listeners := new Listener_Array'(1 .. Reactor_Total => No_Descriptor);
      for Index in Listeners'Range loop
         if Shared and then Index > 1 then
            Listeners (Index) := Listeners (1);
         else
            Open_Listener (Settings.Address, Settings.Port, Listeners (Index), Failure, Share_Port => not Shared);
            if not Succeeded (Failure) then
               Release;
               raise Start_Error with "cannot listen on port" & Settings.Port'Image & ": " & Message (Failure);
            end if;
         end if;
      end loop;

      Wakers    := new Waker_Array (1 .. Reactor_Total);
      Mailboxes := new Mailbox_Array (1 .. Reactor_Total);
      Live      := new Live_Table (1 .. Reactor_Total);
      Pipes     := new Pipe_Table'(1 .. Reactor_Total => null);
      Lanes     := new Lane_Table'(1 .. Reactor_Total => null);
      for Index in Live'Range loop
         Live (Index) := new Live_Array'[1 .. Settings.Max_Connections => 0];
      end loop;
      for Item of Wakers.all loop
         Open (Item, Failure);
         if not Succeeded (Failure) then
            Release;
            raise Start_Error with "cannot open a waker: " & Message (Failure);
         end if;
      end loop;
      if Settings.Catch_Signals then
         Open (Termination, Failure);
         if Succeeded (Failure) then
            Signal_On_Termination (Termination);
         end if;
      end if;

      Startup.Reset (Natural (Settings.Workers));
      declare
         Worker_Tasks : array (1 .. Settings.Workers) of Worker;
      begin
         for Id in Worker_Tasks'Range loop
            Worker_Tasks (Id).Start (Id);
         end loop;
         Startup.Wait (All_Started);

         if All_Started then
            --  What the server holds: a slot table per reactor up front, and a connection record (plus its
            --  buffers, from 4 KiB as data arrives) for each connection open at once at the busiest moment.
            Logs.Info ("server started",
                       Logs.Field ("address", Image (Settings.Address)),
                       Logs.Field ("port", Long_Long_Integer (Settings.Port)),
                       Logs.Field ("reactors", Long_Long_Integer (Reactor_Total)),
                       Logs.Field ("workers", Long_Long_Integer (Settings.Workers)),
                       Logs.Field ("max_connections", Long_Long_Integer (Reactor_Total * Settings.Max_Connections)),
                       Logs.Field ("slot_tables_kb", Long_Long_Integer (Reactor_Total) * Long_Long_Integer
                                     (Settings.Max_Connections) * Slot_Table_Bytes / 1024)
                       & Logs.Field ("bytes_per_connection", Long_Long_Integer (Connection'Size / 8)));
            declare
               Reactor_Tasks : array (1 .. Reactor_Total) of Reactor;
            begin
               for Id in Reactor_Tasks'Range loop
                  Reactor_Tasks (Id).Start (Id);
               end loop;
            end;   --  waits for every reactor
         end if;
         Work_Queue.Close;
      end;   --  waits for every worker

      --  Jobs no reactor came back for (the shutdown's grace ran out).
      for Item of Mailboxes.all loop
         declare
            Chain, Next : Job_Access;
         begin
            Item.Take_All (Chain);
            while Chain /= null loop
               Next := Chain.Next;
               Free (Chain);
               Chain := Next;
            end loop;
         end;
      end loop;
      Release;
      Active_Routes   := null;
      Active_Security := null;
      declare
         Done : Route_Metrics_Access := By_Route;
      begin
         By_Route := null;
         Free (Done);
      end;
      Logs.Flush;   --  the last requests' lines, before Run returns

      if not All_Started then
         raise Start_Error with "a worker's On_Start failed";
      end if;
   end Run;

   ----------
   -- Stop --
   ----------

   function Is_Stopping return Boolean is (Stopping);

   procedure Stop is
      Current : constant Waker_Array_Access := Wakers;
   begin
      Stopping := True;
      if Current /= null then
         for Item of Current.all loop
            if Is_Open (Item) then
               Signal (Item);
            end if;
         end loop;
      end if;
   end Stop;

   ----------------------
   -- From_Environment --
   ----------------------

   function From_Environment (Defaults : Configuration := (others => <>)) return Configuration is
      Result : Configuration := Defaults;

      function Number (Name : String; Low, High : Long_Long_Integer; Default : Long_Long_Integer)
                       return Long_Long_Integer
      is
         Value : Long_Long_Integer;
         Valid : Boolean;
      begin
         Encoding.Parse_Decimal (IO.Process.Environment (Name), Value, Valid);
         return (if Valid and then Value in Low .. High then Value else Default);
      end Number;

      --  on, true, yes, 1 / off, false, no, 0; anything else keeps Default.
      function Switch (Name : String; Default : Boolean) return Boolean is
         Value : constant String := Ada.Characters.Handling.To_Lower (IO.Process.Environment (Name));
      begin
         return (if Value in "on" | "true" | "yes" | "1" then True
                 elsif Value in "off" | "false" | "no" | "0" then False
                 else Default);
      end Switch;

      Address : IP_Address;
      Valid   : Boolean;
   begin
      Parse_Address (IO.Process.Environment ("HOST"), Address, Valid);
      if Valid then
         Result.Address := Address;
      end if;
      Result.Port     := Port_Number (Number ("PORT", 1, 65_535, Long_Long_Integer (Defaults.Port)));
      Result.Reactors := Natural (Number ("REACTORS", 0, 1024, Long_Long_Integer (Defaults.Reactors)));
      Result.Workers  := Worker_Id (Number ("WORKERS", 1, Long_Long_Integer (Worker_Id'Last),
                                            Long_Long_Integer (Defaults.Workers)));
      Result.Access_Log   := Switch ("ACCESS_LOG", Defaults.Access_Log);
      Result.Trust_Trace  := Switch ("TRUST_TRACE", Defaults.Trust_Trace);
      Result.Behind_Proxy := Switch ("BEHIND_PROXY", Defaults.Behind_Proxy);
      Result.Http_2       := Switch ("HTTP_2", Defaults.Http_2);
      Result.Compression  := Switch ("COMPRESSION", Defaults.Compression);
      return Result;
   end From_Environment;

end Sparrow.Http.Servers;
