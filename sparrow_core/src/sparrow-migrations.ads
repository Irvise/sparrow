--  Schema changes for either database: an ordered list of steps, each a version number and the SQL that takes
--  the database to it. Sparrow.Sqlite.Migrations and Sparrow.Postgres.Migrations apply them.
--
--     Steps : constant Migrations.Step_List :=
--       [Migrations.Step (1, "CREATE TABLE todos (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"),
--        Migrations.Step (2, "ALTER TABLE todos ADD COLUMN done INTEGER NOT NULL DEFAULT 0")];
--
--  Never change a step once it has run anywhere: add a new one.
package Sparrow.Migrations with SPARK_Mode => Off is

   type Migration_Step is private;
   type Step_List is array (Positive range <>) of Migration_Step;

   No_Steps : constant Step_List;

   --  Steps are made once, at elaboration: the SQL is copied to the heap and kept for the program's life.
   function Step (Version : Positive; Sql : String) return Migration_Step;

   function Version (Of_Step : Migration_Step) return Positive;
   function Sql (Of_Step : Migration_Step) return String;

   --  Raises Program_Error when the versions of Steps do not increase.
   procedure Check_Order (Steps : Step_List);

private

   type Text_Access is access constant String;

   type Migration_Step is record
      Version : Positive := 1;
      Sql     : Text_Access;
   end record;

   No_Steps : constant Step_List (1 .. 0) := [others => <>];

end Sparrow.Migrations;
