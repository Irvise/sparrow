with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Checks; use Checks;
with Sparrow.Sqlite; use Sparrow.Sqlite;
with Sparrow.Sqlite.Migrations;
with Sparrow.Buffers;
with Sparrow.Templates.Bindings.Add_Rows;
with Sparrow.Encoding;

procedure Sqlite_Tests is
   use type Sparrow.UTF8_String;


   Db     : Database;
   Insert : Statement;
   Query  : Statement;
   Name   : constant Sparrow.UTF8_String := Sparrow.Encoding.From_Unicode ("Grüße, 世界");
   Id     : Long_Long_Integer;

   function Raises_Violation (Value : Sparrow.UTF8_String) return Boolean is begin
      Bind (Insert, 1, Value);
      Run (Insert);
      return False;
   exception
      when Constraint_Violation =>
         return True;
   end Raises_Violation;
begin
   Open (Db, In_Memory);
   Check (Is_Open (Db), "open in memory");
   Run_Script (Db, "create table item (id integer primary key, name text unique not null, size integer, "
               & "ratio real, flag integer, blob blob, owner integer references item (id))");

   Prepare (Db, Insert, "insert into item (name, size, ratio, flag, blob) values (?, ?, ?, ?, ?);  ");
   Bind (Insert, 1, Name);
   Bind (Insert, 2, Long_Long_Integer'(-9_000_000_000));
   Bind (Insert, 3, Long_Float'(2.5));
   Bind (Insert, 4, True);
   Bind_Blob (Insert, 5, "a" & ASCII.NUL & Character'Val (255));
   Run (Insert);
   Id := Last_Insert_Id (Db);
   Check (Id = 1 and then Changes (Db) = 1, "insert, rowid, changes");

   Prepare (Db, Query, "select name, size, ratio, flag, blob, owner from item where id = ?");
   Bind (Query, 1, Id);
   Check (Next_Row (Query), "a row");
   Check (Column_Count (Query) = 6 and then Column_Name (Query, 2) = "size", "columns");
   Check (Text (Query, 1) = Name, "UTF-8 text");
   Check (Integer_Value (Query, 2) = -9_000_000_000, "int64");
   Check (Float_Value (Query, 3) = 2.5, "real");
   Check (Boolean_Value (Query, 4), "boolean");
   Check (Bytes (Query, 5) = "a" & ASCII.NUL & Character'Val (255), "blob");
   Check (Is_Null (Query, 6) and then not Is_Null (Query, 1), "NULL");
   Check (Is_Null (Query, 7) and then Text (Query, 7) = "", "past the last column");
   Check (not Next_Row (Query), "one row only");
   Check (Text (Query, 1) = "" and then Integer_Value (Query, 2) = 0, "no current row");
   Reset (Query);

   --  Bindings are cleared by Run's reset: unbound name is NULL, which NOT NULL refuses.
   Check (Raises_Violation (Name), "UNIQUE is a Constraint_Violation");
   begin
      Run (Insert);
      Check (False, "NOT NULL is a Constraint_Violation");
   exception
      when Constraint_Violation => Check (True, "NOT NULL is a Constraint_Violation");
   end;
   begin
      Run_Script (Db, "insert into item (name, owner) values ('orphan', 99)");
      Check (False, "foreign keys are enforced");
   exception
      when Constraint_Violation => Check (True, "foreign keys are enforced");
   end;

   Begin_Transaction (Db);
   Bind (Insert, 1, Sparrow.UTF8_String'("rolled back"));
   Run (Insert);
   Rollback (Db);
   Begin_Transaction (Db);
   Bind (Insert, 1, Sparrow.UTF8_String'("kept"));
   Run (Insert);
   Commit (Db);
   Prepare (Db, Query, "select count(*), sum(name = 'kept') from item");
   Check (Next_Row (Query) and then Integer_Value (Query, 1) = 2 and then Integer_Value (Query, 2) = 1,
          "rollback and commit");
   Reset (Query);

   --  Text another program stored that is not UTF-8: Text refuses it, Bytes reads it.
   Run_Script (Db, "insert into item (name) values (cast (x'ff41' as text))");
   Prepare (Db, Query, "select name from item where id = last_insert_rowid()");
   Check (Next_Row (Query), "a row of bad text");
   begin
      declare
         Value : constant Sparrow.UTF8_String := Text (Query, 1);
      begin
         Check (False, "text that is not UTF-8 is refused, not" & Value'Length'Image & " bytes");
      end;
   exception
      when Database_Error => Check (True, "text that is not UTF-8 is refused");
   end;
   Check (Bytes (Query, 1) = Character'Val (255) & "A", "Bytes reads it anyway");
   Reset (Query);

   begin
      Prepare (Db, Query, "select 1; select 2");
      Check (False, "two statements in one Prepare are refused");
   exception
      when Database_Error => Check (True, "two statements in one Prepare are refused");
   end;
   begin
      Prepare (Db, Query, "selec 1");
      Check (False, "a syntax error");
   exception
      when Database_Error => Check (True, "a syntax error");
   end;
   begin
      Bind (Insert, 9, Long_Long_Integer'(1));
      Check (False, "a parameter out of range");
   exception
      when Database_Error => Check (True, "a parameter out of range");
   end;
   Finalize (Insert);
   Finalize (Query);
   Close (Db);
   Check (not Is_Open (Db), "close");

   --  A file database is in write-ahead-log mode.
   if Ada.Directories.Exists ("data/test.db") then
      Ada.Directories.Delete_File ("data/test.db");
   end if;
   Open (Db, "data/test.db");
   Prepare (Db, Query, "pragma journal_mode");
   Check (Next_Row (Query) and then Text (Query, 1) = "wal", "write-ahead log");
   Finalize (Query);
   Close (Db);

   begin
      Open (Db, "data/missing.db", (Mode => Read_Only, others => <>));
      Check (False, "opening a missing file read-only fails");
   exception
      when Database_Error => Check (not Is_Open (Db), "opening a missing file read-only fails");
   end;

   --  Many connections opening a new file at once (as a server's workers do): the WAL switch must not fail with
   --  "database is locked". Without the retry in Open this failed about one run in six.
   declare
      Fresh    : constant String := "data/concurrent.db";
      Failures : Natural := 0 with Atomic;

      procedure Remove (Name : String) is begin
         if Ada.Directories.Exists (Name) then
            Ada.Directories.Delete_File (Name);
         end if;
      end Remove;

      task type Opener;
      task body Opener is
         Mine : Database;
      begin
         Open (Mine, Fresh);
         Run_Script (Mine, "CREATE TABLE IF NOT EXISTS t (x)");
      exception
         when Database_Error => Failures := Failures + 1;
      end Opener;
   begin
      Remove (Fresh);
      Remove (Fresh & "-wal");
      Remove (Fresh & "-shm");
      declare
         Openers : array (1 .. 32) of Opener;
      begin
         null;   --  waits here for all of them
      end;
      Check (Failures = 0, "32 connections open a new file and create a table at once");
   end;

   --  columns by name, and migrations
   declare
      use Sparrow.Sqlite.Migrations;
      Fresh : Database;
      Rows  : Statement;
      Steps : constant Step_List :=
        [Step (1, "CREATE TABLE note (id INTEGER PRIMARY KEY, body TEXT NOT NULL)"),
         Step (2, "ALTER TABLE note ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;"
                  & " INSERT INTO note (body) VALUES ('first')")];
      Broken : constant Step_List := [Steps (1), Steps (2), Step (3, "INSERT INTO note (body) VALUES ('third');"
                                                                   & " ALTER TABLE nowhere ADD COLUMN x")];
   begin
      Open (Fresh, In_Memory);
      Check (Version (Fresh) = 0, "a new database is at version 0");
      Apply (Fresh, Steps);
      Check (Version (Fresh) = 2, "migrated to the last step");
      Apply (Fresh, Steps);
      Prepare (Fresh, Rows, "SELECT id, body AS text, pinned FROM note");
      Check (Next_Row (Rows) and then Text (Rows, "text") = "first" and then Integer_Value (Rows, "pinned") = 0
             and then Integer_Value (Rows, "id") = 1 and then not Next_Row (Rows),
             "each step ran once, and columns read by name");
      Check (Column_Index (Rows, "body") = 0 and then Column_Index (Rows, "text") = 2, "columns by their AS names");
      begin
         Check (Integer_Value (Rows, "missing") = 0, "an unknown column raises");
      exception
         when Database_Error => Check (True, "an unknown column raises");
      end;
      Finalize (Rows);

      begin
         Apply (Fresh, Broken);
         Check (False, "a failing step raises");
      exception
         when Error : Database_Error =>
            Check (Ada.Strings.Fixed.Index (Ada.Exceptions.Exception_Message (Error), "migration 3:") = 1,
                   "a failing step raises, naming it");
      end;
      Prepare (Fresh, Rows, "SELECT count(*) AS total FROM note");
      Check (Version (Fresh) = 2 and then Next_Row (Rows) and then Integer_Value (Rows, "total") = 1,
             "a failing step leaves the database as it was");
      Finalize (Rows);
      begin
         Apply (Fresh, [Steps (2), Steps (1)]);
         Check (False, "steps out of order are refused");
      exception
         when Program_Error => Check (True, "steps out of order are refused");
      end;
      Run_Script (Fresh, "INSERT INTO note (body, pinned) VALUES ('second', 1), ('third', 0)");
      Prepare (Fresh, Rows, "SELECT body, pinned FROM note WHERE id > ?1 ORDER BY id");
      Bind (Rows, 1, Long_Long_Integer'(0));
      declare
         Bodies : Ada.Strings.Unbounded.Unbounded_String;
         Pinned : Long_Long_Integer := 0;
         Last   : Natural := 0;
      begin
         for Row in Sparrow.Sqlite.Rows (Rows) loop
            Ada.Strings.Unbounded.Append (Bodies, String (Row.Text ("body")) & ",");
            Pinned := Pinned + Row.Integer_Value (2);
            Last := Row.Number;
         end loop;
         Check (Ada.Strings.Unbounded.To_String (Bodies) = "first,second,third," and then Pinned = 1
                and then Last = 3, "rows iterated in order, by name and number");
      end;
      Reset (Rows);
      Bind (Rows, 1, Long_Long_Integer'(100));
      for Row in Sparrow.Sqlite.Rows (Rows) loop
         Check (False, "no rows: no iterations " & String (Row.Text (1)));
      end loop;
      Finalize (Rows);

      --  rows into a template
      declare
         procedure Add_Rows is new Sparrow.Templates.Bindings.Add_Rows (Statement);
         Page  : Sparrow.Templates.Template;
         Data  : Sparrow.Templates.Bindings.Binding_Set;
         Into  : Sparrow.Buffers.Buffer;
         Valid : Boolean;
      begin
         Sparrow.Templates.Compile
           (Page, "{{#notes}}{{body}}{{#pinned}}*{{/pinned}};{{/notes}}{{^empty}}none{{/empty}}", Valid);
         Prepare (Fresh, Rows, "SELECT body, nullif(pinned, 0) AS pinned FROM note ORDER BY id");
         Add_Rows (Data, "notes", Rows);
         Finalize (Rows);
         Prepare (Fresh, Rows, "SELECT body FROM note WHERE id < 0");
         Add_Rows (Data, "empty", Rows);
         Finalize (Rows);
         Sparrow.Templates.Render (Page, Data, Into);
         Check (Valid and then Sparrow.Buffers.Content (Into) = "first;second*;third;none",
                "rows rendered by a template, a NULL as false, no rows as an empty list");
         Sparrow.Buffers.Free (Into);
      end;
      Close (Fresh);
   end;

   Finish ("sqlite");
end Sqlite_Tests;
