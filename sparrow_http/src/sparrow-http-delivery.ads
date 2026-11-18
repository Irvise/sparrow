--  What the server's tasks pass to one another, shared by the server and by the units that send to a
--  connection later (Streams, Websockets): jobs, each reactor's mailbox and waker, which connections are live
--  streams or sockets, and the registered WebSocket endpoints.
--
--  A reactor owns its connections; everything else reaches them only by posting a job to its mailbox and
--  signalling its waker. The mailbox keeps order, so what one task sends to a connection arrives in order.
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Http.Routers;
with Sparrow.IO.Events;

private package Sparrow.Http.Delivery is

   subtype Reactor_Index is Positive;

   type Job_Kind is
     (Handle_Request,    --  to a worker: run Action; back: send Response
      Push_Data,         --  to a reactor: send Data on a stream or socket
      Push_Close,        --  to a reactor: end a stream, close a socket
      Socket_Message,    --  to a worker: a WebSocket message for its endpoint; back: carry on reading
      Socket_Closed,     --  to a worker: tell the endpoint a socket closed; not sent back
      Body_Wanted);      --  to a reactor: a handler made room in a full body pipe, so read the socket again

   type Job;
   type Job_Access is access Job;

   type Job is limited record
      Kind       : Job_Kind := Handle_Request;
      Request    : Requests.Request;
      Response   : Responses.Response;
      Action     : Routers.Route_Handler_Access;
      Data       : Buffer;                --  Push_Data, Socket_Message
      Binary     : Boolean := False;      --  Push_Data, Socket_Message: a binary WebSocket frame
      Endpoint   : Natural := 0;          --  Socket_Message, Socket_Closed
      Reactor    : Reactor_Index := 1;
      Slot       : Positive := 1;
      Generation : Natural := 0;          --  of the connection when the job left; a different one means it closed
      Stream     : Natural := 0;          --  the HTTP/2 stream it is for; 0: the connection itself
      Trace      : Trace_Context := No_Trace;   --  Handle_Request, Socket_Message: the request's, for its logs
      Next       : Job_Access;
   end record;

   procedure Free (Item : in out Job_Access);

   function Id_Of (Item : Job) return Connection_Id;

   --  Jobs on their way to one reactor, oldest first.
   protected type Mailbox is
      procedure Push (Item : in out Job_Access);
      procedure Take_All (Chain : out Job_Access);   --  oldest first
   private
      First, Last : Job_Access;
   end Mailbox;

   type Mailbox_Array is array (Reactor_Index range <>) of Mailbox;
   type Mailbox_Array_Access is access Mailbox_Array;
   type Waker_Array is array (Reactor_Index range <>) of IO.Events.Waker;
   type Waker_Array_Access is access Waker_Array;

   Mailboxes : Mailbox_Array_Access;   --  set by Run while the server runs
   Wakers    : Waker_Array_Access;

   --  Post Item to the reactor it names and wake that reactor; Item is freed when no server is running.
   procedure Post (Item : in out Job_Access);

   ---------------------------------------------------------------------------------------------------------------
   --  Which connections are open streams or sockets: Live (Reactor) (Slot) is the connection's generation + 1
   --  while it is one, 0 otherwise. Written by the reactor, read by any task.

   type Live_Value is new Natural with Atomic;
   type Live_Array is array (Positive range <>) of Live_Value;
   type Live_Array_Access is access Live_Array;
   type Live_Table is array (Reactor_Index range <>) of Live_Array_Access;
   type Live_Table_Access is access Live_Table;

   Live : Live_Table_Access;

   function Is_Live (Id : Connection_Id) return Boolean;

   ---------------------------------------------------------------------------------------------------------------
   --  WebSocket endpoints, registered as their packages elaborate (before any server runs).

   type Endpoint_Handlers is abstract tagged limited null record;
   procedure On_Message
     (This    : Endpoint_Handlers;
      Socket  : Connection_Id;
      Message : String;
      Binary  : Boolean;
      Context : Call_Context) is abstract;
   procedure On_Close (This : Endpoint_Handlers; Socket : Connection_Id) is abstract;

   type Endpoint_Handlers_Access is access all Endpoint_Handlers'Class;

   type Endpoint_Entry is record
      Handlers    : Endpoint_Handlers_Access;
      Run         : Routers.Placement := Routers.On_Worker;
      Max_Message : Positive := 1;
   end record;

   Max_Endpoints : constant := 64;
   type Endpoint_Table is array (1 .. Max_Endpoints) of Endpoint_Entry;

   Endpoints      : Endpoint_Table;
   Endpoint_Total : Natural := 0;

   --  Program_Error past Max_Endpoints.
   function Register (Item : Endpoint_Entry) return Positive;

   ---------------------------------------------------------------------------------------------------------------
   --  Streamed request bodies: the reactor puts the bytes in as they arrive, the handler's worker takes them out.
   --  A slot's pipe is made the first time that slot streams a body, and kept.

   Pipe_Capacity : constant := 65_536;
   Client_Closed : constant Status_Code := 499;   --  why a pipe broke when the client left (nginx's code)

   type Pipe_State is (Flowing, Finished, Broken);

   protected type Body_Pipe is
      --  The reactor's side. Open readies the pipe for a request of the connection's Generation (and Stream, for
      --  HTTP/2).
      procedure Open (Generation : Natural; Stream : Natural := 0);
      --  As much of Data as fits; when not all, the next Take that makes room says so (Wanted_More).
      procedure Put (Data : String; Taken : out Natural);
      procedure Finish;                      --  the body is complete: Take reports the end once it is drained
      procedure Break (Status : Status_Code);   --  the client left (Client_Closed) or sent a bad or too long body

      --  The worker's side: waits for bytes, the end or a break. Last < Into'First at the end. Wanted_More: the
      --  reactor is waiting for room, so post it a Body_Wanted job.
      entry Take
        (Generation  : Natural;
         Stream      : Natural;
         Into        : out String;
         Last        : out Natural;
         State       : out Pipe_State;
         Status      : out Status_Code;
         Wanted_More : out Boolean);
   private
      Data        : String (1 .. Pipe_Capacity);
      First       : Positive := 1;   --  the oldest byte; the bytes wrap round
      Length      : Natural := 0;
      Current     : Pipe_State := Broken;
      Why         : Status_Code := Client_Closed;
      Owner       : Natural := 0;    --  the generation of the connection it serves
      Owner_Stream : Natural := 0;   --  and the HTTP/2 stream
      Waiting     : Boolean := False;
   end Body_Pipe;

   ---------------------------------------------------------------------------------------------------------------
   --  HTTP/2 connections: which stream holds each of the connection's lanes (Http_2.Lane), so that other tasks can
   --  tell a live stream, and each lane's pipe for a streamed body. Made for a slot the first time it serves
   --  HTTP/2, and kept while the server runs. Streams (Lane) is written by the reactor: the stream holding the lane
   --  while it is answered or open as an event stream, 0 otherwise.

   Max_Lanes : constant := 100;   --  Http_2.Max_Streams

   type Lane_Stream is new Natural with Atomic;
   type Lane_Stream_Array is array (1 .. Max_Lanes) of Lane_Stream;

   type Pipe_Access is access Body_Pipe;
   type Lane_Pipe_Array is array (1 .. Max_Lanes) of Pipe_Access with Atomic_Components;

   type Lane_Record is limited record
      Streams : Lane_Stream_Array := [others => 0];
      Pipes   : Lane_Pipe_Array := [others => null];
   end record;

   type Lane_Access is access Lane_Record;
   type Lane_Slots is array (Positive range <>) of Lane_Access with Atomic_Components;
   type Lane_Slots_Access is access Lane_Slots;
   type Lane_Table is array (Reactor_Index range <>) of Lane_Slots_Access;
   type Lane_Table_Access is access Lane_Table;

   Lanes : Lane_Table_Access;   --  set by Run; Lanes (Reactor) (Slot) by the reactor

   --  The lane of Id's connection that holds Id.Stream; 0 when none does.
   function Lane_Of (Id : Connection_Id) return Natural;

   type Pipe_Array is array (Positive range <>) of Pipe_Access;
   type Pipe_Array_Access is access Pipe_Array;
   type Pipe_Table is array (Reactor_Index range <>) of Pipe_Array_Access;
   type Pipe_Table_Access is access Pipe_Table;

   Pipes : Pipe_Table_Access;   --  set by Run; Pipes (Reactor) by that reactor when it first streams a body

end Sparrow.Http.Delivery;
