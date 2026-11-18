--  Over libpq in pipeline mode. Parameters are encoded here (binary, at the widths the statements declare) into
--  a command stream, which Flush hands to libpq; results are copied field by field into one buffer and read
--  back through Sparrow.Postgres_Wire.
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with GNAT.OS_Lib;
with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with Sparrow.Encoding;

package body Sparrow.Postgres with SPARK_Mode => Off is

   package Encoding renames Sparrow.Encoding;

   procedure Free is new Ada.Unchecked_Deallocation (Field_Array, Field_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Type_Oid_Array, Type_Oid_Array_Access);

   Max_Fields : constant := 2 ** 26;

   --  Postgres counts timestamps in microseconds from 2000-01-01T00:00:00Z.
   Postgres_Epoch : constant := 946_684_800_000_000;

   Execute_Command : constant Character := 'E';
   Sync_Command    : constant Character := 'S';

   ---------------------------------------------------------------------------------------------------------------
   --  libpq

   subtype Handle is System.Address;   --  PGconn, PGresult

   type Address_Array is array (Positive range <>) of aliased System.Address with Convention => C;
   type Int_Array is array (Positive range <>) of aliased int with Convention => C;
   type Oid_Array is array (Positive range <>) of aliased unsigned with Convention => C;

   function PQlibVersion return int with Import, Convention => C, External_Name => "PQlibVersion";
   function PQconnectdbParams (Keywords, Values : System.Address; Expand_Dbname : int) return Handle
      with Import, Convention => C, External_Name => "PQconnectdbParams";
   function PQstatus (Connection : Handle) return int with Import, Convention => C, External_Name => "PQstatus";
   function PQerrorMessage (Connection : Handle) return chars_ptr
      with Import, Convention => C, External_Name => "PQerrorMessage";
   procedure PQfinish (Connection : Handle) with Import, Convention => C, External_Name => "PQfinish";
   function PQprepare
     (Connection : Handle; Name, Query : System.Address; Count : int; Types : System.Address) return Handle
      with Import, Convention => C, External_Name => "PQprepare";
   function PQexec (Connection : Handle; Query : System.Address) return Handle
      with Import, Convention => C, External_Name => "PQexec";
   function PQenterPipelineMode (Connection : Handle) return int
      with Import, Convention => C, External_Name => "PQenterPipelineMode";
   function PQexitPipelineMode (Connection : Handle) return int
      with Import, Convention => C, External_Name => "PQexitPipelineMode";
   function PQsendQueryPrepared
     (Connection : Handle; Name : System.Address; Count : int; Values, Lengths, Formats : System.Address;
      Result_Format : int) return int
      with Import, Convention => C, External_Name => "PQsendQueryPrepared";
   function PQpipelineSync (Connection : Handle) return int
      with Import, Convention => C, External_Name => "PQpipelineSync";
   function PQflush (Connection : Handle) return int with Import, Convention => C, External_Name => "PQflush";
   function PQgetResult (Connection : Handle) return Handle
      with Import, Convention => C, External_Name => "PQgetResult";
   function PQresultStatus (Result : Handle) return int
      with Import, Convention => C, External_Name => "PQresultStatus";
   function PQresultErrorField (Result : Handle; Code : int) return chars_ptr
      with Import, Convention => C, External_Name => "PQresultErrorField";
   function PQntuples (Result : Handle) return int with Import, Convention => C, External_Name => "PQntuples";
   function PQnfields (Result : Handle) return int with Import, Convention => C, External_Name => "PQnfields";
   function PQfname (Result : Handle; Column : int) return chars_ptr
      with Import, Convention => C, External_Name => "PQfname";
   function PQdescribePrepared (Connection : Handle; Name : System.Address) return Handle
      with Import, Convention => C, External_Name => "PQdescribePrepared";
   function PQnparams (Result : Handle) return int with Import, Convention => C, External_Name => "PQnparams";
   function PQftype (Result : Handle; Column : int) return unsigned
      with Import, Convention => C, External_Name => "PQftype";
   function PQparamtype (Result : Handle; Index : int) return unsigned
      with Import, Convention => C, External_Name => "PQparamtype";
   function PQgetisnull (Result : Handle; Row, Column : int) return int
      with Import, Convention => C, External_Name => "PQgetisnull";
   function PQgetlength (Result : Handle; Row, Column : int) return int
      with Import, Convention => C, External_Name => "PQgetlength";
   function PQgetvalue (Result : Handle; Row, Column : int) return System.Address
      with Import, Convention => C, External_Name => "PQgetvalue";
   function PQcmdTuples (Result : Handle) return chars_ptr
      with Import, Convention => C, External_Name => "PQcmdTuples";
   procedure PQclear (Result : Handle) with Import, Convention => C, External_Name => "PQclear";

   CONNECTION_OK          : constant := 0;
   PGRES_EMPTY_QUERY      : constant := 0;
   PGRES_COMMAND_OK       : constant := 1;
   PGRES_TUPLES_OK        : constant := 2;
   PGRES_FATAL_ERROR      : constant := 7;
   PGRES_PIPELINE_SYNC    : constant := 10;
   PG_DIAG_SQLSTATE       : constant := Character'Pos ('C');
   PG_DIAG_MESSAGE        : constant := Character'Pos ('M');
   Binary_Format          : constant := 1;

   --  A C string as Ada text; "" for null.
   function To_Ada (Item : chars_ptr) return String is (if Item = Null_Ptr then "" else Value (Item));

   --  At most 512 bytes of Text, from its end: libpq reports each host it tried in turn, so the reason that
   --  decided comes last.
   function Clip (Text : String) return String is
     (if Text'Length <= 512 then Text else "..." & Text (Text'Last - 508 .. Text'Last));

   --  libpq's message without its trailing line break.
   function Trimmed (Text : String) return String is
      Last : Natural := Text'Last;
   begin
      while Last >= Text'First and then Text (Last) in ASCII.LF | ASCII.CR | ' ' loop
         Last := Last - 1;
      end loop;
      return Text (Text'First .. Last);
   end Trimmed;

   procedure Remember (This : in out Connection; Message : String) is
      Kept : constant String := Clip (Trimmed (Message));
   begin
      This.Reason (1 .. Kept'Length) := Kept;
      This.Reason_Length             := Kept'Length;
   end Remember;

   --  Record why, then raise Connection_Error.
   procedure Fail (This : in out Connection; Message : String) with No_Return is
   begin
      Remember (This, Message);
      raise Connection_Error with Clip (Trimmed (Message));
   end Fail;

   --  Fail with libpq's own account of what went wrong.
   procedure Fail_From_Library (This : in out Connection; What : String) with No_Return is begin
      Fail (This, What & ": " & Trimmed (To_Ada (PQerrorMessage (This.Handle))));
   end Fail_From_Library;

   function Has_Nul (Text : String) return Boolean is (for some Symbol of Text => Symbol = ASCII.NUL);

   ---------------------------------------------------------------------------------------------------------------
   --  connecting

   --  PQconninfoOption
   type Option is record
      Keyword, Environment_Name, Compiled_Default, Value, Label, Display : chars_ptr;
      Display_Size                                                      : int;
   end record with Convention => C;
   type Option_Array is array (Natural) of Option with Convention => C;
   type Option_Array_Access is access all Option_Array with Convention => C;

   function PQconninfoParse (Text : System.Address; Error : access chars_ptr) return Option_Array_Access
      with Import, Convention => C, External_Name => "PQconninfoParse";
   procedure PQconninfoFree (Options : Option_Array_Access)
      with Import, Convention => C, External_Name => "PQconninfoFree";
   procedure PQfreemem (Item : chars_ptr) with Import, Convention => C, External_Name => "PQfreemem";

   --  Whether Url (NUL-terminated) asks for verify-full and names no roots: then the system's are meant. (libpq
   --  would look in ~/.postgresql, and accepts sslrootcert=system only with verify-full.)
   function Wants_System_Roots (Url : String) return Boolean is
      Error   : aliased chars_ptr := Null_Ptr;
      Options : constant Option_Array_Access := PQconninfoParse (Url'Address, Error'Access);
      Mode    : Boolean := False;
      Roots   : Boolean := False;
      Index   : Natural := 0;
   begin
      if Error /= Null_Ptr then
         PQfreemem (Error);
      end if;
      if Options = null then
         return False;   --  Connect reports why
      end if;
      while Options (Index).Keyword /= Null_Ptr loop
         declare
            Keyword : constant String := Value (Options (Index).Keyword);
            Given   : constant String := To_Ada (Options (Index).Value);
         begin
            Mode  := Mode or else (Keyword = "sslmode" and then Given = "verify-full");
            Roots := Roots or else (Keyword = "sslrootcert" and then Given /= "");
         end;
         Index := Index + 1;
      end loop;
      PQconninfoFree (Options);
      return Mode and then not Roots;
   end Wants_System_Roots;

   procedure Connect (This : in out Connection; Url : String) is
      Url_Text : aliased constant String := Url & ASCII.NUL;
      --  In order: defaults the URL may override, the URL, then what it may not.
      Name     : aliased constant String := "application_name" & ASCII.NUL;
      Name_Of  : aliased constant String := "sparrow" & ASCII.NUL;
      Auth     : aliased constant String := "require_auth" & ASCII.NUL;
      Auth_Of  : aliased constant String := "!password,!md5" & ASCII.NUL;
      Roots    : aliased constant String := "sslrootcert" & ASCII.NUL;
      Roots_Of : aliased constant String := "system" & ASCII.NUL;
      Database : aliased constant String := "dbname" & ASCII.NUL;
      Encoding : aliased constant String := "client_encoding" & ASCII.NUL;
      Utf8     : aliased constant String := "UTF8" & ASCII.NUL;
      Keywords : aliased Address_Array :=
        [Name'Address, Auth'Address, Database'Address, Encoding'Address, System.Null_Address, System.Null_Address];
      Values   : aliased Address_Array :=
        [Name_Of'Address, Auth_Of'Address, Url_Text'Address, Utf8'Address, System.Null_Address, System.Null_Address];
   begin
      Disconnect (This);
      if Has_Nul (Url) then
         Fail (This, "the connection URL holds a NUL");
      end if;
      if Wants_System_Roots (Url_Text) then   --  after the URL: it named none
         Keywords (5) := Roots'Address;
         Values (5)   := Roots_Of'Address;
      end if;
      This.Handle := PQconnectdbParams (Keywords'Address, Values'Address, Expand_Dbname => 1);
      if This.Handle = System.Null_Address then
         Fail (This, "libpq could not allocate a connection");
      elsif PQstatus (This.Handle) /= CONNECTION_OK then
         declare
            Reason : constant String := Trimmed (To_Ada (PQerrorMessage (This.Handle)));
         begin
            PQfinish (This.Handle);
            This.Handle := System.Null_Address;
            Fail (This, Reason);
         end;
      end if;
   end Connect;

   procedure Disconnect (This : in out Connection) is begin
      if This.Handle /= System.Null_Address then
         PQfinish (This.Handle);
         This.Handle := System.Null_Address;
      end if;
      Clear (This.Outgoing);
      This.Outgoing.Overflowed := False;
      Free (This.Outgoing);
      Free (This.Incoming);
      Free (This.Fields);
      Free (This.Bound_Types);
      Free (This.Described);
      This.Field_Count        := 0;
      This.Bound_Count        := 0;
      This.Parameters_Missing := 0;
      This.Elements_Missing   := 0;
   end Disconnect;

   procedure Require_Connection (This : in out Connection) is begin
      if This.Handle = System.Null_Address then
         Fail (This, "not connected");
      end if;
   end Require_Connection;

   --  The row count of a command ("5" for INSERT 0 5); 0 when it has none.
   function Affected (Result : Handle) return Natural is
      Text  : constant String := To_Ada (PQcmdTuples (Result));
      Value : Long_Long_Integer;
      Valid : Boolean;
   begin
      Encoding.Parse_Decimal (Text, Value, Valid);
      return (if not Valid or else Value < 0 then 0
              elsif Value > Long_Long_Integer (Natural'Last) then Natural'Last
              else Natural (Value));
   end Affected;

   --  What a finished result says, rows aside; the server's message is remembered when it failed.
   procedure Describe (This : in out Connection; Result : Handle; Into : in out Statement_Result) is
      Status : constant int := PQresultStatus (Result);
   begin
      Into.Succeeded := Status in PGRES_EMPTY_QUERY | PGRES_COMMAND_OK | PGRES_TUPLES_OK;
      if Into.Succeeded then
         Into.Affected_Rows := Affected (Result);
      else
         declare
            State : constant String := To_Ada (PQresultErrorField (Result, PG_DIAG_SQLSTATE));
         begin
            if State'Length = Sql_State'Length then
               Into.State := State;
            end if;
         end;
         if Status = PGRES_FATAL_ERROR then
            Remember (This, To_Ada (PQresultErrorField (Result, PG_DIAG_MESSAGE)));
         end if;
      end if;
   end Describe;

   --  Run one blocking libpq call's result: Fail when there is none (the connection broke).
   procedure Check_Prepared (This : in out Connection; Result : Handle; Name : String) is
      Outcome : Statement_Result;
   begin
      if Result = System.Null_Address then
         Fail_From_Library (This, "prepare " & Name);
      end if;
      Describe (This, Result, Outcome);
      PQclear (Result);
      if not Outcome.Succeeded then
         Fail (This, "prepare " & Name & ": " & Last_Failure (This));
      end if;
   end Check_Prepared;

   procedure Prepare (This : in out Connection; Query : Statement) is
      Name  : aliased constant String := Query.Name & ASCII.NUL;
      Text  : aliased constant String := Query.Text & ASCII.NUL;
      Types : aliased Oid_Array (1 .. Natural'Max (1, Query.Parameter_Count)) := [others => 0];
   begin
      Require_Connection (This);
      if Has_Nul (Query.Name) or else Has_Nul (Query.Text) then
         Fail (This, "statement " & Clip (Query.Name) & " holds a NUL");
      end if;
      for Index in 1 .. Query.Parameter_Count loop
         Types (Index) := unsigned (Query.Parameter_Types (Index));
      end loop;
      Check_Prepared (This, PQprepare (This.Handle, Name'Address, Text'Address, int (Query.Parameter_Count),
                                       Types'Address),
                      Query.Name);

      if Query.Parameter_Count = 0 then
         --  Learn the types the server inferred, kept as: the name, a NUL, the count (2 bytes), each type
         --  (4 bytes).
         declare
            Answer : constant Handle := PQdescribePrepared (This.Handle, Name'Address);
            Count  : Natural;
         begin
            if Answer = System.Null_Address then
               Fail_From_Library (This, "describe " & Query.Name);
            end if;
            Count := Natural (PQnparams (Answer));
            if Count > Parameter_Total'Last then
               PQclear (Answer);
               Fail (This, "statement " & Clip (Query.Name) & " has too many parameters");
            end if;
            Append (This.Described, Query.Name);
            Append (This.Described, ASCII.NUL);
            Append_Big_Endian (This.Described, Unsigned_16 (Count));
            for Index in 0 .. Count - 1 loop
               Append_Big_Endian (This.Described, Unsigned_32 (PQparamtype (Answer, int (Index))));
            end loop;
            PQclear (Answer);
            if This.Described.Overflowed then
               Fail (This, "too many statements prepared");
            end if;
         end;
      end if;
   end Prepare;

   --  The parameter types Prepare learnt for the statement called Name; empty when there are none.
   function Described_Types (This : Connection; Name : String) return Type_Oid_Array is
      Data     : constant String := Content (This.Described);
      Position : Positive := 1;

      function Word (At_Position, Size : Positive) return Unsigned_32 is
         Result : Unsigned_32 := 0;
      begin
         for Index in At_Position .. At_Position + Size - 1 loop
            Result := Result * 256 + Character'Pos (Data (Index));
         end loop;
         return Result;
      end Word;
   begin
      while Position <= Data'Last loop
         declare
            Name_End : Natural := Position;
            Count    : Natural;
         begin
            while Data (Name_End) /= ASCII.NUL loop
               Name_End := Name_End + 1;
            end loop;
            Count := Natural (Word (Name_End + 1, 2));
            if Data (Position .. Name_End - 1) = Name then
               return Result : Type_Oid_Array (1 .. Count) do
                  for Index in Result'Range loop
                     Result (Index) := Type_Oid (Word (Name_End + 3 + (Index - 1) * 4, 4));
                  end loop;
               end return;
            end if;
            Position := Name_End + 3 + Count * 4;
         end;
      end loop;
      return No_Parameters;
   end Described_Types;

   procedure Prepare (This : in out Connection; Queries : Statement_List) is begin
      for Query of Queries loop
         if Query /= null then
            Prepare (This, Query.all);
         end if;
      end loop;
   end Prepare;

   procedure Take_Rows (This : in out Connection; Source : Handle; Result : in out Statement_Result);

   procedure Run_Script (This : in out Connection; Sql : String; Result : out Statement_Result) is
      Text   : aliased constant String := Sql & ASCII.NUL;
      Answer : Handle;
   begin
      Result := (others => <>);
      Require_Connection (This);
      if Has_Nul (Sql) then
         Fail (This, "the script holds a NUL");
      end if;
      Answer := PQexec (This.Handle, Text'Address);   --  the last statement's result
      if Answer = System.Null_Address then
         Fail_From_Library (This, "run script");
      end if;
      Clear (This.Incoming);
      This.Field_Count := 0;
      Describe (This, Answer, Result);
      if PQresultStatus (Answer) = PGRES_TUPLES_OK then
         Take_Rows (This, Answer, Result);
      end if;
      Result.As_Text := True;
      PQclear (Answer);
   end Run_Script;

   ---------------------------------------------------------------------------------------------------------------
   --  pipelines: building the command stream

   procedure Unsendable (This : in out Connection) is begin
      This.Outgoing.Overflowed := True;
   end Unsendable;

   procedure Bind (This : in out Connection; Query : Statement) is begin
      if This.Parameters_Missing /= 0 or else This.Elements_Missing /= 0 or else Has_Nul (Query.Name) then
         Unsendable (This);   --  the previous statement is missing parameters, or this name cannot be sent
      end if;

      declare
         Types : constant Type_Oid_Array :=
           (if Query.Parameter_Count = 0 then Described_Types (This, Query.Name) else Query.Parameter_Types);
      begin
         if This.Bound_Types = null or else This.Bound_Types'Length < Types'Length then
            Free (This.Bound_Types);
            This.Bound_Types := new Type_Oid_Array (1 .. Natural'Max (16, Types'Length));
         end if;
         This.Bound_Types (1 .. Types'Length) := Types;
         This.Bound_Count := Types'Length;

         Append (This.Outgoing, Execute_Command);
         Append (This.Outgoing, Query.Name);
         Append (This.Outgoing, ASCII.NUL);
         Append_Big_Endian (This.Outgoing, Unsigned_16 (Types'Length));
         This.Parameters_Missing := Types'Length;
      end;
   end Bind;

   --  The declared type of the parameter about to be added; 0 when there is none left.
   function Next_Type (This : Connection) return Type_Oid is
     (if This.Parameters_Missing = 0 or else This.Parameters_Missing > This.Bound_Count then 0
      else This.Bound_Types (This.Bound_Count - This.Parameters_Missing + 1));

   --  One parameter more; more than the statement takes makes the pipeline unsendable.
   procedure Added (This : in out Connection) is begin
      if This.Parameters_Missing = 0 or else This.Elements_Missing /= 0 then
         Unsendable (This);
      else
         This.Parameters_Missing := This.Parameters_Missing - 1;
      end if;
   end Added;

   --  An integer in the width of Kind: int2, int4, or int8 for anything else.
   procedure Append_Integer_Value (This : in out Connection; Kind : Type_Oid; Value : Long_Long_Integer) is begin
      case Kind is
         when Int2_Oid =>
            if Value not in -2 ** 15 .. 2 ** 15 - 1 then
               Unsendable (This);
            end if;
            Append_Big_Endian (This.Outgoing, Unsigned_32'(2));
            Append_Big_Endian (This.Outgoing, Unsigned_16'Mod (Value));
         when Int4_Oid =>
            if Value not in -2 ** 31 .. 2 ** 31 - 1 then
               Unsendable (This);
            end if;
            Append_Big_Endian (This.Outgoing, Unsigned_32'(4));
            Append_Big_Endian (This.Outgoing, Unsigned_32'Mod (Value));
         when others =>
            Append_Big_Endian (This.Outgoing, Unsigned_32'(8));
            Append_Big_Endian (This.Outgoing, Unsigned_64'Mod (Value));
      end case;
   end Append_Integer_Value;

   procedure Add_Parameter (This : in out Connection; Value : UTF8_String) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32 (Value'Length));
      Append_Text (This.Outgoing, Value);
      Added (This);
   end Add_Parameter;

   procedure Add_Bytes (This : in out Connection; Value : String) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32 (Value'Length));
      Append (This.Outgoing, Value);
      Added (This);
   end Add_Bytes;

   procedure Add_Parameter (This : in out Connection; Value : Long_Long_Integer) is begin
      Append_Integer_Value (This, Next_Type (This), Value);
      Added (This);
   end Add_Parameter;

   procedure Add_Parameter (This : in out Connection; Value : Boolean) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32'(1));
      Append (This.Outgoing, (if Value then ASCII.SOH else ASCII.NUL));
      Added (This);
   end Add_Parameter;

   procedure Add_Parameter (This : in out Connection; Value : Long_Float) is
      function To_Bits is new Ada.Unchecked_Conversion (Long_Float, Unsigned_64);
      function To_Bits is new Ada.Unchecked_Conversion (Float, Unsigned_32);
   begin
      if not Value'Valid then
         Unsendable (This);
      elsif Next_Type (This) = Float4_Oid then
         if abs Value > Long_Float (Float'Last) then
            Unsendable (This);
         end if;
         Append_Big_Endian (This.Outgoing, Unsigned_32'(4));
         Append_Big_Endian (This.Outgoing, To_Bits (Float (Long_Float'Max (-Long_Float (Float'Last),
                                                         Long_Float'Min (Long_Float (Float'Last), Value)))));
      else
         Append_Big_Endian (This.Outgoing, Unsigned_32'(8));
         Append_Big_Endian (This.Outgoing, To_Bits (Value));
      end if;
      Added (This);
   end Add_Parameter;

   procedure Add_Timestamp (This : in out Connection; Value : Unix_Microseconds) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32'(8));
      if Long_Long_Integer (Value) < Long_Long_Integer'First + Postgres_Epoch then
         Unsendable (This);
         Append_Big_Endian (This.Outgoing, Unsigned_64'(0));
      else
         Append_Big_Endian (This.Outgoing, Unsigned_64'Mod (Long_Long_Integer (Value) - Postgres_Epoch));
      end if;
      Added (This);
   end Add_Timestamp;

   procedure Add_Null (This : in out Connection) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32'(16#FFFF_FFFF#));   --  length -1: NULL
      Added (This);
   end Add_Null;

   procedure Begin_Array (This : in out Connection; Element_Type : Type_Oid; Count : Natural) is begin
      if This.Elements_Missing /= 0 then
         Unsendable (This);
      end if;
      This.Array_Start      := This.Outgoing.Length + 1;
      This.Element_Type     := Element_Type;
      This.Elements_Missing := Count;
      Append_Big_Endian (This.Outgoing, Unsigned_32'(0));   --  the length, set by End_Array
      Append_Big_Endian (This.Outgoing, Unsigned_32'(if Count = 0 then 0 else 1));   --  dimensions
      Append_Big_Endian (This.Outgoing, Unsigned_32'(0));   --  no NULL elements
      Append_Big_Endian (This.Outgoing, Unsigned_32 (Element_Type));
      if Count > 0 then
         Append_Big_Endian (This.Outgoing, Unsigned_32 (Count));
         Append_Big_Endian (This.Outgoing, Unsigned_32'(1));   --  lower bound
      end if;
   end Begin_Array;

   procedure Element_Added (This : in out Connection) is begin
      if This.Elements_Missing = 0 then
         Unsendable (This);
      else
         This.Elements_Missing := This.Elements_Missing - 1;
      end if;
   end Element_Added;

   procedure Add_Element (This : in out Connection; Value : UTF8_String) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32 (Value'Length));
      Append_Text (This.Outgoing, Value);
      Element_Added (This);
   end Add_Element;

   procedure Add_Element (This : in out Connection; Value : Long_Long_Integer) is begin
      Append_Integer_Value (This, This.Element_Type, Value);
      Element_Added (This);
   end Add_Element;

   procedure End_Array (This : in out Connection) is begin
      if This.Elements_Missing /= 0 then
         Unsendable (This);
         This.Elements_Missing := 0;
      end if;
      if This.Outgoing.Length >= 3 and then This.Array_Start <= This.Outgoing.Length - 3 then
         Overwrite_Big_Endian (This.Outgoing, This.Array_Start,
                               Unsigned_32 (This.Outgoing.Length - This.Array_Start - 3));
      else
         Unsendable (This);
      end if;
      Added (This);
   end End_Array;

   procedure Execute (This : in out Connection) is begin
      if This.Parameters_Missing /= 0 or else This.Elements_Missing /= 0 then
         Unsendable (This);
      end if;
   end Execute;

   procedure Sync (This : in out Connection) is begin
      Append (This.Outgoing, Sync_Command);
   end Sync;

   procedure Discard_Unsent (This : in out Connection) is begin
      Clear (This.Outgoing);
      This.Outgoing.Overflowed := False;
      This.Parameters_Missing  := 0;
      This.Elements_Missing    := 0;
   end Discard_Unsent;

   ---------------------------------------------------------------------------------------------------------------
   --  pipelines: sending

   --  Hand the Execute command at Next of Stream to libpq, and move Next past it. False when it is malformed.
   procedure Send_Execute (This : in out Connection; Stream : String; Next : in out Positive; Sent : out Boolean) is
      Name_First : constant Positive := Next;
      Count      : Natural;
   begin
      Sent := False;
      while Next <= Stream'Last and then Stream (Next) /= ASCII.NUL loop
         Next := Next + 1;
      end loop;
      if Next > Stream'Last - 2 then
         return;
      end if;
      Count := Postgres_Wire.Short (Stream, Next + 1);
      Next  := Next + 3;
      declare
         Values  : aliased Address_Array (1 .. Natural'Max (1, Count)) := [others => System.Null_Address];
         Lengths : aliased Int_Array (1 .. Natural'Max (1, Count)) := [others => 0];
         Formats : aliased constant Int_Array (1 .. Natural'Max (1, Count)) := [others => Binary_Format];
      begin
         for Index in 1 .. Count loop
            if Next > Stream'Last - 3 then
               return;
            end if;
            declare
               Length : constant Unsigned_32 := Postgres_Wire.Word (Stream, Next);
            begin
               Next := Next + 4;
               if Length /= 16#FFFF_FFFF# then   --  otherwise NULL: a null pointer
                  if Length > Unsigned_32 (Stream'Last - Next + 1) then
                     return;
                  end if;
                  Lengths (Index) := int (Length);
                  Values (Index)  := (if Next <= Stream'Last then Stream (Next)'Address else Stream'Address);
                  Next            := Next + Natural (Length);
               end if;
            end;
         end loop;
         Sent := PQsendQueryPrepared (This.Handle, Stream (Name_First)'Address, int (Count), Values'Address,
                                      Lengths'Address, Formats'Address, Binary_Format) = 1;
         if not Sent then
            Fail_From_Library (This, "send");
         end if;
      end;
   end Send_Execute;

   procedure Flush (This : in out Connection) is
      Next : Positive := 1;
      Sent : Boolean;
   begin
      Require_Connection (This);
      if This.Outgoing.Overflowed or else This.Parameters_Missing /= 0 or else This.Elements_Missing /= 0 then
         Discard_Unsent (This);
         Fail (This, "a statement in the pipeline could not be built (parameters not matching it, or too large)");
      end if;
      if This.Outgoing.Length = 0 then
         return;
      end if;
      if PQenterPipelineMode (This.Handle) /= 1 then
         Fail_From_Library (This, "pipeline mode");
      end if;

      declare
         Stream : String renames This.Outgoing.Data (1 .. This.Outgoing.Length);
      begin
         while Next <= Stream'Last loop
            case Stream (Next) is
               when Execute_Command =>
                  Next := Next + 1;
                  Send_Execute (This, Stream, Next, Sent);
                  if not Sent then
                     Discard_Unsent (This);
                     Fail (This, "malformed pipeline");
                  end if;
               when Sync_Command =>
                  Next := Next + 1;
                  if PQpipelineSync (This.Handle) /= 1 then
                     Fail_From_Library (This, "sync");
                  end if;
               when others =>
                  Discard_Unsent (This);
                  Fail (This, "malformed pipeline");
            end case;
         end loop;
      end;
      Clear (This.Outgoing);
      if PQflush (This.Handle) /= 0 then
         Fail_From_Library (This, "send");
      end if;
   end Flush;

   ---------------------------------------------------------------------------------------------------------------
   --  pipelines: receiving

   --  Append Item to the field table, growing it; Added is False when the table is full.
   procedure Add_Field (Fields : in out Field_Array_Access; Count : in out Natural; Item : Field; Added : out Boolean)
   is begin
      Added := False;
      if Fields = null or else Count = Fields'Last then
         if Count >= Max_Fields then
            return;
         end if;
         declare
            Larger : constant Field_Array_Access :=
              new Field_Array'(1 .. (if Fields = null then 4096 else 2 * Count + 1) => <>);
         begin
            if Fields /= null then
               Larger (1 .. Count) := Fields (1 .. Count);
               Free (Fields);
            end if;
            Fields := Larger;
         end;
      end if;
      Count          := Count + 1;
      Fields (Count) := Item;
      Added          := True;
   end Add_Field;

   --  Every row of Source into the field table, its bytes into Incoming.
   procedure Take_Rows (This : in out Connection; Source : Handle; Result : in out Statement_Result) is
      Rows    : constant int := PQntuples (Source);
      Columns : constant int := PQnfields (Source);
      Added   : Boolean;
   begin
      --  The column names first, as fields, so that columns can be found by name.
      Result.First_Name := This.Field_Count + 1;
      for Column in 0 .. Columns - 1 loop
         declare
            Name  : constant String := To_Ada (PQfname (Source, Column));
            Start : constant Positive := This.Incoming.Length + 1;
         begin
            Append (This.Incoming, Name);
            if This.Incoming.Overflowed then
               Fail (This, "the results do not fit in memory");
            end if;
            Add_Field (This.Fields, This.Field_Count, (Position => Start, Length => Name'Length), Added);
            if not Added then
               Fail (This, "too many fields in the results");
            end if;
         end;
      end loop;
      for Column in 0 .. Columns - 1 loop   --  then their types, 4 bytes each
         declare
            Start : constant Positive := This.Incoming.Length + 1;
         begin
            Append_Big_Endian (This.Incoming, Unsigned_32 (PQftype (Source, Column)));
            if This.Incoming.Overflowed then
               Fail (This, "the results do not fit in memory");
            end if;
            Add_Field (This.Fields, This.Field_Count, (Position => Start, Length => 4), Added);
            if not Added then
               Fail (This, "too many fields in the results");
            end if;
         end;
      end loop;

      Result.First_Field  := This.Field_Count + 1;
      Result.Column_Count := Natural (Columns);
      for Row in 0 .. Rows - 1 loop
         for Column in 0 .. Columns - 1 loop
            if PQgetisnull (Source, Row, Column) = 1 then
               Add_Field (This.Fields, This.Field_Count, Field (Postgres_Wire.Null_Field), Added);
            else
               declare
                  Length : constant Natural := Natural (PQgetlength (Source, Row, Column));
                  Bytes  : String (1 .. Length) with Import, Address => PQgetvalue (Source, Row, Column);
                  Start  : constant Positive := This.Incoming.Length + 1;
               begin
                  Append (This.Incoming, Bytes);
                  if This.Incoming.Overflowed then
                     Fail (This, "the results do not fit in memory");
                  end if;
                  Add_Field (This.Fields, This.Field_Count, (Position => Start, Length => Length), Added);
               end;
            end if;
            if not Added then
               Fail (This, "too many fields in the results");
            end if;
         end loop;
         Result.Row_Count := Result.Row_Count + 1;
      end loop;
   end Take_Rows;

   procedure Read_Results (This : in out Connection; Results : out Result_Array; Keep_Earlier : Boolean := False) is
      Done   : Natural := 0;        --  statements whose results are complete
      Seen   : Boolean := False;    --  whether the current statement has given a result yet
      Answer : Handle;
   begin
      Results := [others => <>];
      Require_Connection (This);
      if not Keep_Earlier then
         Clear (This.Incoming);
         This.Field_Count := 0;
      end if;

      loop
         Answer := PQgetResult (This.Handle);
         if Answer = System.Null_Address then
            --  the end of one statement's results; two in a row means nothing is coming
            if not Seen then
               Fail_From_Library (This, "no results pending (Flush a group closed by Sync first)");
            end if;
            Seen := False;
            Done := Done + 1;
         elsif PQresultStatus (Answer) = PGRES_PIPELINE_SYNC then
            PQclear (Answer);
            exit;
         else
            Seen := True;
            if Done < Results'Length then
               declare
                  Result : Statement_Result renames Results (Results'First + Done);
               begin
                  Describe (This, Answer, Result);
                  if PQresultStatus (Answer) = PGRES_TUPLES_OK then
                     Take_Rows (This, Answer, Result);
                  end if;
               end;
            end if;
            PQclear (Answer);
         end if;
      end loop;

      --  Back to ordinary mode when nothing else is pending, so Prepare and Run_Script work; it stays in
      --  pipeline mode (and this does nothing) while later groups are unread.
      if PQexitPipelineMode (This.Handle) /= 1 then
         null;
      end if;
   end Read_Results;

   procedure Fetch (This : in out Connection; Result : out Statement_Result) is
      Results : Result_Array (1 .. 1);
   begin
      Sync (This);
      Flush (This);
      Read_Results (This, Results);
      Result := Results (1);
   end Fetch;

   procedure Try_Flush (This : in out Connection; Sent : out Boolean) is begin
      Flush (This);
      Sent := True;
   exception
      when Connection_Error =>
         Sent := False;
   end Try_Flush;

   procedure Try_Read_Results
     (This : in out Connection; Results : out Result_Array; Received : out Boolean; Keep_Earlier : Boolean := False)
   is
      Got : Result_Array (Results'Range);
   begin
      Read_Results (This, Got, Keep_Earlier);
      Results  := Got;
      Received := True;
   exception
      when Connection_Error =>
         Results  := [others => <>];
         Received := False;
   end Try_Read_Results;

   function Last_Failure (This : Connection) return String is (This.Reason (1 .. This.Reason_Length));

   ---------------------------------------------------------------------------------------------------------------
   --  values

   function Data (This : Connection) return String is
     (if This.Incoming.Data = null then "" else This.Incoming.Data (1 .. This.Incoming.Length));

   function Wire (Item : Field) return Postgres_Wire.Field is (Postgres_Wire.Field (Item)) with Inline;

   function Column_Of (This : Connection; Result : Statement_Result; Name : String) return Natural is
   begin
      if Result.First_Name = 0 or else This.Fields = null then
         return 0;
      end if;
      for Column in 1 .. Result.Column_Count loop
         declare
            Index : constant Natural := Result.First_Name + Column - 1;
         begin
            exit when Index > This.Field_Count;
            if Bytes (This, This.Fields (Index)) = Name then
               return Column;
            end if;
         end;
      end loop;
      return 0;
   end Column_Of;

   function Column_Name (This : Connection; Result : Statement_Result; Column : Positive) return String is
   begin
      if Result.First_Name = 0 or else This.Fields = null or else Column > Result.Column_Count
        or else Result.First_Name + Column - 1 > This.Field_Count
      then
         return "";
      end if;
      return Bytes (This, This.Fields (Result.First_Name + Column - 1));
   end Column_Name;

   function Column_Type (This : Connection; Result : Statement_Result; Column : Positive) return Type_Oid is
   begin
      if Result.First_Name = 0 or else This.Fields = null or else Column > Result.Column_Count
        or else Result.First_Name + Result.Column_Count + Column - 1 > This.Field_Count
      then
         return 0;
      end if;
      declare
         Word   : constant String := Bytes (This, This.Fields (Result.First_Name + Result.Column_Count + Column - 1));
         Result_Type : Type_Oid := 0;
      begin
         for Symbol of Word loop
            Result_Type := Result_Type * 256 + Character'Pos (Symbol);
         end loop;
         return Result_Type;
      end;
   end Column_Type;

   function Field_At (This : Connection; Result : Statement_Result; Row : Positive; Column : String) return Field is
     (Field_At (This, Result, Row, Positive'Max (1, Column_Of (This, Result, Column))));

   function Field_At (This : Connection; Result : Statement_Result; Row, Column : Positive) return Field is
      Index : constant Long_Long_Integer :=
        Long_Long_Integer (Result.First_Field) + Long_Long_Integer (Row - 1) * Long_Long_Integer (Result.Column_Count)
        + Long_Long_Integer (Column - 1);
   begin
      if This.Fields = null or else Row > Result.Row_Count or else Column > Result.Column_Count
        or else Index > Long_Long_Integer (This.Field_Count)
      then
         return Field (Postgres_Wire.Null_Field);   --  outside the result: reads as NULL
      end if;
      return This.Fields (Positive (Index));
   end Field_At;

   --  The session's client_encoding is UTF8 (set at Connect), so the server sends text as UTF-8.
   function Text (This : Connection; Item : Field) return UTF8_String is
     (UTF8_String (Postgres_Wire.Text (Data (This), Wire (Item))));

   function Bytes (This : Connection; Item : Field) return String is (Postgres_Wire.Text (Data (This), Wire (Item)));

   function Integer_Value (This : Connection; Item : Field) return Long_Long_Integer is
     (Postgres_Wire.Integer_Value (Data (This), Wire (Item)));

   function Boolean_Value (This : Connection; Item : Field) return Boolean is
     (Postgres_Wire.Boolean_Value (Data (This), Wire (Item)));

   function Float_Value (This : Connection; Item : Field) return Long_Float is
     (Postgres_Wire.Float_Value (Data (This), Wire (Item)));

   function Timestamp_Value (This : Connection; Item : Field) return Unix_Microseconds is
      Value : constant Long_Long_Integer := Integer_Value (This, Item);
   begin
      if Is_Null (Item) then
         return 0;
      end if;
      return Unix_Microseconds (if Value > Long_Long_Integer'Last - Postgres_Epoch then Long_Long_Integer'Last
                                else Value + Postgres_Epoch);   --  'infinity' is int8'Last
   end Timestamp_Value;

   function Element_Count (This : Connection; Item : Field) return Natural is
     (Postgres_Wire.Element_Count (Data (This), Wire (Item)));

   function Element (This : Connection; Item : Field; Index : Positive) return Field is
     (Field (Postgres_Wire.Element (Data (This), Wire (Item), Index)));

   --  libpq 16 is the oldest with require_auth (and 14 the oldest with pipeline mode): refuse to start on an
   --  older one, before any connection is attempted, rather than fail on every Connect.
   Minimum_Libpq : constant := 16_00_00;

   --  180006 as "18.6"
   function Version_Image (Version : int) return String is
     (Encoding.Decimal_Image (Long_Long_Integer (Version / 10_000)) & "."
      & Encoding.Decimal_Image (Long_Long_Integer (Version mod 10_000)));

begin
   if PQlibVersion < Minimum_Libpq then
      declare
         Line    : constant String :=
           "sparrow: Sparrow needs libpq 16 or later, and this program loaded libpq " & Version_Image (PQlibVersion)
           & ". Install or update the system's PostgreSQL client library (libpq), then start it again."
           & ASCII.LF;
         Written : Integer;
      begin
         Written := GNAT.OS_Lib.Write (GNAT.OS_Lib.Standerr, Line'Address, Line'Length);
         pragma Unreferenced (Written);
         GNAT.OS_Lib.OS_Exit (1);
      end;
   end if;
end Sparrow.Postgres;
