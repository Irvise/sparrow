--  A PostgreSQL client over the system's libpq (16 or later): named prepared statements, pipelined groups of
--  statements each closed by a Sync, binary parameters and results. libpq does the protocol, authentication,
--  TLS and host failover; this unit decides the shape: statements are typed, parameters are built in place,
--  and results are copied once into a buffer the proved decoders of Sparrow.Postgres_Wire read.
--
--  A connection belongs to one task and is blocking: give each worker its own (see
--  Sparrow.Http.Servers.Worker_Hooks).
--
--  Text parameters and text results are UTF8_String: the session's client_encoding is UTF8, so that is what
--  the server accepts and sends. bytea goes as bytes.
--
--  SPARK spec; the body calls C and is not proved, the value decoders it hands results to are. Failures of the
--  connection raise Connection_Error, and only from the subprograms that say so; a statement the server rejects
--  is not an exception but a result that did not succeed. Building a pipeline is total: a statement that cannot
--  be built (parameters not matching it, or past the buffer's limit) makes the next Flush fail instead.
--
--  The short way, one statement at a time:
--
--     Bind (Db, Find_User); Add_Parameter (Db, Email); Execute (Db);
--     Fetch (Db, Rows);
--     if Rows.Succeeded and then Rows.Row_Count = 1 then ... Text (Db, Field_At (Db, Rows, 1, 1)) ...
--
--  The fast way: Bind/Execute any number of statements, Sync, Flush once, then Read_Results once per Sync.
with Interfaces; use Interfaces;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Postgres_Wire;
with Sparrow.Times; use Sparrow.Times;
private with System;

--  GNAT 13 does not know Exceptional_Cases (it only matters to SPARK callers): keep its builds quiet.
pragma Warnings (Off, """Exceptional_Cases"" is not a valid aspect identifier");

--  Server is the database as proved callers see it: everything libpq sends and receives on the connections.
--  It is external (another program changes it) and synchronized (each task uses its own connection).
package Sparrow.Postgres
  with SPARK_Mode, Abstract_State => (Server with Synchronous, External), Initializes => Server
is

   Connection_Error : exception;

   type Type_Oid is new Unsigned_32;
   Bool_Oid        : constant Type_Oid := 16;
   Bytea_Oid       : constant Type_Oid := 17;
   Int8_Oid        : constant Type_Oid := 20;
   Int2_Oid        : constant Type_Oid := 21;
   Int4_Oid        : constant Type_Oid := 23;
   Text_Oid        : constant Type_Oid := 25;
   Json_Oid        : constant Type_Oid := 114;
   Float4_Oid      : constant Type_Oid := 700;
   Float8_Oid      : constant Type_Oid := 701;
   Timestamptz_Oid : constant Type_Oid := 1184;
   Bool_Array_Oid  : constant Type_Oid := 1000;
   Int4_Array_Oid  : constant Type_Oid := 1007;
   Text_Array_Oid  : constant Type_Oid := 1009;
   Int8_Array_Oid  : constant Type_Oid := 1016;

   type Type_Oid_Array is array (Positive range <>) of Type_Oid;

   No_Parameters : constant Type_Oid_Array (1 .. 0) := [others => 0];

   subtype Parameter_Total is Natural range 0 .. 2 ** 16 - 1;

   --  A named prepared statement and the types of its parameters $1 .. $Parameter_Count. Declare statements
   --  as library-level constants and Prepare them on each connection after Connect.
   --
   --     Find_User : aliased constant Statement := Define ("find_user", "select id, name from users where email = $1");
   --
   --  Without Parameter_Types the server infers each parameter's type from the SQL, and Prepare asks for them;
   --  give them (or cast in SQL: $1::int8) only where the SQL leaves a type open, as in "select $1".
   type Statement (Name_Length, Text_Length : Positive; Parameter_Count : Parameter_Total) is record
      Name            : String (1 .. Name_Length);
      Text            : String (1 .. Text_Length);
      Parameter_Types : Type_Oid_Array (1 .. Parameter_Count);
   end record;

   function Define (Name, Text : String; Parameter_Types : Type_Oid_Array := No_Parameters) return Statement is
     (Name_Length     => Name'Length,
      Text_Length     => Text'Length,
      Parameter_Count => Parameter_Types'Length,
      Name            => Name,
      Text            => Text,
      Parameter_Types => Parameter_Types)
      with Pre => Name'Length > 0 and then Text'Length > 0 and then Parameter_Types'Length <= Parameter_Total'Last;

   type Statement_Access is access constant Statement;
   type Statement_List is array (Positive range <>) of Statement_Access;

   subtype Sql_State is String (1 .. 5);
   No_State              : constant Sql_State := "     ";
   Unique_Violation      : constant Sql_State := "23505";
   Foreign_Key_Violation : constant Sql_State := "23503";
   Not_Null_Violation    : constant Sql_State := "23502";
   Check_Violation       : constant Sql_State := "23514";
   Serialization_Failure : constant Sql_State := "40001";

   --  What one Execute produced. Rows are read with Field_At until the next Read_Results.
   type Statement_Result is record
      Succeeded     : Boolean   := False;
      State         : Sql_State := No_State; --  the error's SQLSTATE when not Succeeded
      First_Field   : Positive  := 1;
      Row_Count     : Natural   := 0;
      Column_Count  : Natural   := 0;
      Affected_Rows : Natural   := 0;        --  of an INSERT, UPDATE or DELETE
      First_Name    : Natural   := 0;        --  where the column names, then types, are kept; 0 if none
      As_Text       : Boolean   := False;    --  the values are text (from Run_Script), not binary
   end record;

   type Result_Array is array (Positive range <>) of Statement_Result;

   type Field is private;
   type Connection is limited private;

   ---------------------------------------------------------------------------------------------------------------
   --  connecting

   --  A libpq connection URI or keyword string: postgres://user:password@host:port/database?sslmode=...,
   --  with any libpq parameter (sslmode, sslrootcert, connect_timeout, target_session_attrs, several hosts...).
   --  Session settings go through libpq's options parameter: ?options=-c%20statement_timeout%3D5000.
   --
   --  Defaults that differ from libpq's: client_encoding is always UTF8; application_name is "sparrow" unless
   --  given; and require_auth is "!password,!md5", so the password is only ever sent by SCRAM-SHA-256 (give
   --  require_auth in the URL to choose otherwise); and with sslmode=verify-full and no sslrootcert, the
   --  operating system's trusted roots are used rather than ~/.postgresql/root.crt. sslmode defaults to prefer,
   --  as in libpq: use verify-full across any network that is not yours.
   procedure Connect (This : in out Connection; Url : String)
      with Global            => (In_Out => Server),
           Exceptional_Cases => (Connection_Error => True);

   procedure Disconnect (This : in out Connection) with Global => (In_Out => Server);

   function Is_Connected (This : Connection) return Boolean;

   --  Parse a named statement on this connection and wait for it.
   procedure Prepare (This : in out Connection; Query : Statement)
      with Global => (In_Out => Server), Exceptional_Cases => (Connection_Error => True);

   procedure Prepare (This : in out Connection; Queries : Statement_List)
      with Global => (In_Out => Server), Exceptional_Cases => (Connection_Error => True);

   --  Run SQL text as it is (the simple query protocol): schema set-up, migrations, BEGIN/COMMIT. Several
   --  statements may be separated by ';'. The last statement's rows can be read with Field_At until the next
   --  results, as text (read them with Text; cast in SQL: count(*)::text). Never build Sql from request data:
   --  that is what prepared statements and their parameters are for.
   --  Not while a flushed group's results are unread.
   procedure Run_Script (This : in out Connection; Sql : String; Result : out Statement_Result)
      with Global => (In_Out => Server), Exceptional_Cases => (Connection_Error => True);

   ---------------------------------------------------------------------------------------------------------------
   --  Building a pipeline: Bind, one Add per parameter in order, Execute; Sync closes a group. A group is one
   --  implicit transaction: its statements commit together at the Sync, or not at all.

   procedure Bind (This : in out Connection; Query : Statement);

   --  Integers are sent in the width the statement declares (int2, int4 or int8).
   procedure Add_Parameter (This : in out Connection; Value : UTF8_String);         --  text or json
   procedure Add_Parameter (This : in out Connection; Value : Long_Long_Integer);
   procedure Add_Parameter (This : in out Connection; Value : Boolean);
   procedure Add_Parameter (This : in out Connection; Value : Long_Float);
   procedure Add_Bytes (This : in out Connection; Value : String);                  --  bytea
   procedure Add_Timestamp (This : in out Connection; Value : Unix_Microseconds);   --  timestamptz
   procedure Add_Null (This : in out Connection);

   --  An array parameter built in place: Begin_Array, then exactly Count Add_Element calls, then End_Array.
   procedure Begin_Array (This : in out Connection; Element_Type : Type_Oid; Count : Natural);
   procedure Add_Element (This : in out Connection; Value : UTF8_String);
   procedure Add_Element (This : in out Connection; Value : Long_Long_Integer);
   procedure End_Array (This : in out Connection);

   procedure Execute (This : in out Connection);
   procedure Sync (This : in out Connection);

   --  Send everything built so far.
   procedure Flush (This : in out Connection)
      with Global => (In_Out => Server), Exceptional_Cases => (Connection_Error => True);

   procedure Discard_Unsent (This : in out Connection);   --  after a Connection_Error

   --  Read one group's replies, up to its ReadyForQuery: one result per Execute, in order. A failed
   --  statement makes Postgres skip the rest of its group; those results stay not Succeeded. Rows of earlier
   --  groups stay readable when Keep_Earlier is set; otherwise they are dropped.
   procedure Read_Results (This : in out Connection; Results : out Result_Array; Keep_Earlier : Boolean := False)
      with Global => (In_Out => Server), Exceptional_Cases => (Connection_Error => True);

   --  Sync, Flush and Read_Results for a group of one Execute.
   procedure Fetch (This : in out Connection; Result : out Statement_Result)
      with Global => (In_Out => Server), Exceptional_Cases => (Connection_Error => True);

   --  The same without exceptions, for proved callers: Sent and Received are False where those raise
   --  Connection_Error, and Last_Failure says why.
   procedure Try_Flush (This : in out Connection; Sent : out Boolean) with Global => (In_Out => Server);
   procedure Try_Read_Results
     (This : in out Connection; Results : out Result_Array; Received : out Boolean; Keep_Earlier : Boolean := False)
      with Global => (In_Out => Server);

   --  Why the last Connection_Error was raised, or the server's message for the last statement that failed.
   function Last_Failure (This : Connection) return String
      with Post => Last_Failure'Result'Length <= 512;

   ---------------------------------------------------------------------------------------------------------------
   --  Values. All are total: a field outside the result, or one whose bytes do not fit what is asked, reads as
   --  NULL, "", 0 or False. Results are binary: Text reads text, varchar and json columns, Bytes reads
   --  bytea (and the raw bytes of anything else); cast other types in SQL (jsonb::text, uuid::text,
   --  numeric::float8).

   function Field_At (This : Connection; Result : Statement_Result; Row, Column : Positive) return Field with Inline;

   --  The position of the column called Name (as the query names it: use AS for expressions); 0 when there is
   --  none.
   function Column_Of (This : Connection; Result : Statement_Result; Name : String) return Natural
      with Post => Column_Of'Result <= Result.Column_Count;

   --  The name of a column, as the query names it; "" outside the result.
   function Column_Name (This : Connection; Result : Statement_Result; Column : Positive) return String;

   --  The type of a column; 0 outside the result.
   function Column_Type (This : Connection; Result : Statement_Result; Column : Positive) return Type_Oid;

   --  A field by column name. A misspelt name is a bug: the precondition catches it where assertions are on.
   --
   --     for Row in 1 .. Result.Row_Count loop
   --        Show (Integer_Value (Db, Field_At (Db, Result, Row, "id")), Text (Db, Field_At (Db, Result, Row, "name")));
   --     end loop;
   function Field_At (This : Connection; Result : Statement_Result; Row : Positive; Column : String) return Field
      with Pre => Column_Of (This, Result, Column) /= 0;

   function Is_Null (Item : Field) return Boolean;
   function Text (This : Connection; Item : Field) return UTF8_String;
   function Bytes (This : Connection; Item : Field) return String;
   function Integer_Value (This : Connection; Item : Field) return Long_Long_Integer;   --  int2, int4 or int8
   function Boolean_Value (This : Connection; Item : Field) return Boolean;
   function Float_Value (This : Connection; Item : Field) return Long_Float;            --  float4 or float8
   function Timestamp_Value (This : Connection; Item : Field) return Unix_Microseconds; --  timestamptz

   --  A one-dimensional array: its element count and its Index-th element.
   function Element_Count (This : Connection; Item : Field) return Natural;
   function Element (This : Connection; Item : Field; Index : Positive) return Field;

private

   type Field is new Postgres_Wire.Field;   --  a value in the receive buffer

   function Is_Null (Item : Field) return Boolean is (Postgres_Wire.Is_Null (Postgres_Wire.Field (Item)));

   type Field_Array is array (Positive range <>) of Field;
   type Field_Array_Access is access Field_Array;
   type Type_Oid_Array_Access is access Type_Oid_Array;

   --  Outgoing holds the pipeline not yet sent, as a stream of commands: 'E', the statement name and a NUL, the
   --  parameter count (2 bytes), then each parameter as a 4-byte length (-1 for NULL) and its bytes; or 'S' for
   --  a Sync. Flush hands them to libpq.
   type Connection is limited record
      Handle             : System.Address := System.Null_Address;   --  PGconn
      Outgoing           : Buffer;
      Incoming           : Buffer;                                  --  the bytes of every field read so far
      Fields             : Field_Array_Access;
      Field_Count        : Natural := 0;
      Array_Start        : Positive := 1;                           --  length word of the array being built
      Parameters_Missing : Natural := 0;
      Bound_Types        : Type_Oid_Array_Access;                   --  (1 .. Bound_Count): the statement bound
      Bound_Count        : Natural := 0;
      Element_Type       : Type_Oid := 0;                           --  of the array parameter being built
      Elements_Missing   : Natural := 0;
      Reason             : String (1 .. 512) := [others => ' '];    --  see Last_Failure
      Reason_Length      : Natural range 0 .. 512 := 0;
      Described          : Buffer;   --  parameter types the server inferred, by statement name (see Prepare)
   end record
   with Type_Invariant => Valid (Connection);

   function Valid (This : Connection) return Boolean is
     (Buffers.Valid (This.Outgoing) and then Buffers.Valid (This.Incoming) and then Buffers.Valid (This.Described)
      and then (if This.Fields = null then This.Field_Count = 0
                else This.Fields'First = 1 and then This.Field_Count <= This.Fields'Last)
      and then (if This.Bound_Types = null then This.Bound_Count = 0
                else This.Bound_Types'First = 1 and then This.Bound_Count <= This.Bound_Types'Last));

   use type System.Address;
   function Is_Connected (This : Connection) return Boolean is (This.Handle /= System.Null_Address);

end Sparrow.Postgres;
