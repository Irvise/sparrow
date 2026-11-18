--  A client of Valkey (and of Redis, which speaks the same protocol): a cache, counters, short-lived keys, and a
--  place to keep sessions that several servers share (Sparrow.Valkey.Sessions).
--
--     Cache : Valkey.Connection;
--     ...
--     Valkey.Connect (Cache, Valkey.Server_At (Environment ("VALKEY_URL")));
--     Valkey.Set (Cache, "greeting", "hello", Lifetime => 60);
--     ... Valkey.Get (Cache, "greeting") ...
--
--  A connection belongs to one task and is blocking: give each worker its own (see
--  Sparrow.Http.Servers.Worker_Hooks), and never use one on a reactor.
--
--  The helpers (Get, Set, ...) cover the everyday commands and raise Command_Error when the server refuses one.
--  Any other command is built with Start and Add, and its reply read with Read_Reply; commands started before a
--  Read_Reply go out together, and their replies come back in order (a pipeline):
--
--     Valkey.Start (Cache, "HINCRBY"); Valkey.Add (Cache, "visits"); Valkey.Add (Cache, Page); Valkey.Add (Cache, 1);
--     Valkey.Read_Reply (Cache, Answer);
--     if Valkey.Kind (Answer) = Valkey.Number then ... Valkey.Number (Answer) ...
--
--  Connection_Error is raised when there is no answer: the host does not resolve, the connection, TLS or the
--  password fails, the time runs out or the server sends something that is not the protocol. The connection is
--  then closed; Connect it again to go on.
with Sparrow.Buffers;
with Sparrow.IO;
with Sparrow.Tls;
with Sparrow.Valkey_Protocol;
private with Ada.Finalization;
private with Ada.Strings.Unbounded;
private with Sparrow.IO.Sockets;

