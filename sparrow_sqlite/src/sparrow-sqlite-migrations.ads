--  Applies Sparrow.Migrations steps to a SQLite database, recording each version in a schema_migrations table.
--
--     Migrations.Apply (Db, Steps);   --  at start-up; Per_Worker does it for you when given Steps
--
--  Apply runs every pending step in one BEGIN IMMEDIATE transaction, so programs starting together apply each
--  step once and a failing step leaves the database as it was. A step's SQL may hold several statements but
--  not its own BEGIN or COMMIT. A database already past the last step (a newer program has run) is left alone.
with Sparrow.Migrations;

package Sparrow.Sqlite.Migrations is

   subtype Migration_Step is Sparrow.Migrations.Migration_Step;
   subtype Step_List is Sparrow.Migrations.Step_List;

   No_Steps : Step_List renames Sparrow.Migrations.No_Steps;

   function Step (Version : Positive; Sql : String) return Migration_Step renames Sparrow.Migrations.Step;

   --  Bring This up to the last step. Raises Program_Error when versions do not increase, and Database_Error
   --  naming the step when one fails (nothing of the run is then kept).
   procedure Apply (This : in out Database; Steps : Step_List);

   --  The last version applied; 0 for a database never migrated.
   function Version (This : in out Database) return Natural;

end Sparrow.Sqlite.Migrations;
