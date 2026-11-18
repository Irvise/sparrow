with Ada.Text_IO;
with Sparrow; use Sparrow;
with Sparrow.Migrations;
with Sparrow.Postgres.Migrations;
with Sparrow.Postgres.Queries; use Sparrow.Postgres.Queries;

package body User_Queries is

   Steps : constant Sparrow.Migrations.Step_List :=
     [Sparrow.Migrations.Step
        (1, "CREATE TABLE users (id bigserial PRIMARY KEY,"
            & " email text UNIQUE, name text)")];

   Find_User : aliased constant Statement :=
     Define ("find_user", "SELECT id, name FROM users WHERE email = $1");

   --  Url: "postgresql://app@localhost/app"; add "?sslmode=verify-full"
   --  for a server on another machine.
   procedure Open (Db : in out Connection; Url : String) is
   begin
      Connect (Db, Url);
      Postgres.Migrations.Apply (Db, Steps);
      Prepare (Db, Find_User);   --  once per connection
   end Open;

   procedure Print_User (Db : in out Connection; Email : String) is
      Result : Statement_Result;
   begin
      Query (Db, Find_User, [+UTF8_String (Email)], Result);
      for Row in Rows (Db, Result) loop
         Ada.Text_IO.Put_Line
           (Row.Integer_Value ("id")'Image & " " & String (Row.Text ("name")));
      end loop;
   end Print_User;

end User_Queries;
