with Ada.Strings.Fixed;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.IO.Process;
with Sparrow.Sqlite; use Sparrow.Sqlite;
with Sparrow.Sqlite.Migrations;
with Sparrow.Sqlite.Per_Worker;
with Sparrow.Templates;
with Sparrow.Templates.Bindings; use Sparrow.Templates.Bindings;
with Sparrow.Templates.Bindings.Add_Rows;

package body Todo_Pages is

   package Requests renames Sparrow.Http.Requests;
   package Responses renames Sparrow.Http.Responses;

   Views : Sparrow.Templates.Library;

   --  The schema, one step per change; add steps, never edit one that has run.
   Steps : constant Sparrow.Sqlite.Migrations.Step_List :=
     [Sparrow.Sqlite.Migrations.Step
        (1, "CREATE TABLE IF NOT EXISTS todos ("
            & "  id    INTEGER PRIMARY KEY,"
            & "  title TEXT NOT NULL,"
            & "  done  INTEGER NOT NULL DEFAULT 0)")];

   package Databases is new Sparrow.Sqlite.Per_Worker
     (Worker_Id, Path => Sparrow.IO.Process.Environment ("DATABASE", Default => "todos.db"), Steps => Steps);

   --  A statement's rows as a template list, each column a name.
   procedure Add_Rows is new Sparrow.Templates.Bindings.Add_Rows (Statement);

   procedure Open_Connection (Worker : Worker_Id) renames Databases.Open;
   procedure Close_Connection (Worker : Worker_Id) renames Databases.Close;

   --  The database connection of the worker running Request's handler.
   function Worker_Database (Request : Http_Request) return Databases.Reference is
     (Databases.Connection (Requests.Worker (Request)));

   procedure Load_Views (Directory : String) is
      Loaded, Failed : Natural;
   begin
      Sparrow.Templates.Load_Directory (Views, Directory, Loaded, Failed);
      if Failed > 0 or else Loaded = 0 then
         raise Program_Error with "templates in " & Directory & ": " & Failed'Image & " did not compile";
      end if;
   end Load_Views;

   ---------------------------------------------------------------------------------------------------------------
   --  rendering

   type Filter is (All_Todos, Active, Finished);

   function Filter_Of (Request : Http_Request) return Filter is
      --  In the query for GET and DELETE (htmx puts DELETE values there), the form for the rest.
      Name : constant String :=
        (if Requests.Has_Query_Value (Request, "filter") then Requests.Query_Value (Request, "filter")
         else Requests.Form_Value (Request, "filter"));
   begin
      return (if Name = "active" then Active elsif Name = "done" then Finished else All_Todos);
   end Filter_Of;

   --  Everything the templates show: the todos Shown lets through, the counts, and the filter.
   procedure Bind_Todos (Data : in out Binding_Set; Db : in out Database; Shown : Filter) is
      Todos  : Statement;
      Counts : Statement;
   begin
      Prepare (Db, Todos, "SELECT id, title, nullif(done, 0) AS done FROM todos"   --  done: a flag, so NULL when 0
                          & " WHERE ?1 IS NULL OR done = ?1 ORDER BY id");
      case Shown is
         when All_Todos => Bind_Null (Todos, 1);
         when Active    => Bind (Todos, 1, False);
         when Finished  => Bind (Todos, 1, True);
      end case;
      Add_Rows (Data, "todos", Todos);

      Prepare (Db, Counts, "SELECT count(*) FILTER (WHERE NOT done) AS left,"
                           & " count(*) FILTER (WHERE done) AS finished FROM todos");
      if Next_Row (Counts) then
         Set (Data, "left", Integer_Value (Counts, "left"));
         Set (Data, "finished", Integer_Value (Counts, "finished") > 0);
      end if;

      Set (Data, "filter", (case Shown is when All_Todos => "all", when Active => "active", when Finished => "done"));
      Set (Data, "filter_all", Shown = All_Todos);
      Set (Data, "filter_active", Shown = Active);
      Set (Data, "filter_done", Shown = Finished);
   end Bind_Todos;

   --  Append the template Name, rendered over Data, to the response.
   procedure Render (Response : in out Http_Response; Name : String; Data : Binding_Set) is
      Found : Boolean;
   begin
      Sparrow.Templates.Render (Views, Name, Data, Response.Content, Found);
      if not Found then
         raise Program_Error with "no template " & Name;
      end if;
   end Render;

   --  The answer to every change: the list, and the footer to swap out of band.
   procedure Send_List (Request : Http_Request; Response : in out Http_Response) is
      Data : Binding_Set;
   begin
      Bind_Todos (Data, Worker_Database (Request), Filter_Of (Request));
      Set (Data, "oob", True);
      Responses.Begin_Content (Response, OK, Text_Html);
      Render (Response, "list", Data);
      Render (Response, "footer", Data);
   end Send_List;

   --  Whether the request came from this app's own pages (see the spec); answers 403 when not.
   function From_Our_Page (Request : Http_Request; Response : in out Http_Response) return Boolean is
      Ours : constant Boolean := Requests.Header (Request, "X-Requested-With") = "htmx";
   begin
      if not Ours then
         Responses.Fail (Response, Forbidden);
      end if;
      return Ours;
   end From_Our_Page;

   --  Run Sql with the request's :id as parameter 1, then answer with the list.
   procedure Change_One
     (Request : Http_Request; Response : in out Http_Response; Sql : String)
   is
      Change : Statement;
   begin
      if From_Our_Page (Request, Response) then
         Prepare (Worker_Database (Request), Change, Sql);
         Bind (Change, 1, Requests.Integer_Parameter (Request, "id"));
         Run (Change);
         Send_List (Request, Response);
      end if;
   end Change_One;

   ---------------------------------------------------------------------------------------------------------------
   --  handlers

   procedure Home (Request : Http_Request; Response : in out Http_Response) is
      Data : Binding_Set;
   begin
      Bind_Todos (Data, Worker_Database (Request), Filter_Of (Request));
      Responses.Begin_Content (Response, OK, Text_Html);
      Render (Response, "page", Data);
   end Home;

   procedure List (Request : Http_Request; Response : in out Http_Response)
      renames Send_List;

   procedure Add (Request : Http_Request; Response : in out Http_Response) is
      Title  : constant UTF8_String :=
        UTF8_String (Ada.Strings.Fixed.Trim (String (Requests.Form_Text (Request, "title")), Ada.Strings.Both));
      Insert : Statement;
   begin
      if not From_Our_Page (Request, Response) then
         return;
      elsif Title'Length not in 1 .. 200 then
         Responses.Send (Response, Unprocessable_Content, "A title is 1 to 200 bytes of text.");
         return;
      end if;
      Prepare (Worker_Database (Request), Insert, "INSERT INTO todos (title) VALUES (?1)");
      Bind (Insert, 1, Title);
      Run (Insert);
      Send_List (Request, Response);
   end Add;

   procedure Toggle (Request : Http_Request; Response : in out Http_Response) is begin
      Change_One (Request, Response, "UPDATE todos SET done = NOT done WHERE id = ?1");
   end Toggle;

   procedure Remove (Request : Http_Request; Response : in out Http_Response) is begin
      Change_One (Request, Response, "DELETE FROM todos WHERE id = ?1");
   end Remove;

   procedure Clear_Done (Request : Http_Request; Response : in out Http_Response) is
      Clear : Statement;
   begin
      if From_Our_Page (Request, Response) then
         Prepare (Worker_Database (Request), Clear, "DELETE FROM todos WHERE done");
         Run (Clear);
         Send_List (Request, Response);
      end if;
   end Clear_Done;

end Todo_Pages;
