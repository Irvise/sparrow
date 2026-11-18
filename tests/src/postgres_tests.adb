with Ada.Text_IO; use Ada.Text_IO;
with Checks; use Checks;
with Ada.Exceptions;
with Sparrow.Postgres; use Sparrow.Postgres;
with Sparrow.Postgres.Migrations;
with Sparrow.Postgres.Queries;
with Sparrow.Buffers;
with Sparrow.Templates.Bindings.Add_Rows;
with Sparrow.Times; use Sparrow.Times;

--  Against the server postgres_server.sh starts; skipped when nothing listens on localhost:15432.
procedure Postgres_Tests is
   use Sparrow;

   Base  : constant String := "postgres://postgres:sparrow%20p%C3%A4ssword@localhost:15432/sparrow";
   Plain : constant String := Base & "?sslmode=disable";
   Safe  : constant String := Base & "?sslmode=verify-full&sslrootcert=data/cert.pem&application_name=sparrow-tests";

   --  Whether connecting to Url fails, and Last_Failure then holds Expected.
   function Refused (Url : String; Expected : String) return Boolean is
      Db : Connection;
   begin
      Connect (Db, Url);
      Disconnect (Db);
      return False;
   exception
      when Connection_Error =>
         declare
            Reason : constant String := Last_Failure (Db);
            Found  : constant Boolean :=
              (for some Position in Reason'First .. Reason'Last - Expected'Length + 1 =>
                 Reason (Position .. Position + Expected'Length - 1) = Expected);
         begin
            if not Found then
               Put_Line ("   refused for another reason: " & Reason);
            end if;
            Disconnect (Db);
            return Found;
         end;
   end Refused;

   Insert_Item : aliased constant Statement := Define
     ("insert_item",
      "insert into item (small, medium, large, name, flag, ratio, single, stamp, blob, numbers, words) "
      & "values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) returning id",
      [Int2_Oid, Int4_Oid, Int8_Oid, Text_Oid, Bool_Oid, Float8_Oid, Float4_Oid, Timestamptz_Oid, Bytea_Oid,
       Int4_Array_Oid, Text_Array_Oid]);
   Select_Item : aliased constant Statement := Define
     ("select_item",
      "select small, medium, large, name, flag, ratio, single, stamp, blob, numbers, words from item where id = $1",
      [Int8_Oid]);
   Rename_All  : aliased constant Statement := Define ("rename_all", "update item set name = $1", [Text_Oid]);
   Insert_Name : aliased constant Statement := Define
     ("insert_name", "insert into item (name) values ($1)", [Text_Oid]);
   Count_Items : aliased constant Statement := Define ("count_items", "select count(*) from item");
   Insert_Small : aliased constant Statement := Define
     ("insert_small", "insert into item (name, small, single) values ($1, $2, $3)");   --  types inferred
   Find_Small   : aliased constant Statement := Define
     ("find_small", "select small, name as label, single from item where name like $1 order by id");
   Using_Tls   : aliased constant Statement := Define
     ("using_tls", "select ssl, current_setting('application_name') from pg_stat_ssl where pid = pg_backend_pid()");

   Db      : Connection;
   Result  : Statement_Result;
   Results : Result_Array (1 .. 3);
   Stamp   : constant Unix_Microseconds := 1_700_000_000_123_456;
   Name    : constant UTF8_String := "Grüße, 世界";
   Id      : Long_Long_Integer;
begin
   begin
      Connect (Db, Plain);
   exception
      when Connection_Error =>
         Put_Line ("postgres: skipped, no test server (run tests/postgres_server.sh): " & Last_Failure (Db));
         Disconnect (Db);
         return;
   end;
   Check (Is_Connected (Db), "connect with SCRAM, unencrypted");
   Disconnect (Db);
   Check (not Is_Connected (Db), "disconnect");

   Check (Refused ("postgres://postgres:wrong@localhost:15432/sparrow?sslmode=disable", "password"),
          "a wrong password is refused");
   Check (Refused (Base & "?sslmode=verify-full", "certificate verify failed"),
          "self-signed certificate against the system roots");
   Check (Refused ("postgres://postgres:x@127.0.0.1:15432/sparrow?sslmode=verify-full&sslrootcert=data/cert.pem",
                   "does not match host name"),
          "verify-full refuses a certificate that does not name the host");
   Check (Refused (Base & "?sslmode=sometimes", "sslmode"), "an unknown sslmode");
   Check (Refused ("postgres://postgres:x@localhost:1/sparrow?connect_timeout=2", "connect"), "connection refused");
   Check (Refused ("postgres://localhost:99999/x", "invalid port"), "bad port");

   Connect (Db, Safe);
   Prepare (Db, Using_Tls);
   Bind (Db, Using_Tls);
   Execute (Db);
   Fetch (Db, Result);
   Check (Result.Succeeded and then Result.Row_Count = 1 and then Boolean_Value (Db, Field_At (Db, Result, 1, 1)),
          "verify-full: the session is encrypted");
   Check (Text (Db, Field_At (Db, Result, 1, 2)) = "sparrow-tests", "URL options become session settings");

   Run_Script (Db, "drop table if exists item; create table item (id bigserial primary key, small int2, "
               & "medium int4, large int8, name text unique, flag bool, ratio float8, single float4, "
               & "stamp timestamptz, blob bytea, numbers int4[], words text[])", Result);
   Check (Result.Succeeded, "run a script: " & Last_Failure (Db));

   --  The statements are local to this test program, which outlives the connection: the accesses do not dangle.
   Prepare (Db, Statement_List'[Insert_Item'Unchecked_Access, Select_Item'Unchecked_Access,
                                Rename_All'Unchecked_Access, Insert_Name'Unchecked_Access,
                                Count_Items'Unchecked_Access]);

   Bind (Db, Insert_Item);
   Add_Parameter (Db, Long_Long_Integer'(-12));
   Add_Parameter (Db, Long_Long_Integer'(-100_000));
   Add_Parameter (Db, Long_Long_Integer'(9_000_000_000));
   Add_Parameter (Db, Name);
   Add_Parameter (Db, True);
   Add_Parameter (Db, Long_Float'(2.5));
   Add_Parameter (Db, Long_Float'(-0.25));
   Add_Timestamp (Db, Stamp);
   Add_Bytes (Db, "a" & ASCII.NUL & Character'Val (255));
   Begin_Array (Db, Int4_Oid, 3);
   Add_Element (Db, Long_Long_Integer'(1));
   Add_Element (Db, Long_Long_Integer'(-2));
   Add_Element (Db, Long_Long_Integer'(300));
   End_Array (Db);
   Begin_Array (Db, Text_Oid, 0);
   End_Array (Db);
   Execute (Db);
   Fetch (Db, Result);
   Check (Result.Succeeded and then Result.Row_Count = 1, "insert every parameter type: " & Last_Failure (Db));
   Id := Integer_Value (Db, Field_At (Db, Result, 1, 1));
   Check (Id >= 1, "returning id");

   Bind (Db, Select_Item);
   Add_Parameter (Db, Id);
   Execute (Db);
   Fetch (Db, Result);
   Check (Result.Succeeded and then Result.Row_Count = 1 and then Result.Column_Count = 11, "select it back");
   Check (Integer_Value (Db, Field_At (Db, Result, 1, 1)) = -12, "int2");
   Check (Integer_Value (Db, Field_At (Db, Result, 1, 2)) = -100_000, "int4");
   Check (Integer_Value (Db, Field_At (Db, Result, 1, 3)) = 9_000_000_000, "int8");
   Check (Text (Db, Field_At (Db, Result, 1, 4)) = Name, "UTF-8 text");
   Check (Boolean_Value (Db, Field_At (Db, Result, 1, 5)), "bool");
   Check (Float_Value (Db, Field_At (Db, Result, 1, 6)) = 2.5, "float8");
   Check (Float_Value (Db, Field_At (Db, Result, 1, 7)) = -0.25, "float4");
   Check (Timestamp_Value (Db, Field_At (Db, Result, 1, 8)) = Stamp, "timestamptz");
   Check (Bytes (Db, Field_At (Db, Result, 1, 9)) = "a" & ASCII.NUL & Character'Val (255), "bytea");
   declare
      Numbers : constant Sparrow.Postgres.Field := Field_At (Db, Result, 1, 10);
   begin
      Check (Element_Count (Db, Numbers) = 3
             and then Integer_Value (Db, Element (Db, Numbers, 2)) = -2
             and then Integer_Value (Db, Element (Db, Numbers, 3)) = 300
             and then Is_Null (Element (Db, Numbers, 4)), "int4[]");
   end;
   Check (Element_Count (Db, Field_At (Db, Result, 1, 11)) = 0, "empty text[]");
   Check (Is_Null (Field_At (Db, Result, 1, 12)) and then Is_Null (Field_At (Db, Result, 2, 1)),
          "outside the result reads as NULL");

   --  A pipeline: three groups sent at once, read in order. The second fails and leaves the others alone.
   Bind (Db, Insert_Name); Add_Parameter (Db, UTF8_String'("second")); Execute (Db); Sync (Db);
   Bind (Db, Insert_Name); Add_Parameter (Db, Name); Execute (Db);
   Bind (Db, Insert_Name); Add_Parameter (Db, UTF8_String'("skipped")); Execute (Db); Sync (Db);
   Bind (Db, Count_Items); Execute (Db); Sync (Db);
   Flush (Db);
   Read_Results (Db, Results (1 .. 1));
   Check (Results (1).Succeeded and then Results (1).Affected_Rows = 1, "pipelined insert");
   Read_Results (Db, Results (1 .. 2));
   Check (not Results (1).Succeeded and then Results (1).State = Unique_Violation, "unique violation's SQLSTATE");
   Check (not Results (2).Succeeded and then Results (2).State = No_State, "the rest of a failed group is skipped");
   Read_Results (Db, Results (1 .. 1));
   Check (Results (1).Succeeded and then Integer_Value (Db, Field_At (Db, Results (1), 1, 1)) = 2,
          "a failed group rolls back alone");

   Bind (Db, Rename_All);
   Add_Null (Db);
   Execute (Db);
   Fetch (Db, Result);
   Check (Result.Succeeded and then Result.Affected_Rows = 2, "affected rows of an update");

   --  Too few parameters: the pipeline cannot be sent, and the connection stays usable once it is discarded.
   Bind (Db, Select_Item);
   Execute (Db);
   begin
      Fetch (Db, Result);
      Check (False, "a statement missing parameters is refused");
   exception
      when Connection_Error =>
         Check (True, "a statement missing parameters is refused");
         Discard_Unsent (Db);
   end;
   Bind (Db, Insert_Item);
   Add_Parameter (Db, Long_Long_Integer'(40_000));   --  does not fit int2
   begin
      Flush (Db);
      Check (False, "an integer too wide for its parameter is refused");
   exception
      when Connection_Error =>
         Check (True, "an integer too wide for its parameter is refused");
         Discard_Unsent (Db);
   end;
   Bind (Db, Count_Items);
   Execute (Db);
   Fetch (Db, Result);
   Check (Result.Succeeded and then Integer_Value (Db, Field_At (Db, Result, 1, 1)) = 2,
          "usable after discarding");

   Run_Script (Db, "selec 1", Result);
   Check (not Result.Succeeded and then Result.State = "42601" and then Last_Failure (Db)'Length > 0,
          "a script with a syntax error");
   Run_Script (Db, "begin; insert into item (name) values ('x'); rollback; select generate_series(1, 100000)", Result);
   Check (Result.Succeeded, "a script returning many rows");
   begin
      Prepare (Db, Count_Items);
      Check (False, "preparing a statement twice fails");
   exception
      when Connection_Error =>
         Check (Last_Failure (Db)'Length > 0, "preparing a statement twice fails");
   end;

   --  inferred parameter types, one-call queries, rows by name
   declare
      use Sparrow.Postgres.Queries;
      Seen  : Natural := 0;
      Total : Long_Long_Integer := 0;
   begin
      Prepare (Db, Insert_Small);
      Prepare (Db, Find_Small);
      Query (Db, Insert_Small, [+"inferred one", +Long_Long_Integer'(7), +Long_Float'(0.25)], Result);
      Check (Result.Succeeded and then Result.Affected_Rows = 1, "a one-call insert with inferred int2 and float4");
      Query (Db, Insert_Small, [+"inferred two", +Integer'(9), Null_Value], Result);
      Check (Result.Succeeded, "a one-call insert with a NULL: " & Last_Failure (Db));
      Query (Db, Find_Small, [+"inferred%"], Result);
      Check (Result.Succeeded and then Result.Row_Count = 2, "a one-call select");
      Check (Column_Of (Db, Result, "label") = 2 and then Column_Of (Db, Result, "name") = 0,
             "columns found by their AS names");
      Check (Text (Db, Field_At (Db, Result, 2, "label")) = "inferred two", "a field by column name");
      for Row in Rows (Db, Result) loop
         Seen  := Seen + 1;
         Total := Total + Row.Integer_Value ("small");
         Check (Row.Number = Seen and then Row.Text (2) = (if Seen = 1 then "inferred one" else "inferred two"),
                "rows in order, read by number");
         Check (Row.Is_Null ("single") = (Seen = 2), "NULL read by name");
      end loop;
      Check (Seen = 2 and then Total = 16 and then Float_Value (Db, Field_At (Db, Result, 1, "single")) = 0.25,
             "rows read by name");
      for Row in Rows (Db, Result) loop
         begin
            Check (Row.Integer_Value ("missing") = 0, "an unknown column raises");
         exception
            when Constraint_Error => Check (True, "an unknown column raises");
         end;
         exit;
      end loop;
      begin
         Query (Db, Find_Small, [+"x", +"too many"], Result);
         Check (False, "too many parameters raise");
      exception
         when Connection_Error => Check (True, "too many parameters raise");
      end;
      Query (Db, Count_Items, Result);
      Check (Result.Succeeded and then Result.Row_Count = 1, "usable after a refused query");

      --  rows into a template, decoded from binary by column type
      Query (Db, Find_Small, [+"inferred%"], Result);
      declare
         procedure Add_Rows is new Sparrow.Templates.Bindings.Add_Rows (Result_Reader);
         Page   : Sparrow.Templates.Template;
         Data   : Sparrow.Templates.Bindings.Binding_Set;
         Into   : Sparrow.Buffers.Buffer;
         Valid  : Boolean;
         Reading : Result_Reader := Reader (Db, Result);
      begin
         Sparrow.Templates.Compile
           (Page, "{{#items}}{{label}}={{small}}/{{single}}{{^single}}-{{/single}};{{/items}}", Valid);
         Add_Rows (Data, "items", Reading);
         Sparrow.Templates.Render (Page, Data, Into);
         Equal (Sparrow.Buffers.Content (Into), "inferred one=7/0.25;inferred two=9/-;",
                "Postgres rows rendered by a template");
         Sparrow.Buffers.Free (Into);
      end;
      Run_Script (Db, "SELECT 5 AS n, 'x' AS t", Result);
      declare
         Reading : Result_Reader := Reader (Db, Result);
      begin
         Check (Next_Row (Reading) and then Column_Name (Reading, 1) = "n" and then Text (Reading, 1) = "5"
                and then Text (Reading, 2) = "x" and then not Next_Row (Reading), "a script's text rows read as text");
      end;
   end;

   --  migrations
   declare
      package Migrations renames Sparrow.Postgres.Migrations;
      use Migrations;
      Steps  : constant Step_List :=
        [Step (1, "DROP TABLE IF EXISTS note; CREATE TABLE note (id bigserial PRIMARY KEY, body text NOT NULL)"),
         Step (2, "ALTER TABLE note ADD COLUMN pinned bool NOT NULL DEFAULT false;"
                  & " INSERT INTO note (body) VALUES ('first')")];
      Broken : constant Step_List :=
        [Steps (1), Steps (2), Step (3, "INSERT INTO note (body) VALUES ('third'); ALTER TABLE nowhere ADD x int")];
   begin
      Run_Script (Db, "DROP TABLE IF EXISTS schema_migrations", Result);
      Check (Migrations.Version (Db) = 0, "a database never migrated is at version 0");
      Apply (Db, Steps);
      Apply (Db, Steps);
      Check (Migrations.Version (Db) = 2, "migrated to the last step");
      Run_Script (Db, "SELECT count(*)::text FROM note", Result);   --  after Version: its script replaces the rows
      Check (Result.Succeeded and then Text (Db, Field_At (Db, Result, 1, 1)) = "1", "each step ran once");
      begin
         Apply (Db, Broken);
         Check (False, "a failing step raises");
      exception
         when Error : Migration_Error =>
            Check (Ada.Exceptions.Exception_Message (Error)'Length > 12
                   and then Ada.Exceptions.Exception_Message (Error) (1 .. 12) = "migration 3:",
                   "a failing step raises, naming it");
      end;
      Check (Migrations.Version (Db) = 2, "a failing step leaves the version as it was");
      Run_Script (Db, "SELECT count(*)::text FROM note", Result);
      Check (Text (Db, Field_At (Db, Result, 1, 1)) = "1", "a failing step leaves the data as it was");
   end;

   Disconnect (Db);
   Finish ("postgres");
end Postgres_Tests;
