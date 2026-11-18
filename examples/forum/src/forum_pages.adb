with Ada.Strings.Fixed;
with Sparrow.Crypto.Passwords;
with Sparrow.Crypto.Random;
with Sparrow.Encoding;
with Sparrow.Http.Event_Streams;
with Sparrow.Http.Log;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Http.Sessions; use Sparrow.Http.Sessions;
with Sparrow.Http.Streams;
with Sparrow.IO.Process;
with Sparrow.Logs;
with Sparrow.Sqlite; use Sparrow.Sqlite;
with Sparrow.Sqlite.Migrations;
with Sparrow.Sqlite.Per_Worker;
with Sparrow.Templates;
with Sparrow.Templates.Bindings; use Sparrow.Templates.Bindings;
with Sparrow.Templates.Bindings.Add_Rows;
with Sparrow.Valkey.Sessions;

package body Forum_Pages is

   package Requests renames Sparrow.Http.Requests;
   package Responses renames Sparrow.Http.Responses;

   Views : Sparrow.Templates.Library;

   --  The schema, one step per change; add steps, never edit one that has run.
   Steps : constant Sparrow.Sqlite.Migrations.Step_List :=
     [Sparrow.Sqlite.Migrations.Step
        (1, "CREATE TABLE IF NOT EXISTS users ("
            & "  id       INTEGER PRIMARY KEY,"
            & "  name     TEXT NOT NULL UNIQUE COLLATE NOCASE,"
            & "  password TEXT NOT NULL,"
            & "  joined   INTEGER NOT NULL DEFAULT (unixepoch()));"
            & "CREATE TABLE IF NOT EXISTS threads ("
            & "  id        INTEGER PRIMARY KEY,"
            & "  title     TEXT NOT NULL,"
            & "  author    INTEGER NOT NULL REFERENCES users,"
            & "  last_post INTEGER NOT NULL DEFAULT (unixepoch()));"
            & "CREATE TABLE IF NOT EXISTS posts ("
            & "  id      INTEGER PRIMARY KEY,"
            & "  thread  INTEGER NOT NULL REFERENCES threads,"
            & "  author  INTEGER NOT NULL REFERENCES users,"
            & "  body    TEXT NOT NULL,"
            & "  written INTEGER NOT NULL DEFAULT (unixepoch()));"
            & "CREATE INDEX IF NOT EXISTS posts_by_thread ON posts (thread, id);"
            & "CREATE INDEX IF NOT EXISTS threads_by_activity ON threads (last_post DESC)")];

   package Databases is new Sparrow.Sqlite.Per_Worker
     (Worker_Id, Path => Sparrow.IO.Process.Environment ("DATABASE", Default => "forum.db"), Steps => Steps);

   --  A statement's rows as a template list, each column a name.
   procedure Add_Rows is new Sparrow.Templates.Bindings.Add_Rows (Statement);

   procedure Open_Connection (Worker : Worker_Id) renames Databases.Open;
   procedure Close_Connection (Worker : Worker_Id) renames Databases.Close;

   --  The database connection of the worker running Request's handler.
   function Worker_Database (Request : Http_Request) return Databases.Reference is
     (Databases.Connection (Requests.Worker (Request)));

   --  SESSION_SECRET (32 bytes or more) keeps people logged in across restarts; without it, a random one.
   function Session_Secret return String is
      Configured : constant String := Sparrow.IO.Process.Environment ("SESSION_SECRET", Default => "");
   begin
      if Configured'Length > 0 then
         return Configured;
      end if;
      Sparrow.Logs.Warning ("no SESSION_SECRET: everyone is logged out when the server restarts");
      return Random_Secret;
   end Session_Secret;

   --  VALKEY_URL keeps sessions in Valkey, where every forum server sees them; without it, in a sealed cookie.
   function Visitor_Store return Store is
      Shared : constant String := Sparrow.IO.Process.Environment ("VALKEY_URL", Default => "");
   begin
      if Shared'Length > 0 then
         return Table_Store
           (Sparrow.Valkey.Sessions.Table (Shared, Prefix => "forum:"), Cookie_Name => "forum_session");
      end if;
      return Cookie_Store
        (Secret          => Session_Secret,
         Cookie_Name     => "forum_session",
         Previous_Secret => Sparrow.IO.Process.Environment ("SESSION_SECRET_PREVIOUS", Default => ""));
   end Visitor_Store;

   Visitors : constant Store := Visitor_Store;

   --  Every open page, told when someone posts.
   Watchers : Sparrow.Http.Streams.Group (Capacity => 1024);

   procedure Load_Views (Directory : String) is
      Loaded, Failed : Natural;
   begin
      Sparrow.Templates.Load_Directory (Views, Directory, Loaded, Failed);
      if Failed > 0 or else Loaded = 0 then
         raise Program_Error with "templates in " & Directory & ": " & Failed'Image & " did not compile";
      end if;
   end Load_Views;

   ---------------------------------------------------------------------------------------------------------------
   --  helpers

   function Logged_In (Session : Sessions.Session) return Boolean is (Has (Session, "user_id"));

   function User_Id (Session : Sessions.Session) return Long_Long_Integer is
      Value : Long_Long_Integer;
      Valid : Boolean;
   begin
      Sparrow.Encoding.Parse_Decimal (String (Get (Session, "user_id")), Value, Valid);
      return (if Valid then Value else 0);
   end User_Id;

   function Trimmed (Text : UTF8_String) return UTF8_String is
     (UTF8_String (Ada.Strings.Fixed.Trim (String (Text), Ada.Strings.Both)));

   --  Render the page template Name over Data, with what every page shows: who is logged in, the CSRF
   --  token for its forms, and a message left by the request before (shown once). Saves the session.
   procedure Render_Page
     (Response : in out Http_Response;
      Session  : in out Sessions.Session;
      Name     : String;
      Data     : in out Binding_Set;
      Status   : Status_Code := OK)
   is
      Found : Boolean;
   begin
      Set (Data, "logged_in", Logged_In (Session));
      Set (Data, "user_name", Get (Session, "user_name"));
      Set (Data, "csrf_token", UTF8_String (Csrf_Token (Session)));
      if Has (Session, "flash") then
         Set (Data, "flash", Get (Session, "flash"));
         Remove (Session, "flash");
      end if;
      Visitors.Save (Session, Response);
      Responses.Begin_Content (Response, Status, Text_Html);
      Sparrow.Templates.Render (Views, Name, Data, Response.Content, Found);
      if not Found then
         raise Program_Error with "no template " & Name;
      end if;
   end Render_Page;

   --  Leave Message for the next page, and go there.
   procedure Redirect_With
     (Response : in out Http_Response; Session : in out Sessions.Session; Location, Message : String)
   is begin
      if Message'Length > 0 then
         Set (Session, "flash", UTF8_String (Message));
      end if;
      Visitors.Save (Session, Response);
      Responses.Redirect (Response, Location);
   end Redirect_With;

   --  For every POST: the form must carry the session's CSRF token. Answers 403 when it does not.
   function Form_Is_Ours
     (Request : Http_Request; Response : in out Http_Response; Session : Sessions.Session) return Boolean
   is begin
      if Csrf_Valid (Session, Request) then
         return True;
      end if;
      Responses.Send (Response, Forbidden, "This form has expired. Go back, reload the page and try again.");
      return False;
   end Form_Is_Ours;

   ---------------------------------------------------------------------------------------------------------------
   --  reading

   procedure Home (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
      Data    : Binding_Set;
      Threads : Statement;
   begin
      Prepare (Worker_Database (Request), Threads,
               "SELECT id, title, author, replies, nullif(replies = 1, 0) AS one_reply, active FROM"
               & " (SELECT t.id AS id, t.title AS title, u.name AS author, t.last_post AS last_post,"
               & "         (SELECT count(*) - 1 FROM posts WHERE thread = t.id) AS replies,"
               & "         strftime('%Y-%m-%d %H:%M', t.last_post, 'unixepoch') AS active"
               & "    FROM threads t JOIN users u ON u.id = t.author)"
               & " ORDER BY last_post DESC, id DESC LIMIT 100");
      Add_Rows (Data, "threads", Threads);
      Render_Page (Response, Session, "home", Data);
   end Home;

   --  The thread page, with Error (and the reply that caused it) above the reply form when given.
   procedure Thread_Page
     (Request  : Http_Request;
      Response : in out Http_Response;
      Session  : in out Sessions.Session;
      Error    : String := "";
      Draft    : UTF8_String := "")
   is
      Id     : constant Long_Long_Integer := Requests.Integer_Parameter (Request, "id");
      Data   : Binding_Set;
      Thread : Statement;
      Posts  : Statement;
      Db     : Database renames Worker_Database (Request);
   begin
      Prepare (Db, Thread, "SELECT title FROM threads WHERE id = ?1");
      Bind (Thread, 1, Id);
      if not Next_Row (Thread) then
         Responses.Send (Response, Not_Found, "There is no such thread.");
         return;
      end if;
      Set (Data, "id", Id);
      Set (Data, "title", Text (Thread, "title"));

      Prepare (Db, Posts,
               "SELECT p.id AS post_id, u.name AS author, p.body AS body,"
               & "       strftime('%Y-%m-%d %H:%M', p.written, 'unixepoch') AS written"
               & "  FROM posts p JOIN users u ON u.id = p.author WHERE p.thread = ?1 ORDER BY p.id");
      Bind (Posts, 1, Id);
      Add_Rows (Data, "posts", Posts);
      if Error'Length > 0 then
         Set (Data, "error", UTF8_String (Error));
         Set (Data, "draft", Draft);
      end if;
      Render_Page (Response, Session, "thread", Data,
                   Status => (if Error'Length > 0 then Unprocessable_Content else OK));
   end Thread_Page;

   procedure Show_Thread (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
   begin
      Thread_Page (Request, Response, Session);
   end Show_Thread;

   procedure Events (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.Http.Event_Streams.Begin_Events (Response, Retry => 5_000);
      Sparrow.Http.Streams.Add (Watchers, Requests.Connection (Request));
   end Events;

   ---------------------------------------------------------------------------------------------------------------
   --  writing

   Max_Title : constant := 120;
   Max_Body  : constant := 10_000;

   procedure New_Thread (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
      Title   : constant UTF8_String := Trimmed (Requests.Form_Text (Request, "title"));
      Text_Of : constant UTF8_String := Trimmed (Requests.Form_Text (Request, "body"));
      Db      : Database renames Worker_Database (Request);
      Insert  : Statement;
      Id      : Long_Long_Integer;
   begin
      if not Form_Is_Ours (Request, Response, Session) then
         return;
      elsif not Logged_In (Session) then
         Redirect_With (Response, Session, "/login", "Log in to start a thread.");
         return;
      elsif Title'Length not in 1 .. Max_Title or else Text_Of'Length not in 1 .. Max_Body then
         Redirect_With (Response, Session, "/", "A thread needs a title (up to 120 bytes) and a first post.");
         return;
      end if;

      Begin_Transaction (Db);
      Prepare (Db, Insert, "INSERT INTO threads (title, author) VALUES (?1, ?2)");
      Bind (Insert, 1, Title);
      Bind (Insert, 2, User_Id (Session));
      Run (Insert);
      Id := Last_Insert_Id (Db);
      Prepare (Db, Insert, "INSERT INTO posts (thread, author, body) VALUES (?1, ?2, ?3)");
      Bind (Insert, 1, Id);
      Bind (Insert, 2, User_Id (Session));
      Bind (Insert, 3, Text_Of);
      Run (Insert);
      Commit (Db);

      Sparrow.Http.Log.Info (Request, "thread started", Sparrow.Http.Log.Field ("thread", Id),
                             Sparrow.Http.Log.Field ("user", User_Id (Session)));
      Sparrow.Http.Event_Streams.Send (Watchers, UTF8_String (Sparrow.Encoding.Decimal_Image (Id)), Name => "thread");
      Redirect_With (Response, Session, "/threads/" & Sparrow.Encoding.Decimal_Image (Id), "");
   end New_Thread;

   procedure Reply (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
      Id      : constant Long_Long_Integer := Requests.Integer_Parameter (Request, "id");
      Text_Of : constant UTF8_String := Trimmed (Requests.Form_Text (Request, "body"));
      Db      : Database renames Worker_Database (Request);
      Insert  : Statement;
      Touch   : Statement;
   begin
      if not Form_Is_Ours (Request, Response, Session) then
         return;
      elsif not Logged_In (Session) then
         Redirect_With (Response, Session, "/login", "Log in to reply.");
         return;
      elsif Text_Of'Length not in 1 .. Max_Body then
         Thread_Page (Request, Response, Session, "A reply is 1 to 10,000 bytes.", Text_Of);
         return;
      end if;

      Begin_Transaction (Db);
      Prepare (Db, Touch, "UPDATE threads SET last_post = unixepoch() WHERE id = ?1");
      Bind (Touch, 1, Id);
      Run (Touch);
      if Changes (Db) = 0 then
         Rollback (Db);
         Responses.Send (Response, Not_Found, "There is no such thread.");
         return;
      end if;
      Prepare (Db, Insert, "INSERT INTO posts (thread, author, body) VALUES (?1, ?2, ?3)");
      Bind (Insert, 1, Id);
      Bind (Insert, 2, User_Id (Session));
      Bind (Insert, 3, Text_Of);
      Run (Insert);
      Commit (Db);

      Sparrow.Http.Event_Streams.Send (Watchers, UTF8_String (Sparrow.Encoding.Decimal_Image (Id)), Name => "reply");
      Redirect_With (Response, Session, "/threads/" & Sparrow.Encoding.Decimal_Image (Id)
                                        & "#post-" & Sparrow.Encoding.Decimal_Image (Last_Insert_Id (Db)), "");
   end Reply;

   ---------------------------------------------------------------------------------------------------------------
   --  accounts

   procedure Account_Page
     (Request  : Http_Request;
      Response : in out Http_Response;
      Session  : in out Sessions.Session;
      Name     : String;
      Error    : String := "")
   is
      Data : Binding_Set;
   begin
      Set (Data, "name", Requests.Form_Text (Request, "name"));
      if Error'Length > 0 then
         Set (Data, "error", UTF8_String (Error));
      end if;
      Render_Page (Response, Session, Name, Data,
                   Status => (if Error'Length > 0 then Unprocessable_Content else OK));
   end Account_Page;

   procedure Register_Form (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
   begin
      Account_Page (Request, Response, Session, "register");
   end Register_Form;

   procedure Login_Form (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
   begin
      Account_Page (Request, Response, Session, "login");
   end Login_Form;

   --  The user is Id, called Name, from now on.
   procedure Log_In (Session : in out Sessions.Session; Id : Long_Long_Integer; Name : UTF8_String) is begin
      Set (Session, "user_id", UTF8_String (Sparrow.Encoding.Decimal_Image (Id)));
      Set (Session, "user_name", Name);
      Renew (Session);   --  a token seen before logging in is no good after
   end Log_In;

   function Valid_Name (Name : UTF8_String) return Boolean is
     (Name'Length in 3 .. 24
      and then (for all Symbol of Name => Symbol in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-'));

   function New_Hash (Password : String) return String is
      Salt : Sparrow.Crypto.Passwords.Salt_Bytes;
   begin
      Sparrow.Crypto.Random.Fill (Salt);
      return Sparrow.Crypto.Passwords.Hash (Password, Salt);
   end New_Hash;

   procedure Register (Request : Http_Request; Response : in out Http_Response) is
      Session  : Sessions.Session := Visitors.Load (Request);
      Name     : constant UTF8_String := Trimmed (Requests.Form_Text (Request, "name"));
      Password : constant String := Requests.Form_Value (Request, "password");
      Db       : Database renames Worker_Database (Request);
      Insert   : Statement;
   begin
      if not Form_Is_Ours (Request, Response, Session) then
         return;
      elsif not Valid_Name (Name) then
         Account_Page (Request, Response, Session, "register",
                       "A name is 3 to 24 letters, digits, dashes or underscores.");
         return;
      elsif Password'Length not in 8 .. 200 then
         Account_Page (Request, Response, Session, "register", "A password is 8 to 200 characters.");
         return;
      end if;

      Prepare (Db, Insert, "INSERT INTO users (name, password) VALUES (?1, ?2)");
      Bind (Insert, 1, Name);
      Bind (Insert, 2, UTF8_String (New_Hash (Password)));
      begin
         Run (Insert);
      exception
         when Constraint_Violation =>
            Account_Page (Request, Response, Session, "register", "That name is taken.");
            return;
      end;
      Log_In (Session, Last_Insert_Id (Db), Name);
      Sparrow.Http.Log.Info (Request, "user registered", Sparrow.Http.Log.Field ("user", Last_Insert_Id (Db)),
                             Sparrow.Http.Log.Field ("name", String (Name)));
      Redirect_With (Response, Session, "/", "Welcome, " & String (Name) & ".");
   end Register;

   --  Checked against when the name is unknown, so a wrong name takes as long as a wrong password.
   Decoy_Hash : constant String := New_Hash ("not anyone's password");

   procedure Login (Request : Http_Request; Response : in out Http_Response) is
      Session  : Sessions.Session := Visitors.Load (Request);
      Password : constant String := Requests.Form_Value (Request, "password");
      Find     : Statement;
   begin
      if not Form_Is_Ours (Request, Response, Session) then
         return;
      end if;
      Prepare (Worker_Database (Request), Find,
               "SELECT id, name, password FROM users WHERE name = ?1");
      Bind (Find, 1, Trimmed (Requests.Form_Text (Request, "name")));
      if Password'Length <= 200 and then Next_Row (Find) then
         if Sparrow.Crypto.Passwords.Verify (Password, String (Text (Find, "password"))) then
            Log_In (Session, Integer_Value (Find, "id"), Text (Find, "name"));
            Sparrow.Http.Log.Info (Request, "logged in", Sparrow.Http.Log.Field ("user", Integer_Value (Find, "id")));
            Redirect_With (Response, Session, "/", "Welcome back, " & String (Text (Find, "name")) & ".");
            return;
         end if;
      elsif Sparrow.Crypto.Passwords.Verify ("", Decoy_Hash) then
         null;   --  never: only the time it takes matters
      end if;
      --  Worth watching: many of these from one client is someone guessing passwords.
      Sparrow.Http.Log.Warning (Request, "login failed",
                                Sparrow.Http.Log.Field ("name", Requests.Form_Value (Request, "name")));
      Account_Page (Request, Response, Session, "login", "That name and password do not match.");
   end Login;

   procedure Logout (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
   begin
      if Form_Is_Ours (Request, Response, Session) then
         Clear (Session);
         Redirect_With (Response, Session, "/", "You are logged out.");
      end if;
   end Logout;

end Forum_Pages;
