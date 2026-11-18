with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Requests; use Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Json.Builders;
with Sparrow.Sqlite; use Sparrow.Sqlite;
with Sparrow.Sqlite.Migrations;
with Sparrow.Sqlite.Per_Worker;

package body Todo_Store is

   --  One step per change. Add steps; never edit one that has run.
   Steps : constant Migrations.Step_List :=
     [Migrations.Step
        (1, "CREATE TABLE todos (id INTEGER PRIMARY KEY, title TEXT)"),
      Migrations.Step
        (2, "ALTER TABLE todos ADD COLUMN done INTEGER NOT NULL DEFAULT 0")];

   package Databases is new Sparrow.Sqlite.Per_Worker
     (Worker_Id, Path => "todos.db", Steps => Steps);

   function Hooks return Sparrow.Http.Servers.Worker_Hooks is
     (On_Start => Databases.Open'Access, On_Stop => Databases.Close'Access);

   --  GET /todos  ->  [{"id":1,"title":"Write Ada","done":false}]
   procedure List
     (Request : Http_Request; Response : in out Http_Response)
   is
      Db    : Database renames Databases.Connection (Worker (Request));
      Find  : Statement;
      Reply : Sparrow.Json.Builders.Builder (Response.Content'Access);
   begin
      Prepare (Db, Find, "SELECT id, title, done FROM todos");
      Responses.Begin_Content (Response, OK, Application_Json);
      Reply.Begin_Array;
      for Row in Rows (Find) loop
         Reply.Begin_Object;
         Reply.Member ("id", Row.Integer_Value ("id"));
         Reply.Member ("title", Row.Text ("title"));
         Reply.Member ("done", Row.Integer_Value ("done") /= 0);
         Reply.End_Object;
      end loop;
      Reply.End_Array;
   end List;

   --  POST /todos with a form field "title"
   procedure Add_Todo
     (Request : Http_Request; Response : in out Http_Response)
   is
      Db     : Database renames Databases.Connection (Worker (Request));
      Insert : Statement;
   begin
      Prepare (Db, Insert, "INSERT INTO todos (title) VALUES (?1)");
      Bind (Insert, 1, Form_Text (Request, "title"));
      Run (Insert);
      Responses.Redirect (Response, "/todos");
   end Add_Todo;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Get, "/todos", List'Access);
      Add (Routes, Post, "/todos", Add_Todo'Access);
   end Register;

end Todo_Store;
