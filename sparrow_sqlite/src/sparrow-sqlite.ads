--  SQLite, as a thin binding to the system's libsqlite3: open a database, prepare statements, bind, step,
--  read columns. Parameters and columns are numbered from 1.
--
--  A Database and its Statements belong to one task: give each worker its own Database on the same file
--  (write-ahead logging lets readers run beside one writer). SQLite calls block: never on a reactor.
--
--  TEXT is UTF8_String going in. SQLite does not check what it stores, so coming out Text checks: a TEXT
--  value that is not UTF-8 (written by some other program) raises Database_Error; Bytes reads it regardless.
--
--  Not SPARK. Errors raise Database_Error with SQLite's message, or Constraint_Violation when a UNIQUE,
--  NOT NULL, CHECK or FOREIGN KEY constraint refused a write. Reading a column of the wrong type converts as
--  SQLite does; reading with no current row gives "", 0 or False.
--
--     Prepare (Db, Find, "SELECT id, name FROM users WHERE email = ?");
--     ...
--     Bind (Find, 1, Email);
--     for Row in Rows (Find) loop ... Row.Integer_Value ("id") ... Row.Text ("name") ... end loop;
--     Reset (Find);
--
--  A Statement is finalized, and a Database closed, when it goes out of scope (or on Finalize and Close).
--  Sparrow.Sqlite.Per_Worker keeps one Database per worker task of a server.
with Ada.Iterator_Interfaces;
with Sparrow.Times;
private with Ada.Finalization;
private with System;

