with Sparrow; use Sparrow;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Sparrow.Client;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.IO.Process;
with Sparrow.Json; use Sparrow.Json;
with Sparrow.Json.Builders; use Sparrow.Json.Builders;
with Sparrow.Jwt;
with Sparrow.Jwt.Key_Sets; use Sparrow.Jwt.Key_Sets;
with Sparrow.Logs;
with Sparrow.Postgres; use Sparrow.Postgres;
with Sparrow.Postgres.Migrations;
with Sparrow.Postgres.Queries; use Sparrow.Postgres.Queries;
with Sparrow.Times; use Sparrow.Times;

package body Note_Routes is

   package Requests renames Sparrow.Http.Requests;
   package Responses renames Sparrow.Http.Responses;

   Issuer_Url   : Unbounded_String;
   Database_Url : Unbounded_String;

   ---------------------------------------------------------------------------------------------------------------
   --  the issuer's keys

   --  The keys, shared by every worker, and when they were last fetched.
   protected Trusted is
      procedure Replace (Keys : Key_Set; Now : Unix_Seconds);
      procedure Mark (Now : Unix_Seconds);
      function Keys return Key_Set;
      function Fetched return Unix_Seconds;
   private
      Current : Key_Set := Empty_Set;
      When_At : Unix_Seconds := 0;
   end Trusted;

   protected body Trusted is
      procedure Replace (Keys : Key_Set; Now : Unix_Seconds) is begin
         Current := Keys;
         When_At := Now;
      end Replace;
      procedure Mark (Now : Unix_Seconds) is begin
         When_At := Now;
      end Mark;
      function Keys return Key_Set is (Current);
      function Fetched return Unix_Seconds is (When_At);
   end Trusted;

   --  Fetch the issuer's JWKS with sparrow_client. A failure keeps the keys there were.
   procedure Fetch_Keys (Now : Unix_Seconds) is
      Url    : constant String := To_String (Issuer_Url) & "/.well-known/jwks.json";
      Answer : Sparrow.Client.Response;
   begin
      Trusted.Mark (Now);   --  counts as a fetch even when it fails
      Sparrow.Client.Get (Url, Answer, Headers => "Accept: application/json");
      if Sparrow.Client.Status (Answer) /= 200 then
         Sparrow.Logs.Warning ("the issuer's keys were refused", Sparrow.Logs.Field ("url", Url),
                               Sparrow.Logs.Field ("status", Long_Long_Integer (Sparrow.Client.Status (Answer))));
         return;
      end if;
      declare
         Keys : constant Key_Set := Parse_Jwks (Sparrow.Client.Content (Answer));
      begin
         if Count (Keys) = 0 then
            Sparrow.Logs.Warning ("the issuer's JWKS has no signing key", Sparrow.Logs.Field ("url", Url));
         else
            Trusted.Replace (Keys, Now);
            Sparrow.Logs.Info ("issuer keys fetched", Sparrow.Logs.Field ("url", Url),
                               Sparrow.Logs.Field ("keys", Long_Long_Integer (Count (Keys))));
         end if;
      end;
   exception
      when Problem : Sparrow.Client.Request_Error =>
         Sparrow.Logs.Warning ("the issuer cannot be reached", Sparrow.Logs.Field ("url", Url),
                               Sparrow.Logs.Field ("problem", Ada.Exceptions.Exception_Message (Problem)));
   end Fetch_Keys;

   ---------------------------------------------------------------------------------------------------------------
   --  the database

   Steps : constant Migrations.Step_List :=
     [Migrations.Step
        (1, "CREATE TABLE notes ("
            & "  id      bigserial PRIMARY KEY,"
            & "  owner   text NOT NULL,"
            & "  body    text NOT NULL,"
            & "  created timestamptz NOT NULL DEFAULT now());"
            & "CREATE INDEX notes_by_owner ON notes (owner, id)")];

   --  Every query returns these columns, for Write_Note.
   Columns : constant String := "id, body, extract(epoch FROM created)::bigint AS created";

   List_Notes  : aliased constant Statement :=
     Define ("list_notes", "SELECT " & Columns & " FROM notes WHERE owner = $1 ORDER BY id DESC LIMIT 100");
   Find_Note   : aliased constant Statement :=
     Define ("find_note", "SELECT " & Columns & " FROM notes WHERE owner = $1 AND id = $2");
   Add_Note    : aliased constant Statement :=
     Define ("add_note", "INSERT INTO notes (owner, body) VALUES ($1, $2) RETURNING " & Columns);
   Delete_Note : aliased constant Statement :=
     Define ("delete_note", "DELETE FROM notes WHERE owner = $1 AND id = $2");

   type Connection_Access is access Connection;
   procedure Free is new Ada.Unchecked_Deallocation (Connection, Connection_Access);

   Connections : array (Worker_Id) of Connection_Access;   --  each written only by its own worker

   procedure Open_Connection (Worker : Worker_Id) is begin
      Connections (Worker) := new Connection;
      Connect (Connections (Worker).all, To_String (Database_Url));
      Prepare (Connections (Worker).all, Statement_List'[List_Notes'Access, Find_Note'Access, Add_Note'Access,
                                                          Delete_Note'Access]);
   end Open_Connection;

   procedure Close_Connection (Worker : Worker_Id) is begin
      if Connections (Worker) /= null then
         Disconnect (Connections (Worker).all);
         Free (Connections (Worker));
      end if;
   end Close_Connection;

   --  The connection of the worker running Request, opened again if the last one failed.
   function Database (Request : Http_Request) return Connection_Access is
      Worker : constant Worker_Id := Requests.Worker (Request);
   begin
      if Connections (Worker) = null or else not Is_Connected (Connections (Worker).all) then
         Close_Connection (Worker);
         Open_Connection (Worker);
      end if;
      return Connections (Worker);
   end Database;

   function Database_Ready (Request : Http_Request) return Boolean is
     (Requests.Worker (Request) in Worker_Id
      and then Connections (Requests.Worker (Request)) /= null
      and then Is_Connected (Connections (Requests.Worker (Request)).all));

   procedure Start (Issuer, Database : String) is
      Setup : Connection;
      Now   : Unix_Seconds;
   begin
      Issuer_Url   := To_Unbounded_String (Issuer);
      Database_Url := To_Unbounded_String (Database);
      Connect (Setup, Database);
      Migrations.Apply (Setup, Steps);
      Disconnect (Setup);
      Sparrow.IO.Process.Read_Clock (Now);
      Fetch_Keys (Now);
   end Start;

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

   procedure Write_Note (Json : in out Builder; Row : Queries.Row) is
   begin
      Json.Begin_Object;
      Json.Member ("id", Row.Integer_Value ("id"));
      Json.Member ("text", Row.Text ("body"));
      Json.Member ("created", UTF8_String (Rfc3339 (To_Microseconds (Unix_Seconds (Row.Integer_Value ("created"))))));
      Json.End_Object;
   end Write_Note;

   --  Answer with the one row Result holds (Status), or 404.
   procedure Send_Note
     (Response : in out Http_Response; Db : Connection_Access; Result : Statement_Result; Status : Status_Code := OK)
   is
      Json  : Builder (Response.Content'Access);
      Found : Boolean := False;
   begin
      for Row in Rows (Db.all, Result) loop
         Responses.Begin_Content (Response, Status, Application_Json);
         Write_Note (Json, Row);
         Found := True;
      end loop;
      if not Found then
         Send_Error (Response, Not_Found, "no such note");
      end if;
   end Send_Note;

   ---------------------------------------------------------------------------------------------------------------
   --  who is calling

   --  The least time between two fetches of the keys, so that tokens naming unknown keys cannot flood the issuer.
   Refetch_After : constant Unix_Seconds := 10;

   --  The token's user, or "" after answering 401.
   function Caller (Request : Http_Request; Response : in out Http_Response) return String is
      Token  : constant String := Sparrow.Jwt.Bearer_Token (Requests.Header (Request, "Authorization"));
      Now    : constant Unix_Seconds := Requests.Now (Request);
      Claims : Document (Node_Capacity => 32, Text_Capacity => 2048);
      Valid  : Boolean := False;
   begin
      if Token'Length in 1 .. Max_Signed_Token_Length then
         --  A key this server has not seen: the issuer may have rotated its keys since they were fetched.
         if not Has_Key (Trusted.Keys, Key_Id_Of (Token)) and then Now - Trusted.Fetched >= Refetch_After then
            Fetch_Keys (Now);
         end if;
         Verify (Trusted.Keys, Token, Now, Claims, Valid);
      end if;
      if Valid and then String (Text (Claims, "iss")) = To_String (Issuer_Url)
        and then Text (Claims, "aud") = "notes" and then Text (Claims, "sub")'Length in 1 .. 64
      then
         return String (Text (Claims, "sub"));
      end if;
      Responses.Set_Header (Response, "WWW-Authenticate", "Bearer");
      Send_Error (Response, Unauthorized, "a valid bearer token from the issuer is required");
      return "";
   end Caller;

   ---------------------------------------------------------------------------------------------------------------
   --  routes

   procedure List (Request : Http_Request; Response : in out Http_Response) is
      User : constant String := Caller (Request, Response);
   begin
      if User = "" then
         return;
      end if;
      declare
         Db     : constant Connection_Access := Database (Request);
         Result : Statement_Result;
         Json   : Builder (Response.Content'Access);
      begin
         Query (Db.all, List_Notes, [+UTF8_String (User)], Result);
         Responses.Begin_Content (Response, OK, Application_Json);
         Json.Begin_Array;
         for Row in Rows (Db.all, Result) loop
            Write_Note (Json, Row);
         end loop;
         Json.End_Array;
      end;
   end List;

   Note_Rules : constant Rule_List := [Required ("text", Text_Shape, Shortest => 1, Longest => 10_000)];

   procedure Create (Request : Http_Request; Response : in out Http_Response) is
      User : constant String := Caller (Request, Response);
   begin
      if User = "" then
         return;
      end if;
      declare
         Fields : constant Document := Requests.Json_Body (Request);
         Db     : Connection_Access;
         Result : Statement_Result;
      begin
         if not Is_Valid (Fields) or else Problem (Fields, Note_Rules) /= "" then
            Send_Error (Response, Unprocessable_Content,
                        (if Is_Valid (Fields) then Problem (Fields, Note_Rules) else "the body is not JSON"));
            return;
         end if;
         Db := Database (Request);
         Query (Db.all, Add_Note, [+UTF8_String (User), +Text (Fields, "text")], Result);
         Send_Note (Response, Db, Result, Created);
      end;
   end Create;

   procedure Show (Request : Http_Request; Response : in out Http_Response) is
      User : constant String := Caller (Request, Response);
   begin
      if User = "" then
         return;
      end if;
      declare
         Db     : constant Connection_Access := Database (Request);
         Result : Statement_Result;
      begin
         Query (Db.all, Find_Note, [+UTF8_String (User), +Requests.Integer_Parameter (Request, "id")], Result);
         Send_Note (Response, Db, Result);
      end;
   end Show;

   procedure Remove (Request : Http_Request; Response : in out Http_Response) is
      User : constant String := Caller (Request, Response);
   begin
      if User = "" then
         return;
      end if;
      declare
         Db     : constant Connection_Access := Database (Request);
         Result : Statement_Result;
      begin
         Query (Db.all, Delete_Note, [+UTF8_String (User), +Requests.Integer_Parameter (Request, "id")], Result);
         if Result.Affected_Rows = 0 then
            Send_Error (Response, Not_Found, "no such note");
         else
            Response.Status := No_Content;
         end if;
      end;
   end Remove;

end Note_Routes;