package Sparrow.Valkey is

   Connection_Error : exception;
   Command_Error    : exception;   --  a helper's command was refused; the message is the server's

   --  Where the server is, and how to reach it.
   type Server is private;

   --  valkey://[[user]:password@]host[:port][/database], or valkeys:// for TLS (redis:// and rediss:// are
   --  understood too). The port is 6379 unless given; user and password are percent-encoded. Trust_File is a PEM
   --  file of root certificates for TLS ("" for the system's); Timeout bounds the connect and each reply, in
   --  milliseconds. Constraint_Error for a URL of any other form.
   function Server_At (Url : String; Trust_File : String := ""; Timeout : Positive := 5_000) return Server;

   type Connection is limited private;

   function Is_Connected (This : Connection) return Boolean;

   --  Connect, sign in and select the database (or ask for a PING): Connection_Error when any of it fails, so a
   --  server that is misconfigured or wants a password shows at once.
   procedure Connect (This : in out Connection; Where : Server)
      with Post => Is_Connected (This);

   --  Close the connection (also done when This goes out of scope). Commands not yet read are dropped.
   procedure Close (This : in out Connection)
      with Post => not Is_Connected (This);

   ---------------------------------------------------------------------------------------------------------------
   --  The everyday commands. Lifetimes are in seconds. Each waits for its reply, so none can run while replies
   --  to commands built with Start are still due.

   function Replies_Due (This : Connection) return Natural;   --  commands sent or started, replies not yet read
   function Ready (This : Connection) return Boolean is (Is_Connected (This) and then Replies_Due (This) = 0);

   --  The value of Key, or Default when there is none.
   function Get (This : in out Connection; Key : String; Default : String := "") return String
      with Pre => Ready (This);

   --  Keep Value under Key: for Lifetime seconds, or until deleted when Lifetime is 0.
   procedure Set (This : in out Connection; Key : String; Value : String; Lifetime : Natural := 0)
      with Pre => Ready (This);

   procedure Delete (This : in out Connection; Key : String)
      with Pre => Ready (This);

   function Exists (This : in out Connection; Key : String) return Boolean
      with Pre => Ready (This);

   --  Add By to the number under Key (0 when there is none) and return the sum: a counter.
   function Increment (This : in out Connection; Key : String; By : Long_Long_Integer := 1) return Long_Long_Integer
      with Pre => Ready (This);

   --  Increment, and give Key a lifetime of Lifetime seconds when it has none, both at once: a counter for a
   --  window that starts at its first increment ("1000 calls an hour", failed logins in the last 15 minutes).
   function Increment
     (This : in out Connection; Key : String; By : Long_Long_Integer := 1; Lifetime : Positive)
      return Long_Long_Integer
      with Pre => Ready (This);

   --  Keep Value under Key only when Key does not exist; True when it did not and now holds Value. Run once
   --  (an idempotency key, a webhook already seen) or a short lock (Value: a token naming the holder).
   function Set_If_Absent
     (This : in out Connection; Key : String; Value : String; Lifetime : Natural := 0) return Boolean
      with Pre => Ready (This);

   --  End Key after Lifetime seconds; False when there is no Key.
   function Expire (This : in out Connection; Key : String; Lifetime : Positive) return Boolean
      with Pre => Ready (This);

   ---------------------------------------------------------------------------------------------------------------
   --  Any command.

   --  Begin a command named Name ("HSET", "LPUSH", ...); Add gives its arguments, in order.
   procedure Start (This : in out Connection; Name : String)
      with Pre => Is_Connected (This) and then Name'Length > 0;

   procedure Add (This : in out Connection; Argument : String)
      with Pre => Is_Connected (This);
   procedure Add (This : in out Connection; Argument : Long_Long_Integer)
      with Pre => Is_Connected (This);

   --  Send the commands started so far without waiting for their replies (Read_Reply sends them too).
   procedure Flush (This : in out Connection)
      with Pre => Is_Connected (This);

   type Reply is private;

   --  The reply to the oldest command not yet read, after sending any started ones. It can be read until the
   --  next Read_Reply. A command the server refuses is not an exception but an Error reply.
   procedure Read_Reply (This : in out Connection; Answer : out Reply)
      with Pre => Is_Connected (This) and then Replies_Due (This) > 0;

   type Reply_Kind is
     (Status,    --  a short answer such as OK
      Error,     --  the command was refused: Text says why
      Number,
      Text,      --  a string, of any bytes
      Nil,       --  no value (a key that does not exist)
      List);     --  Count replies, each read with Item

   function Kind (Answer : Reply) return Reply_Kind;

   function Text (This : Connection; Answer : Reply) return String
      with Pre => Kind (Answer) in Status | Error | Text;

   function Number (Answer : Reply) return Long_Long_Integer
      with Pre => Kind (Answer) = Number;

   function Count (Answer : Reply) return Natural
      with Pre => Kind (Answer) = List;

   function Item (This : Connection; Answer : Reply; Index : Positive) return Reply
      with Pre => Kind (Answer) = List and then Index <= Count (Answer);

private

   use Ada.Strings.Unbounded;

   type Server is record
      Host       : Unbounded_String;
      Port       : IO.Sockets.Port_Number := 6379;
      User       : Unbounded_String;
      Password   : Unbounded_String;
      Database   : Natural := 0;
      Use_Tls    : Boolean := False;
      Trust_File : Unbounded_String;
      Timeout    : Positive := 5_000;
   end record;

   type Reply is record
      Kind : Reply_Kind := Nil;
      Item : Valkey_Protocol.Element;   --  in the connection's input
   end record;

   type Connection is new Ada.Finalization.Limited_Controlled with record
      Socket       : IO.Descriptor := IO.No_Descriptor;
      Use_Tls      : Boolean := False;
      Context      : Tls.Context;
      Session      : Tls.Session;
      Name         : Unbounded_String;          --  host:port, for messages
      Output       : Buffers.Buffer;            --  commands to send
      Arguments    : Buffers.Buffer;            --  the arguments of the command being built
      Argument_Sum : Natural := 0;
      Building     : Boolean := False;          --  a command is started and not yet in Output
      Sent         : Natural := 0;              --  commands in Output, or sent, whose replies are due
      Input        : Buffers.Buffer;            --  received bytes
      Taken        : Natural := 0;              --  bytes of Input already read as replies
   end record;

   overriding procedure Finalize (This : in out Connection);

   function Is_Connected (This : Connection) return Boolean is (IO."/=" (This.Socket, IO.No_Descriptor));

   function Replies_Due (This : Connection) return Natural is (This.Sent + (if This.Building then 1 else 0));

   function Kind (Answer : Reply) return Reply_Kind is (Answer.Kind);
   function Number (Answer : Reply) return Long_Long_Integer is (Answer.Item.Number);
   function Count (Answer : Reply) return Natural is (Natural (Answer.Item.Number));

end Sparrow.Valkey;
