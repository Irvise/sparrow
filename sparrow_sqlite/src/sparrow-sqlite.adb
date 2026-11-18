with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings;
with Sparrow.Encoding;
with System.Storage_Elements;

package body Sparrow.Sqlite is

   use type System.Address;
   use type Strings.chars_ptr;
   use type Times.Milliseconds;

   SQLITE_OK         : constant := 0;
   SQLITE_BUSY       : constant := 5;   --  the primary code; extended codes add 256 * n
   SQLITE_CONSTRAINT : constant := 19;
   SQLITE_ROW        : constant := 100;
   SQLITE_DONE       : constant := 101;

   SQLITE_OPEN_READONLY      : constant := 16#0000_0001#;
   SQLITE_OPEN_READWRITE     : constant := 16#0000_0002#;
   SQLITE_OPEN_CREATE        : constant := 16#0000_0004#;
   SQLITE_OPEN_URI           : constant := 16#0000_0040#;
   SQLITE_PREPARE_PERSISTENT : constant := 16#01#;

   SQLITE_NULL : constant := 5;

   --  SQLITE_TRANSIENT: SQLite copies a bound value before the call returns.
   Transient : constant System.Address := System'To_Address (-1);   --  (sqlite3_destructor_type)-1

   function C_Open (File : char_array; Handle : access System.Address; Flags : int; Vfs : System.Address) return int
      with Import, Convention => C, External_Name => "sqlite3_open_v2";
   function C_Close (Handle : System.Address) return int
      with Import, Convention => C, External_Name => "sqlite3_close_v2";
   function C_Extended_Result_Codes (Handle : System.Address; On : int) return int
      with Import, Convention => C, External_Name => "sqlite3_extended_result_codes";
   function C_Busy_Timeout (Handle : System.Address; Milliseconds : int) return int
      with Import, Convention => C, External_Name => "sqlite3_busy_timeout";
   function C_Exec
     (Handle : System.Address; Sql : char_array; Callback, Argument : System.Address; Error : access Strings.chars_ptr)
      return int
      with Import, Convention => C, External_Name => "sqlite3_exec";
   procedure C_Free (Item : Strings.chars_ptr)
      with Import, Convention => C, External_Name => "sqlite3_free";
   function C_Errmsg (Handle : System.Address) return Strings.chars_ptr
      with Import, Convention => C, External_Name => "sqlite3_errmsg";
   function C_Errstr (Code : int) return Strings.chars_ptr
      with Import, Convention => C, External_Name => "sqlite3_errstr";
   function C_Last_Insert_Rowid (Handle : System.Address) return Long_Long_Integer
      with Import, Convention => C, External_Name => "sqlite3_last_insert_rowid";
   function C_Changes (Handle : System.Address) return int
      with Import, Convention => C, External_Name => "sqlite3_changes";

   function C_Prepare
     (Handle    : System.Address;
      Sql       : System.Address;
      Length    : int;
      Flags     : unsigned;
      Statement : access System.Address;
      Tail      : access System.Address) return int
      with Import, Convention => C, External_Name => "sqlite3_prepare_v3";
   function C_Finalize (Statement : System.Address) return int
      with Import, Convention => C, External_Name => "sqlite3_finalize";
   function C_Db_Handle (Statement : System.Address) return System.Address
      with Import, Convention => C, External_Name => "sqlite3_db_handle";
   function C_Step (Statement : System.Address) return int
      with Import, Convention => C, External_Name => "sqlite3_step";
   function C_Reset (Statement : System.Address) return int
      with Import, Convention => C, External_Name => "sqlite3_reset";
   function C_Clear_Bindings (Statement : System.Address) return int
      with Import, Convention => C, External_Name => "sqlite3_clear_bindings";

   function C_Bind_Text
     (Statement : System.Address; Index : int; Value : System.Address; Length : int; Destructor : System.Address)
      return int
      with Import, Convention => C, External_Name => "sqlite3_bind_text";
   function C_Bind_Blob
     (Statement : System.Address; Index : int; Value : System.Address; Length : int; Destructor : System.Address)
      return int
      with Import, Convention => C, External_Name => "sqlite3_bind_blob";
   function C_Bind_Int64 (Statement : System.Address; Index : int; Value : Long_Long_Integer) return int
      with Import, Convention => C, External_Name => "sqlite3_bind_int64";
   function C_Bind_Double (Statement : System.Address; Index : int; Value : double) return int
      with Import, Convention => C, External_Name => "sqlite3_bind_double";
   function C_Bind_Null (Statement : System.Address; Index : int) return int
      with Import, Convention => C, External_Name => "sqlite3_bind_null";

   function C_Column_Count (Statement : System.Address) return int
      with Import, Convention => C, External_Name => "sqlite3_column_count";
   function C_Column_Name (Statement : System.Address; Column : int) return Strings.chars_ptr
      with Import, Convention => C, External_Name => "sqlite3_column_name";
   function C_Column_Type (Statement : System.Address; Column : int) return int
      with Import, Convention => C, External_Name => "sqlite3_column_type";
   function C_Column_Text (Statement : System.Address; Column : int) return System.Address
      with Import, Convention => C, External_Name => "sqlite3_column_text";
   function C_Column_Blob (Statement : System.Address; Column : int) return System.Address
      with Import, Convention => C, External_Name => "sqlite3_column_blob";
   function C_Column_Bytes (Statement : System.Address; Column : int) return int
      with Import, Convention => C, External_Name => "sqlite3_column_bytes";
   function C_Column_Int64 (Statement : System.Address; Column : int) return Long_Long_Integer
      with Import, Convention => C, External_Name => "sqlite3_column_int64";
   function C_Column_Double (Statement : System.Address; Column : int) return double
      with Import, Convention => C, External_Name => "sqlite3_column_double";

   --  Something to point at for an empty value: SQLite reads none of it, but a null pointer would bind NULL.
   Nothing : aliased constant Character := ASCII.NUL;

   function Has_Nul (Text : String) return Boolean is (for some Symbol of Text => Symbol = ASCII.NUL);

   --  Raise for Code (not OK), with the connection's message when there is a connection.
   procedure Fail (Handle : System.Address; Code : int; What : String) with No_Return is
      Message : constant String :=
        (if Handle /= System.Null_Address then Strings.Value (C_Errmsg (Handle)) else Strings.Value (C_Errstr (Code)));
   begin
      if Code mod 256 = SQLITE_CONSTRAINT then
         raise Constraint_Violation with What & ": " & Message;
      end if;
      raise Database_Error with What & ": " & Message;
   end Fail;

   procedure Check (Handle : System.Address; Code : int; What : String) is begin
      if Code /= SQLITE_OK then
         Fail (Handle, Code, What);
      end if;
   end Check;

   ---------------------------------------------------------------------------------------------------------------
   --  databases

   procedure Open (This : in out Database; Path : String; Settings : Options := Default_Options) is
      Handle : aliased System.Address := System.Null_Address;
      Code   : int;
      Flags  : constant int :=
        (case Settings.Mode is
            when Read_Only  => SQLITE_OPEN_READONLY,
            when Read_Write => SQLITE_OPEN_READWRITE,
            when Create     => SQLITE_OPEN_READWRITE + SQLITE_OPEN_CREATE) + SQLITE_OPEN_URI;
   begin
      if Is_Open (This) then
         raise Database_Error with "the database is already open";
      elsif Has_Nul (Path) then
         raise Database_Error with "a database path cannot hold a NUL character";
      end if;

      Code := C_Open (To_C (Path), Handle'Access, Flags, System.Null_Address);
      if Code /= SQLITE_OK then
         declare
            Message : constant String :=
              (if Handle = System.Null_Address then "out of memory" else Strings.Value (C_Errmsg (Handle)));
         begin
            Code := C_Close (Handle);   --  a failed open still allocates
            raise Database_Error with "cannot open " & Path & ": " & Message;
         end;
      end if;

      This.Handle := Handle;
      Check (Handle, C_Extended_Result_Codes (Handle, 1), "open");
      Code := C_Busy_Timeout
        (Handle, int (Times.Milliseconds'Max (0, Times.Milliseconds'Min (Settings.Busy_Timeout, 2 ** 31 - 1))));
      begin
         if Settings.Foreign_Keys then
            Run_Script (This, "PRAGMA foreign_keys = ON");
         end if;
         if Settings.Write_Ahead_Log and then Settings.Mode /= Read_Only and then Path /= In_Memory then
            --  Switching a new file to WAL needs an exclusive lock. When several connections open it at once,
            --  SQLite answers SQLITE_BUSY at once instead of waiting (each holds the shared lock the other
            --  needs released), so the busy timeout does not apply: retry for as long as it would have waited.
            for Attempt in 0 .. Settings.Busy_Timeout / 10 loop
               declare
                  Error : aliased Strings.chars_ptr := Strings.Null_Ptr;
               begin
                  Code := C_Exec (Handle, To_C ("PRAGMA journal_mode = WAL"), System.Null_Address,
                                  System.Null_Address, Error'Access);
                  if Error /= Strings.Null_Ptr then
                     C_Free (Error);
                  end if;
               end;
               exit when Code mod 256 /= SQLITE_BUSY;
               delay 0.01;
            end loop;
            Check (Handle, Code, "open");
            Run_Script (This, "PRAGMA synchronous = NORMAL");
         end if;
      exception
         when others =>
            Close (This);
            raise;
      end;
   end Open;

   procedure Close (This : in out Database) is
      Code : int;
   begin
      if This.Handle /= System.Null_Address then
         Code := C_Close (This.Handle);   --  v2: deferred while statements remain, so nothing leaks
         pragma Unreferenced (Code);
         This.Handle := System.Null_Address;
      end if;
   end Close;

   overriding procedure Finalize (This : in out Database_Guard) is begin
      Close (This.Owner.all);
   end Finalize;

   overriding procedure Finalize (This : in out Statement_Guard) is begin
      Finalize (This.Owner.all);
   end Finalize;

   function Is_Open (This : Database) return Boolean is (This.Handle /= System.Null_Address);

   procedure Require_Open (This : Database) is begin
      if not Is_Open (This) then
         raise Database_Error with "the database is not open";
      end if;
   end Require_Open;

   procedure Run_Script (This : in out Database; Sql : String) is
      Error : aliased Strings.chars_ptr := Strings.Null_Ptr;
      Code  : int;
   begin
      Require_Open (This);
      if Has_Nul (Sql) then
         raise Database_Error with "SQL text cannot hold a NUL character";
      end if;
      Code := C_Exec (This.Handle, To_C (Sql), System.Null_Address, System.Null_Address, Error'Access);
      if Error /= Strings.Null_Ptr then
         C_Free (Error);   --  the same text is also the connection's message, which Fail reads
      end if;
      Check (This.Handle, Code, "script");
   end Run_Script;

   procedure Begin_Transaction (This : in out Database; Immediate : Boolean := True) is begin
      Run_Script (This, (if Immediate then "BEGIN IMMEDIATE" else "BEGIN"));
   end Begin_Transaction;

   procedure Commit (This : in out Database) is begin
      Run_Script (This, "COMMIT");
   end Commit;

   procedure Rollback (This : in out Database) is begin
      Run_Script (This, "ROLLBACK");
   end Rollback;

   function Last_Insert_Id (This : Database) return Long_Long_Integer is
     (if Is_Open (This) then C_Last_Insert_Rowid (This.Handle) else 0);

   function Changes (This : Database) return Natural is
     (if Is_Open (This) then Natural (int'Max (0, C_Changes (This.Handle))) else 0);

   ---------------------------------------------------------------------------------------------------------------
   --  statements

   procedure Prepare (This : in out Database; Into : in out Statement; Sql : String) is
      Handle : aliased System.Address := System.Null_Address;
      Tail   : aliased System.Address := System.Null_Address;
      Code   : int;
   begin
      Require_Open (This);
      Finalize (Into);
      if Sql'Length = 0 or else Sql'Length >= int'Last then
         raise Database_Error with "prepare: no SQL";
      end if;

      Code := C_Prepare (This.Handle, Sql (Sql'First)'Address, int (Sql'Length), SQLITE_PREPARE_PERSISTENT,
                         Handle'Access, Tail'Access);
      Check (This.Handle, Code, "prepare");
      if Handle = System.Null_Address then
         raise Database_Error with "prepare: the SQL holds no statement";
      end if;

      --  What follows the first statement must be blank (or a ';'): a second statement would be ignored.
      declare
         use System.Storage_Elements;
         Used : constant Storage_Offset := Tail - Sql (Sql'First)'Address;
      begin
         if Used in 0 .. Storage_Offset (Sql'Length - 1)
           and then (for some Symbol of Sql (Sql'First + Integer (Used) .. Sql'Last) =>
                       Symbol not in ' ' | ';' | ASCII.HT | ASCII.LF | ASCII.CR)
         then
            Code := C_Finalize (Handle);
            raise Database_Error with "prepare: one statement at a time (use Run_Script for several)";
         end if;
      end;
      Into.Handle  := Handle;
      Into.Has_Row := False;
   end Prepare;

   procedure Finalize (This : in out Statement) is
      Code : int;
   begin
      if This.Handle /= System.Null_Address then
         Code := C_Finalize (This.Handle);
         pragma Unreferenced (Code);
         This.Handle  := System.Null_Address;
         This.Has_Row := False;
      end if;
   end Finalize;

   function Is_Prepared (This : Statement) return Boolean is (This.Handle /= System.Null_Address);

   function Connection (This : Statement) return System.Address is (C_Db_Handle (This.Handle));

   procedure Require_Prepared (This : Statement) is begin
      if not Is_Prepared (This) then
         raise Database_Error with "the statement is not prepared";
      end if;
   end Require_Prepared;

   procedure Bound (This : Statement; Code : int) is begin
      Check (Connection (This), Code, "bind");
   end Bound;

   function Address_Of (Value : String) return System.Address is
     (if Value'Length = 0 then Nothing'Address else Value (Value'First)'Address);

   procedure Bind (This : in out Statement; Index : Positive; Value : UTF8_String) is begin
      Require_Prepared (This);
      if Value'Length >= int'Last then
         raise Database_Error with "bind: text too long";
      end if;
      Bound (This, C_Bind_Text (This.Handle, int (Index), Address_Of (String (Value)), int (Value'Length),
                                Transient));
   end Bind;

   procedure Bind (This : in out Statement; Index : Positive; Value : Long_Long_Integer) is begin
      Require_Prepared (This);
      Bound (This, C_Bind_Int64 (This.Handle, int (Index), Value));
   end Bind;

   procedure Bind (This : in out Statement; Index : Positive; Value : Long_Float) is begin
      Require_Prepared (This);
      if not Value'Valid then
         raise Database_Error with "bind: not a number";
      end if;
      Bound (This, C_Bind_Double (This.Handle, int (Index), double (Value)));
   end Bind;

   procedure Bind (This : in out Statement; Index : Positive; Value : Boolean) is begin
      Bind (This, Index, Long_Long_Integer'(if Value then 1 else 0));
   end Bind;

   procedure Bind_Blob (This : in out Statement; Index : Positive; Value : String) is begin
      Require_Prepared (This);
      if Value'Length >= int'Last then
         raise Database_Error with "bind: blob too long";
      end if;
      Bound (This, C_Bind_Blob (This.Handle, int (Index), Address_Of (Value), int (Value'Length), Transient));
   end Bind_Blob;

   procedure Bind_Null (This : in out Statement; Index : Positive) is begin
      Require_Prepared (This);
      Bound (This, C_Bind_Null (This.Handle, int (Index)));
   end Bind_Null;

   function Next_Row (This : in out Statement) return Boolean is
      Code : int;
   begin
      Require_Prepared (This);
      Code := C_Step (This.Handle);
      This.Has_Row := Code = SQLITE_ROW;
      if Code /= SQLITE_ROW and then Code /= SQLITE_DONE then
         declare
            Ignored : constant int := C_Reset (This.Handle);   --  ready for another try
            pragma Unreferenced (Ignored);
         begin
            Fail (Connection (This), Code, "step");
         end;
      end if;
      return This.Has_Row;
   end Next_Row;

   procedure Run (This : in out Statement) is begin
      while Next_Row (This) loop
         null;
      end loop;
      Reset (This);
   exception
      when others =>
         if Is_Prepared (This) then
            Reset (This);
         end if;
         raise;
   end Run;

   procedure Reset (This : in out Statement) is
      Code : int;
   begin
      Require_Prepared (This);
      Code := C_Reset (This.Handle);   --  repeats the last step's error, already raised then
      pragma Unreferenced (Code);
      Check (Connection (This), C_Clear_Bindings (This.Handle), "reset");
      This.Has_Row := False;
   end Reset;

   ---------------------------------------------------------------------------------------------------------------
   --  the current row

   function Column_Count (This : Statement) return Natural is
     (if Is_Prepared (This) then Natural (C_Column_Count (This.Handle)) else 0);

   function Column_Name (This : Statement; Column : Positive) return String is
     (if Column <= Column_Count (This) then Strings.Value (C_Column_Name (This.Handle, int (Column - 1))) else "");

   --  Whether Column of the current row can be read.
   function Readable (This : Statement; Column : Positive) return Boolean is
     (This.Has_Row and then Column <= Column_Count (This));

   function Is_Null (This : Statement; Column : Positive) return Boolean is
     (not Readable (This, Column) or else C_Column_Type (This.Handle, int (Column - 1)) = SQLITE_NULL);

   --  The bytes at Where, Length of them.
   function Copy (Where : System.Address; Length : int) return String is begin
      if Where = System.Null_Address or else Length <= 0 then
         return "";
      end if;
      declare
         Value : String (1 .. Natural (Length)) with Import, Address => Where;
      begin
         return Value;
      end;
   end Copy;

   function Bytes (This : Statement; Column : Positive) return String is begin
      if not Readable (This, Column) then
         return "";
      end if;
      declare
         Where : constant System.Address := C_Column_Blob (This.Handle, int (Column - 1));
      begin
         return Copy (Where, C_Column_Bytes (This.Handle, int (Column - 1)));   --  bytes after blob: SQLite's order
      end;
   end Bytes;

   function Text (This : Statement; Column : Positive) return UTF8_String is begin
      if not Readable (This, Column) then
         return "";
      end if;
      declare
         Where : constant System.Address := C_Column_Text (This.Handle, int (Column - 1));
         Value : constant String := Copy (Where, C_Column_Bytes (This.Handle, int (Column - 1)));
      begin
         if not Sparrow.Encoding.Valid_Utf8 (Value) then
            raise Database_Error with "column" & Column'Image & " holds text that is not UTF-8 (read it with Bytes)";
         end if;
         return Sparrow.Encoding.To_UTF8 (Value);
      end;
   end Text;

   function Integer_Value (This : Statement; Column : Positive) return Long_Long_Integer is
     (if Readable (This, Column) then C_Column_Int64 (This.Handle, int (Column - 1)) else 0);

   function Float_Value (This : Statement; Column : Positive) return Long_Float is
     (if Readable (This, Column) then Long_Float (C_Column_Double (This.Handle, int (Column - 1))) else 0.0);

   function Boolean_Value (This : Statement; Column : Positive) return Boolean is (Integer_Value (This, Column) /= 0);

   ---------------------------------------------------------------------------------------------------------------
   --  columns by name

   function Column_Index (This : Statement; Name : String) return Natural is
   begin
      for Column in 1 .. Column_Count (This) loop
         if Column_Name (This, Column) = Name then
            return Column;
         end if;
      end loop;
      return 0;
   end Column_Index;

   function Named (This : Statement; Name : String) return Positive is
      Column : constant Natural := Column_Index (This, Name);
   begin
      if Column = 0 then
         raise Database_Error with "the statement has no column named """ & Name & """";
      end if;
      return Column;
   end Named;

   function Is_Null (This : Statement; Name : String) return Boolean is (Is_Null (This, Named (This, Name)));
   function Text (This : Statement; Name : String) return UTF8_String is (Text (This, Named (This, Name)));
   function Bytes (This : Statement; Name : String) return String is (Bytes (This, Named (This, Name)));
   function Integer_Value (This : Statement; Name : String) return Long_Long_Integer is
     (Integer_Value (This, Named (This, Name)));
   function Float_Value (This : Statement; Name : String) return Long_Float is
     (Float_Value (This, Named (This, Name)));
   function Boolean_Value (This : Statement; Name : String) return Boolean is
     (Boolean_Value (This, Named (This, Name)));

   ---------------------------------------------------------------------------------------------------------------
   --  rows

   function Number (This : Row) return Positive is (This.Position);

   function Is_Null (This : Row; Column : String) return Boolean is (Is_Null (This.Source.all, Column));
   function Text (This : Row; Column : String) return UTF8_String is (Text (This.Source.all, Column));
   function Bytes (This : Row; Column : String) return String is (Bytes (This.Source.all, Column));
   function Integer_Value (This : Row; Column : String) return Long_Long_Integer is
     (Integer_Value (This.Source.all, Column));
   function Float_Value (This : Row; Column : String) return Long_Float is (Float_Value (This.Source.all, Column));
   function Boolean_Value (This : Row; Column : String) return Boolean is (Boolean_Value (This.Source.all, Column));

   function Is_Null (This : Row; Column : Positive) return Boolean is (Is_Null (This.Source.all, Column));
   function Text (This : Row; Column : Positive) return UTF8_String is (Text (This.Source.all, Column));
   function Bytes (This : Row; Column : Positive) return String is (Bytes (This.Source.all, Column));
   function Integer_Value (This : Row; Column : Positive) return Long_Long_Integer is
     (Integer_Value (This.Source.all, Column));
   function Float_Value (This : Row; Column : Positive) return Long_Float is
     (Float_Value (This.Source.all, Column));
   function Boolean_Value (This : Row; Column : Positive) return Boolean is
     (Boolean_Value (This.Source.all, Column));

   function Has_Element (Position : Row) return Boolean is (Position.Source /= null and then Position.Position > 0);

   --  In a package of its own, so that First and Next are primitive of the iterator only (Row is tagged too).
   package Walking is
      type Row_Walk is new Row_Iterators.Forward_Iterator with record
         Source : Statement_View;
      end record;

      overriding function First (Object : Row_Walk) return Row;
      overriding function Next (Object : Row_Walk; Position : Row) return Row;
   end Walking;

   package body Walking is
      overriding function First (Object : Row_Walk) return Row is
        ((Source => Object.Source, Position => (if Next_Row (Object.Source.all) then 1 else 0)));

      overriding function Next (Object : Row_Walk; Position : Row) return Row is
        ((Source   => Object.Source,
          Position => (if Position.Position > 0 and then Next_Row (Object.Source.all) then Position.Position + 1
                       else 0)));
   end Walking;

   function Rows (This : in out Statement) return Row_Iterators.Forward_Iterator'Class is
     (Walking.Row_Walk'(Source => This'Unrestricted_Access));   --  Statement is limited: by reference

end Sparrow.Sqlite;
