with Sparrow.Encoding;

package body Sparrow.Postgres.Migrations is

   --  The advisory lock that serialises Apply across servers: an arbitrary constant ("spmigrat" in ASCII).
   Lock_Key : constant String := "8318268811227849076";

   function Image (Value : Natural) return String is (Encoding.Decimal_Image (Long_Long_Integer (Value)));

   --  Run Sql; on failure, roll back and raise Migration_Error with What and the server's reason.
   procedure Must (This : in out Connection; Sql, What : String) is
      Result : Statement_Result;
   begin
      Run_Script (This, Sql, Result);
      if not Result.Succeeded then
         declare
            Reason : constant String := Last_Failure (This);
         begin
            Run_Script (This, "ROLLBACK", Result);
            raise Migration_Error with What & ": " & Reason;
         end;
      end if;
   end Must;

   --  The last version recorded, from the text of a single-value result.
   function Scalar (This : in out Connection; Sql : String) return Natural is
      Result : Statement_Result;
   begin
      Run_Script (This, Sql, Result);
      if not Result.Succeeded or else Result.Row_Count = 0 then
         return 0;
      end if;
      return Natural'Value (String (Text (This, Field_At (This, Result, 1, 1))));
   end Scalar;

   function Version (This : in out Connection) return Natural is
     (Scalar (This, "SELECT coalesce((SELECT max(version) FROM schema_migrations), 0)::text"
                    & " WHERE to_regclass('schema_migrations') IS NOT NULL"));

   procedure Apply (This : in out Connection; Steps : Step_List) is
      Current : Natural;
   begin
      Sparrow.Migrations.Check_Order (Steps);
      Must (This, "BEGIN; SELECT pg_advisory_xact_lock(" & Lock_Key & ")", "migrations: take the lock");
      Must (This, "CREATE TABLE IF NOT EXISTS schema_migrations"
                  & " (version bigint PRIMARY KEY, applied timestamptz NOT NULL DEFAULT now())",
            "migrations: create schema_migrations");
      Current := Scalar (This, "SELECT coalesce(max(version), 0)::text FROM schema_migrations");
      for Each of Steps loop
         declare
            Number : constant Positive := Sparrow.Migrations.Version (Each);
         begin
            if Number > Current then
               Must (This, Sparrow.Migrations.Sql (Each), "migration " & Image (Number));
               Must (This, "INSERT INTO schema_migrations (version) VALUES (" & Image (Number) & ")",
                     "migration " & Image (Number));
            end if;
         end;
      end loop;
      Must (This, "COMMIT", "migrations: commit");
   end Apply;

end Sparrow.Postgres.Migrations;