package Sparrow.Sqlite is

   Database_Error       : exception;
   Constraint_Violation : exception;

   type Open_Mode is (Read_Only, Read_Write, Create);   --  Create: read-write, made if missing

   type Options is record
      Mode            : Open_Mode := Create;
      Busy_Timeout    : Sparrow.Times.Milliseconds := 5_000;   --  how long to wait for another connection's lock
      Write_Ahead_Log : Boolean := True;                       --  journal_mode=WAL, synchronous=NORMAL
      Foreign_Keys    : Boolean := True;                       --  SQLite leaves them off unless asked
   end record;

   Default_Options : constant Options := (others => <>);

   In_Memory : constant String := ":memory:";

   type Database is limited private;
   type Statement is limited private;

   ---------------------------------------------------------------------------------------------------------------
   --  databases

   procedure Open (This : in out Database; Path : String; Settings : Options := Default_Options);

   --  Statements of This still prepared keep it open until they are finalized.
   procedure Close (This : in out Database);

   function Is_Open (This : Database) return Boolean;

   --  Run SQL text as it is: schema set-up, migrations, pragmas. Several statements may be separated by ';'.
   --  Never build Sql from request data: that is what Bind is for.
   procedure Run_Script (This : in out Database; Sql : String);

   --  BEGIN IMMEDIATE takes the write lock at once, so a transaction that will write cannot fail half-way for
   --  want of it.
   procedure Begin_Transaction (This : in out Database; Immediate : Boolean := True);
   procedure Commit (This : in out Database);
   procedure Rollback (This : in out Database);

   --  The rowid of the last successful INSERT on this connection, and the rows the last statement changed.
   function Last_Insert_Id (This : Database) return Long_Long_Integer;
   function Changes (This : Database) return Natural;

   ---------------------------------------------------------------------------------------------------------------
   --  statements

   --  Compile Sql (one statement, with ? or ?NNN parameters) into Into. Prepare once and reuse.
   procedure Prepare (This : in out Database; Into : in out Statement; Sql : String);

   --  Release This (done anyway when it goes out of scope).
   procedure Finalize (This : in out Statement);

   function Is_Prepared (This : Statement) return Boolean;

   procedure Bind (This : in out Statement; Index : Positive; Value : UTF8_String);         --  TEXT
   procedure Bind (This : in out Statement; Index : Positive; Value : Long_Long_Integer);
   procedure Bind (This : in out Statement; Index : Positive; Value : Long_Float);
   procedure Bind (This : in out Statement; Index : Positive; Value : Boolean);             --  0 or 1
   procedure Bind_Blob (This : in out Statement; Index : Positive; Value : String);
   procedure Bind_Null (This : in out Statement; Index : Positive);

   --  Advance to the next row; False when there are no more.
   function Next_Row (This : in out Statement) return Boolean;

   --  Run a statement that returns no rows (or whose rows are not wanted) to its end, then Reset it.
   procedure Run (This : in out Statement);

   --  Ready to be bound and run again; the bindings are cleared.
   procedure Reset (This : in out Statement);

   ---------------------------------------------------------------------------------------------------------------
   --  the current row

   function Column_Count (This : Statement) return Natural;
   function Column_Name (This : Statement; Column : Positive) return String;

   function Is_Null (This : Statement; Column : Positive) return Boolean;
   function Text (This : Statement; Column : Positive) return UTF8_String;
   function Bytes (This : Statement; Column : Positive) return String;                      --  BLOB, or TEXT unchecked
   function Integer_Value (This : Statement; Column : Positive) return Long_Long_Integer;
   function Float_Value (This : Statement; Column : Positive) return Long_Float;
   function Boolean_Value (This : Statement; Column : Positive) return Boolean;             --  non-zero

   --  The same by column name (as the SELECT names it: use AS for expressions). Column_Index is 0 when there
   --  is no such column; the others raise Database_Error then, as a misspelt name is a bug to find early.
   --
   --     while Next_Row (Query) loop
   --        Show (Integer_Value (Query, "id"), Text (Query, "title"));
   --     end loop;
   function Column_Index (This : Statement; Name : String) return Natural;
   function Is_Null (This : Statement; Name : String) return Boolean;
   function Text (This : Statement; Name : String) return UTF8_String;
   function Bytes (This : Statement; Name : String) return String;
   function Integer_Value (This : Statement; Name : String) return Long_Long_Integer;
   function Float_Value (This : Statement; Name : String) return Long_Float;
   function Boolean_Value (This : Statement; Name : String) return Boolean;

   ---------------------------------------------------------------------------------------------------------------
   --  Iterating over the rows: each step of the loop is a Next_Row.
   --
   --     Bind (Find, 1, Email);
   --     for Row in Rows (Find) loop
   --        Show (Row.Integer_Value ("id"), Row.Text ("name"));
   --     end loop;

   --  The current row of a statement, its columns by name or number as above.
   type Row is tagged private;

   function Number (This : Row) return Positive;   --  1 for the first row

   function Is_Null (This : Row; Column : String) return Boolean;
   function Text (This : Row; Column : String) return UTF8_String;
   function Bytes (This : Row; Column : String) return String;
   function Integer_Value (This : Row; Column : String) return Long_Long_Integer;
   function Float_Value (This : Row; Column : String) return Long_Float;
   function Boolean_Value (This : Row; Column : String) return Boolean;

   function Is_Null (This : Row; Column : Positive) return Boolean;
   function Text (This : Row; Column : Positive) return UTF8_String;
   function Bytes (This : Row; Column : Positive) return String;
   function Integer_Value (This : Row; Column : Positive) return Long_Long_Integer;
   function Float_Value (This : Row; Column : Positive) return Long_Float;
   function Boolean_Value (This : Row; Column : Positive) return Boolean;

   function Has_Element (Position : Row) return Boolean;
   package Row_Iterators is new Ada.Iterator_Interfaces (Row, Has_Element);

   --  Steps This through its rows. Leaving the loop early leaves the rest unread: Reset before running it again.
   function Rows (This : in out Statement) return Row_Iterators.Forward_Iterator'Class;

private

   --  Components that close or finalize their owner when it goes out of scope. (Not the owners themselves
   --  controlled: Prepare takes both, and may dispatch on only one tagged type.)
   type Database_Guard (Owner : not null access Database) is new Ada.Finalization.Limited_Controlled
      with null record;
   overriding procedure Finalize (This : in out Database_Guard);

   type Statement_Guard (Owner : not null access Statement) is new Ada.Finalization.Limited_Controlled
      with null record;
   overriding procedure Finalize (This : in out Statement_Guard);

   type Database is limited record
      Handle : System.Address := System.Null_Address;   --  sqlite3*
      Guard  : Database_Guard (Database'Access);
   end record;

   type Statement is limited record
      Handle  : System.Address := System.Null_Address;  --  sqlite3_stmt*
      Has_Row : Boolean := False;
      Guard   : Statement_Guard (Statement'Access);
   end record;

   type Statement_View is access all Statement;

   type Row is tagged record
      Source   : Statement_View;
      Position : Natural := 0;   --  0 once the rows are done
   end record;

end Sparrow.Sqlite;
