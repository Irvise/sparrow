--  One Database per worker task, all on the same file: what a server's handlers need, since a connection
--  belongs to one task. Instantiate at library level, give the server Open and Close as its worker hooks,
--  and in a handler use the worker's own:
--
--     package Databases is new Sparrow.Sqlite.Per_Worker (Worker_Id, "app.db", Steps => Migration_Steps);
--     ...
--     Servers.Run (Config, Routes, Hooks => (Databases.Open'Access, Databases.Close'Access));
--     ...
--     Db : Sqlite.Database renames Databases.Connection (Requests.Worker (Request));
with Sparrow.Sqlite.Migrations;

generic
   type Worker_Index is range <>;                --  Sparrow.Http.Worker_Id
   Path     : String;
   Settings : Options := Default_Options;
   Schema   : String := "";                      --  run by every Open (one at a time): use IF NOT EXISTS
   Steps    : Migrations.Step_List := Migrations.No_Steps;   --  applied by the first Open (see Migrations)
package Sparrow.Sqlite.Per_Worker is

   procedure Open (Worker : Worker_Index);
   procedure Close (Worker : Worker_Index);

   type Reference (Element : not null access Database) is limited null record
      with Implicit_Dereference => Element;

   --  The worker's own connection.
   function Connection (Worker : Worker_Index) return Reference;

end Sparrow.Sqlite.Per_Worker;
