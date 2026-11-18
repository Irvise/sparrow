with Ada.Exceptions;
with Sparrow.Encoding;

package body Sparrow.Sqlite.Migrations is

   Bookkeeping : constant String :=
     "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied INTEGER NOT NULL)";

   function Image (Value : Natural) return String is (Encoding.Decimal_Image (Long_Long_Integer (Value)));

   --  The last version recorded; the table must exist.
   function Recorded (This : in out Database) return Natural is
      Query : Statement;
   begin
      Prepare (This, Query, "SELECT coalesce(max(version), 0) FROM schema_migrations");
      if Next_Row (Query) then
         return Natural (Integer_Value (Query, 1));
      end if;
      return 0;
   end Recorded;

   function Version (This : in out Database) return Natural is
      Query : Statement;
   begin
      Prepare (This, Query, "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'");
      if Next_Row (Query) and then Integer_Value (Query, 1) = 0 then
         return 0;
      end if;
      return Recorded (This);
   end Version;

   procedure Apply (This : in out Database; Steps : Step_List) is
      Current : Natural;
   begin
      Sparrow.Migrations.Check_Order (Steps);

      Begin_Transaction (This, Immediate => True);   --  takes the write lock: others wait here
      begin
         Run_Script (This, Bookkeeping);
         Current := Recorded (This);
         for Each of Steps loop
            if Sparrow.Migrations.Version (Each) > Current then
               begin
                  Run_Script (This, Sparrow.Migrations.Sql (Each));
               exception
                  when Error : Database_Error | Constraint_Violation =>
                     raise Database_Error with "migration " & Image (Sparrow.Migrations.Version (Each)) & ": "
                                               & Ada.Exceptions.Exception_Message (Error);
               end;
               declare
                  Record_It : Statement;
               begin
                  Prepare (This, Record_It,
                           "INSERT INTO schema_migrations (version, applied)"
                           & " VALUES (?1, CAST(strftime('%s', 'now') AS INTEGER))");
                  Bind (Record_It, 1, Long_Long_Integer (Sparrow.Migrations.Version (Each)));
                  Run (Record_It);
               end;
            end if;
         end loop;
         Commit (This);
      exception
         when others =>
            Rollback (This);
            raise;
      end;
   end Apply;

end Sparrow.Sqlite.Migrations;
