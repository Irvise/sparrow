with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Http.Spans;
with Sparrow.IO.Process;
with Sparrow.Json; use Sparrow.Json;
with Sparrow.Json.Builders; use Sparrow.Json.Builders;
with Sparrow.Jwt;
with Sparrow.Sqlite; use Sparrow.Sqlite;
with Sparrow.Sqlite.Migrations;
with Sparrow.Sqlite.Per_Worker;
with Sparrow.Encoding;
with Sparrow.Times; use Sparrow.Times;

package body Bookmark_Api is

   package Requests renames Sparrow.Http.Requests;
   package Responses renames Sparrow.Http.Responses;

   Signing_Key : Sparrow.Jwt.Key;

   --  The schema, one step per change; add steps, never edit one that has run.
   Steps : constant Sparrow.Sqlite.Migrations.Step_List :=
     [Sparrow.Sqlite.Migrations.Step
        (1, "CREATE TABLE IF NOT EXISTS bookmarks ("
            & "  id      INTEGER PRIMARY KEY,"
            & "  url     TEXT NOT NULL,"
            & "  title   TEXT NOT NULL,"
            & "  note    TEXT NOT NULL DEFAULT '',"
            & "  created INTEGER NOT NULL)")];

   --  Every query returns these columns, for Write_Bookmark.
   Columns : constant String := "id, url, title, note, created";

   package Databases is new Sparrow.Sqlite.Per_Worker
     (Worker_Id, Path => Sparrow.IO.Process.Environment ("DATABASE", Default => "bookmarks.db"), Steps => Steps);

   ---------------------------------------------------------------------------------------------------------------
   --  set-up

   procedure Set_Secret (Secret : String) is begin
      Signing_Key := Sparrow.Jwt.To_Key (Secret);
   end Set_Secret;

   function Demo_Token (Subject : UTF8_String) return String is
      Now : Unix_Seconds;
   begin
      Sparrow.IO.Process.Read_Clock (Now);
      return Sparrow.Jwt.Sign_Subject (Signing_Key, Subject, Now, Lifetime => 3600);
   end Demo_Token;

   procedure Open_Connection (Worker : Worker_Id) renames Databases.Open;
   procedure Close_Connection (Worker : Worker_Id) renames Databases.Close;

   --  The database connection of the worker running Request's handler.
   function Worker_Database (Request : Http_Request) return Databases.Reference is
     (Databases.Connection (Requests.Worker (Request)));

   ---------------------------------------------------------------------------------------------------------------
   --  answers

   procedure Send_Error (Response : in out Http_Response; Status : Status_Code; Message : UTF8_String) is
      Json : Builder (Response.Content'Access);
   begin
      Responses.Begin_Content (Response, Status, Application_Json);
      Json.Begin_Object;
      Json.Member ("error", Message);
      Json.End_Object;
   end Send_Error;

   --  The current row of Row (the Columns) as a JSON object.
   procedure Write_Bookmark (Json : in out Builder; Row : Statement) is
      Created : constant Unix_Seconds := Unix_Seconds (Integer_Value (Row, "created"));
   begin
      Json.Begin_Object;
      Json.Member ("id", Integer_Value (Row, "id"));
      Json.Member ("url", Text (Row, "url"));
      Json.Member ("title", Text (Row, "title"));
      Json.Member ("note", Text (Row, "note"));
      Json.Member ("created", UTF8_String (Rfc3339 (To_Microseconds (Created))));
      Json.End_Object;
   end Write_Bookmark;

   --  Answer with the row Query found (Status), or 404 when there is none.
   procedure Send_Bookmark (Response : in out Http_Response; Query : in out Statement; Status : Status_Code := OK) is
      Json : Builder (Response.Content'Access);
   begin
      if not Next_Row (Query) then
         Send_Error (Response, Not_Found, "no such bookmark");
         return;
      end if;
      Responses.Begin_Content (Response, Status, Application_Json);
      Write_Bookmark (Json, Query);
   end Send_Bookmark;

   ---------------------------------------------------------------------------------------------------------------
   --  checks

   --  Whether the request carries a valid token; answers 401 when not.
   function Authorized
     (Request : Http_Request; Response : in out Http_Response) return Boolean
   is
      Claims : Document (Node_Capacity => 16, Text_Capacity => 1024);
      Valid  : Boolean;
   begin
      Sparrow.Jwt.Verify
        (Signing_Key, Sparrow.Jwt.Bearer_Token (Requests.Header (Request, "Authorization")), Requests.Now (Request),
         Claims, Valid);
      if not Valid then
         Responses.Set_Header (Response, "WWW-Authenticate", "Bearer");
         Send_Error (Response, Unauthorized, "a valid bearer token is required");
      end if;
      return Valid;
   end Authorized;

   --  What a bookmark's body must hold, for Create and Replace.
   Bookmark_Rules : constant Rule_List :=
     [Required ("url", Text_Shape, Shortest => 1, Longest => 2048),
      Required ("title", Text_Shape, Shortest => 1, Longest => 200),
      Optional ("note", Text_Shape, Longest => 2000)];

   --  Whether Fields (the body) will do for a bookmark; answers 415, 400 or 422 when not.
   function Acceptable (Request : Http_Request; Response : in out Http_Response; Fields : Document) return Boolean is
      Url : constant UTF8_String := Text (Fields, "url");
   begin
      if not Requests.Has_Content_Type (Request, "application/json") then
         Send_Error (Response, Unsupported_Media_Type, "send application/json");
         return False;
      elsif not Is_Valid (Fields) then
         Send_Error (Response, Bad_Request, "the body is not JSON");
         return False;
      elsif Problem (Fields, Bookmark_Rules) /= "" then
         Send_Error (Response, Unprocessable_Content, Problem (Fields, Bookmark_Rules));
         return False;
      elsif not (Url'Length > 7 and then (Url (Url'First .. Url'First + 6) = "http://"
                                          or else Url (Url'First .. Url'First + 7) = "https://"))
      then
         Send_Error (Response, Unprocessable_Content, "url: must be an http or https URL");
         return False;
      end if;
      return True;
   end Acceptable;

   --  Fields into Query's parameters 1 (url), 2 (title) and 3 (note).
   procedure Bind_Fields (Query : in out Statement; Fields : Document) is begin
      Bind (Query, 1, Text (Fields, "url"));
      Bind (Query, 2, Text (Fields, "title"));
      Bind (Query, 3, Text (Fields, "note"));   --  "" when absent
   end Bind_Fields;

   --  Text as a LIKE pattern matching it anywhere, with its own % and _ taken literally (ESCAPE '\').
   function Contains_Pattern (Text : UTF8_String) return UTF8_String is
      Result : UTF8_String (1 .. 2 * Text'Length + 2);
      Last   : Natural := 1;
   begin
      Result (1) := '%';
      for Symbol of Text loop
         if Symbol in '%' | '_' | '\' then
            Last := Last + 1;
            Result (Last) := '\';
         end if;
         Last := Last + 1;
         Result (Last) := Symbol;
      end loop;
      Last := Last + 1;
      Result (Last) := '%';
      return Result (1 .. Last);
   end Contains_Pattern;

   ---------------------------------------------------------------------------------------------------------------
   --  handlers

   procedure List (Request : Http_Request; Response : in out Http_Response) is
      Db     : Database renames Worker_Database (Request);
      Search : constant UTF8_String := Requests.Query_Text (Request, "q");
      Limit  : constant Long_Long_Integer := Long_Long_Integer'Min (200, Requests.Integer_Query (Request, "limit", 50));
      Query  : Statement;
      Json   : Builder (Response.Content'Access);
      Timed  : constant Spans.Span := Spans.Start (Request, "search bookmarks");   --  in the trace, when traced
   begin
      Prepare (Db, Query,
               "SELECT " & Columns & " FROM bookmarks"
               & " WHERE ?1 = '' OR title LIKE ?2 ESCAPE '\' OR url LIKE ?2 ESCAPE '\'"
               & " ORDER BY id DESC LIMIT ?3");
      Bind (Query, 1, Search);
      Bind (Query, 2, Contains_Pattern (Search));
      Bind (Query, 3, Long_Long_Integer'Max (1, Limit));

      Responses.Begin_Content (Response, OK, Application_Json);
      Json.Begin_Object;
      Json.Key ("bookmarks");
      Json.Begin_Array;
      while Next_Row (Query) loop
         Write_Bookmark (Json, Query);
      end loop;
      Json.End_Array;
      Json.End_Object;
   end List;

   procedure Show (Request : Http_Request; Response : in out Http_Response) is
      Db    : Database renames Worker_Database (Request);
      Query : Statement;
   begin
      Prepare (Db, Query, "SELECT " & Columns & " FROM bookmarks WHERE id = ?1");
      Bind (Query, 1, Requests.Integer_Parameter (Request, "id"));
      Send_Bookmark (Response, Query);
   end Show;

   procedure Create (Request : Http_Request; Response : in out Http_Response) is
      Db     : Database renames Worker_Database (Request);
      Fields : constant Document := Requests.Json_Body (Request);
      Insert : Statement;
   begin
      if not Authorized (Request, Response) or else not Acceptable (Request, Response, Fields) then
         return;
      end if;
      Prepare (Db, Insert,
               "INSERT INTO bookmarks (url, title, note, created) VALUES (?1, ?2, ?3, ?4) RETURNING " & Columns);
      Bind_Fields (Insert, Fields);
      Bind (Insert, 4, Long_Long_Integer (Requests.Now (Request)));
      Send_Bookmark (Response, Insert, Status => Created);
      Responses.Set_Header
        (Response, "Location", "/api/bookmarks/" & Encoding.Decimal_Image (Last_Insert_Id (Db)));
   end Create;

   procedure Replace (Request : Http_Request; Response : in out Http_Response) is
      Db     : Database renames Worker_Database (Request);
      Fields : constant Document := Requests.Json_Body (Request);
      Update : Statement;
   begin
      if not Authorized (Request, Response) or else not Acceptable (Request, Response, Fields) then
         return;
      end if;
      Prepare (Db, Update,
               "UPDATE bookmarks SET url = ?1, title = ?2, note = ?3 WHERE id = ?4 RETURNING " & Columns);
      Bind_Fields (Update, Fields);
      Bind (Update, 4, Requests.Integer_Parameter (Request, "id"));
      Send_Bookmark (Response, Update);
   end Replace;

   procedure Remove (Request : Http_Request; Response : in out Http_Response) is
      Db     : Database renames Worker_Database (Request);
      Delete : Statement;
   begin
      if not Authorized (Request, Response) then
         return;
      end if;
      Prepare (Db, Delete, "DELETE FROM bookmarks WHERE id = ?1");
      Bind (Delete, 1, Requests.Integer_Parameter (Request, "id"));
      Run (Delete);
      if Changes (Db) = 0 then
         Send_Error (Response, Not_Found, "no such bookmark");
      else
         Response.Status := No_Content;
      end if;
   end Remove;

   function Database_Ready (Request : Http_Request) return Boolean is
      Db    : Database renames Worker_Database (Request);
      Query : Statement;
   begin
      Prepare (Db, Query, "SELECT 1");
      return Next_Row (Query);
   end Database_Ready;

end Bookmark_Api;
