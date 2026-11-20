with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.Strings.Fixed;
with Forum_BBCode;
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
            & "CREATE INDEX IF NOT EXISTS threads_by_activity ON threads (last_post DESC)"),
      Sparrow.Sqlite.Migrations.Step
        (2, "CREATE TABLE categories ("
            & "  id       INTEGER PRIMARY KEY,"
            & "  name     TEXT NOT NULL,"
            & "  position INTEGER NOT NULL);"
            & "CREATE TABLE boards ("
            & "  id          INTEGER PRIMARY KEY,"
            & "  category    INTEGER NOT NULL REFERENCES categories,"
            & "  name        TEXT NOT NULL,"
            & "  description TEXT NOT NULL,"
            & "  position    INTEGER NOT NULL);"
            & "INSERT INTO categories VALUES (1, 'The forum', 1), (2, 'Community', 2);"
            & "INSERT INTO boards VALUES"
            & "  (1, 1, 'Announcements', 'News about this forum and the server it runs on.', 1),"
            & "  (2, 1, 'Help and support', 'Stuck? Ask here.', 2),"
            & "  (3, 2, 'General discussion', 'Anything that fits nowhere else.', 1),"
            & "  (4, 2, 'Show and tell', 'Things you have built.', 2);"
            & "ALTER TABLE threads ADD COLUMN board INTEGER NOT NULL DEFAULT 3;"
            & "ALTER TABLE threads ADD COLUMN views INTEGER NOT NULL DEFAULT 0;"
            & "CREATE INDEX threads_by_board ON threads (board, last_post DESC);"
            & "CREATE INDEX posts_by_author ON posts (author)")];

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

   function Style_Folder return String is (Sparrow.IO.Process.Environment ("FORUM_STYLE", "forum/styles/classic"));

   Style_Sheet : constant String := "/style/" & Ada.Directories.Simple_Name (Style_Folder) & ".css";

   ---------------------------------------------------------------------------------------------------------------
   --  helpers

   Topics_Per_Page : constant := 25;
   Posts_Per_Page  : constant := 15;

   --  A member's title, from the number of posts they have written (the SQL expression Posts).
   function Rank_Of (Posts : String) return String is
     ("CASE WHEN " & Posts & " < 5 THEN 'New member' WHEN " & Posts & " < 25 THEN 'Member' WHEN "
      & Posts & " < 100 THEN 'Regular' ELSE 'Veteran' END");

   --  The page of a thread that holds its post number Position (the first post is 1), as SQL.
   function Page_Holding (Position : String) return String is
     ("((" & Position & ") - 1) /" & Posts_Per_Page'Image & " + 1");

   function Image (Value : Long_Long_Integer) return String renames Sparrow.Encoding.Decimal_Image;

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

   --  The number in the query's Name, or 0.
   function Query_Number (Request : Http_Request; Name : String) return Long_Long_Integer is
      Value : Long_Long_Integer;
      Valid : Boolean;
   begin
      Sparrow.Encoding.Parse_Decimal (Requests.Query_Value (Request, Name), Value, Valid);
      return (if Valid then Value else 0);
   end Query_Number;

   --  The one number Sql (with ?1 bound to Id) answers.
   function Count_Of (Db : in out Database; Sql : String; Id : Long_Long_Integer) return Natural is
      Query : Statement;
   begin
      Prepare (Db, Query, Sql);
      Bind (Query, 1, Id);
      return (if Next_Row (Query) then Natural (Integer_Value (Query, 1)) else 0);
   end Count_Of;

   --  The page the request asks for among Items shown Per_Page at a time, kept within those there are; binds
   --  the page links ("pages": number, current) and whether there is more than one ("paged").
   function Paged
     (Request : Http_Request; Data : in out Binding_Set; Items : Natural; Per_Page : Positive) return Positive
   is
      Last    : constant Positive := Natural'Max (1, (Items + Per_Page - 1) / Per_Page);
      Current : constant Positive := Positive (Long_Long_Integer'Max (1, Long_Long_Integer'Min
                                                 (Long_Long_Integer (Last), Query_Number (Request, "page"))));
   begin
      Set (Data, "page", Long_Long_Integer (Current));
      Set (Data, "paged", Last > 1);
      for Number in 1 .. Last loop
         declare
            Item : constant Sparrow.Templates.Scope := Add_Item (Data, "pages");
         begin
            Set (Data, "number", Long_Long_Integer (Number), Within => Item);
            Set (Data, "current", Number = Current, Within => Item);
         end;
      end loop;
      return Current;
   end Paged;

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
      Set (Data, "style_sheet", UTF8_String (Style_Sheet));
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
      Session    : Sessions.Session := Visitors.Load (Request);
      Data       : Binding_Set;
      Db         : Database renames Worker_Database (Request);
      Categories : Statement;
      Boards     : Statement;
      Totals     : Statement;
   begin
      Prepare (Db, Categories, "SELECT id, name FROM categories ORDER BY position");
      Prepare (Db, Boards,
               "SELECT b.id AS id, b.name AS name, b.description AS description,"
               & "       (SELECT count(*) FROM threads WHERE board = b.id) AS topics,"
               & "       (SELECT count(*) FROM posts p JOIN threads t ON t.id = p.thread"
               & "         WHERE t.board = b.id) AS posts,"
               & "       strftime('%Y-%m-%d %H:%M', last.written, 'unixepoch') AS last_time,"
               & "       who.name AS last_author, last.thread AS last_thread, last.id AS last_post,"
               & "       (SELECT " & Page_Holding ("count(*)") & " FROM posts WHERE thread = last.thread) AS last_page"
               & "  FROM boards b"
               & "  LEFT JOIN posts last ON last.id ="
               & "       (SELECT max(p.id) FROM posts p JOIN threads t ON t.id = p.thread WHERE t.board = b.id)"
               & "  LEFT JOIN users who ON who.id = last.author"
               & " WHERE b.category = ?1 ORDER BY b.position");
      while Next_Row (Categories) loop
         declare
            Category : constant Sparrow.Templates.Scope := Add_Item (Data, "categories");
         begin
            Set (Data, "name", Text (Categories, "name"), Within => Category);
            Reset (Boards);
            Bind (Boards, 1, Integer_Value (Categories, "id"));
            Add_Rows (Data, "boards", Boards, Within => Category);
         end;
      end loop;

      Prepare (Db, Totals,
               "SELECT (SELECT count(*) FROM posts) AS posts, (SELECT count(*) FROM threads) AS topics,"
               & "       (SELECT count(*) FROM users) AS members,"
               & "       (SELECT name FROM users ORDER BY id DESC LIMIT 1) AS newest");
      Add_Rows (Data, "totals", Totals);
      Render_Page (Response, Session, "index", Data);
   end Home;

   procedure Show_Board (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
      Id      : constant Long_Long_Integer := Requests.Integer_Parameter (Request, "id");
      Db      : Database renames Worker_Database (Request);
      Data    : Binding_Set;
      Board   : Statement;
      Topics  : Statement;
      Page    : Positive;
   begin
      Prepare (Db, Board, "SELECT name, description FROM boards WHERE id = ?1");
      Bind (Board, 1, Id);
      if not Next_Row (Board) then
         Responses.Send (Response, Not_Found, "There is no such forum.");
         return;
      end if;
      Set (Data, "board_id", Id);
      Set (Data, "title", Text (Board, "name"));
      Set (Data, "description", Text (Board, "description"));
      Page := Paged (Request, Data, Count_Of (Db, "SELECT count(*) FROM threads WHERE board = ?1", Id),
                     Topics_Per_Page);

      Prepare (Db, Topics,
               "SELECT t.id AS id, t.title AS title, starter.name AS author, t.views AS views,"
               & "       (SELECT count(*) - 1 FROM posts WHERE thread = t.id) AS replies,"
               & "       strftime('%Y-%m-%d %H:%M', last.written, 'unixepoch') AS last_time,"
               & "       who.name AS last_author, last.id AS last_post,"
               & "       (SELECT " & Page_Holding ("count(*)") & " FROM posts WHERE thread = t.id) AS last_page"
               & "  FROM threads t"
               & "  JOIN users starter ON starter.id = t.author"
               & "  JOIN posts last ON last.id = (SELECT max(id) FROM posts WHERE thread = t.id)"
               & "  JOIN users who ON who.id = last.author"
               & " WHERE t.board = ?1 ORDER BY t.last_post DESC, t.id DESC LIMIT ?2 OFFSET ?3");
      Bind (Topics, 1, Id);
      Bind (Topics, 2, Long_Long_Integer (Topics_Per_Page));
      Bind (Topics, 3, Long_Long_Integer ((Page - 1) * Topics_Per_Page));
      Add_Rows (Data, "topics", Topics);
      Render_Page (Response, Session, "board", Data);
   end Show_Board;

   --  The thread page, with Error (and the reply that caused it) above the reply form when given. Without an
   --  error, a "quote" in the query fills the reply form with that post, quoted.
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
      Quoted : Statement;
      Db     : Database renames Worker_Database (Request);
      Page   : Positive;
   begin
      Prepare (Db, Thread,
               "SELECT t.title AS title, b.id AS board_id, b.name AS board_name"
               & "  FROM threads t JOIN boards b ON b.id = t.board WHERE t.id = ?1");
      Bind (Thread, 1, Id);
      if not Next_Row (Thread) then
         Responses.Send (Response, Not_Found, "There is no such topic.");
         return;
      end if;
      Set (Data, "id", Id);
      Set (Data, "title", Text (Thread, "title"));
      Set (Data, "board_id", Integer_Value (Thread, "board_id"));
      Set (Data, "board_name", Text (Thread, "board_name"));
      Page := Paged (Request, Data, Count_Of (Db, "SELECT count(*) FROM posts WHERE thread = ?1", Id),
                     Posts_Per_Page);

      Prepare (Db, Posts,
               "SELECT p.id AS post_id, p.body AS body, u.name AS author,"
               & "       strftime('%Y-%m-%d %H:%M', p.written, 'unixepoch') AS written,"
               & "       strftime('%Y-%m-%d', u.joined, 'unixepoch') AS joined,"
               & "       (SELECT count(*) FROM posts WHERE author = u.id) AS author_posts,"
               & "       " & Rank_Of ("(SELECT count(*) FROM posts WHERE author = u.id)") & " AS rank"
               & "  FROM posts p JOIN users u ON u.id = p.author"
               & " WHERE p.thread = ?1 ORDER BY p.id LIMIT ?2 OFFSET ?3");
      Bind (Posts, 1, Id);
      Bind (Posts, 2, Long_Long_Integer (Posts_Per_Page));
      Bind (Posts, 3, Long_Long_Integer ((Page - 1) * Posts_Per_Page));
      declare
         Number : Natural := (Page - 1) * Posts_Per_Page;
      begin
         while Next_Row (Posts) loop
            Number := Number + 1;
            declare
               Post : constant Sparrow.Templates.Scope := Add_Item (Data, "posts");
            begin
               Set (Data, "post_id", Integer_Value (Posts, "post_id"), Within => Post);
               Set (Data, "row_class", (if Number mod 2 = 1 then "row1" else "row2"), Within => Post);
               Set (Data, "subject", (if Number = 1 then "" else "Re: ") & Text (Thread, "title"), Within => Post);
               Set (Data, "body_html", Forum_BBCode.To_Html (Text (Posts, "body")), Within => Post);
               Set (Data, "author", Text (Posts, "author"), Within => Post);
               Set (Data, "written", Text (Posts, "written"), Within => Post);
               Set (Data, "joined", Text (Posts, "joined"), Within => Post);
               Set (Data, "rank", Text (Posts, "rank"), Within => Post);
               Set (Data, "author_posts", Integer_Value (Posts, "author_posts"), Within => Post);
            end;
         end loop;
      end;

      if Error'Length > 0 then
         Set (Data, "error", UTF8_String (Error));
         Set (Data, "draft", Draft);
      elsif Query_Number (Request, "quote") > 0 then
         Prepare (Db, Quoted,
                  "SELECT u.name AS author, p.body AS body FROM posts p JOIN users u ON u.id = p.author"
                  & " WHERE p.id = ?1 AND p.thread = ?2");
         Bind (Quoted, 1, Query_Number (Request, "quote"));
         Bind (Quoted, 2, Id);
         if Next_Row (Quoted) then
            Set (Data, "draft", "[quote=""" & Text (Quoted, "author") & """]" & Text (Quoted, "body") & "[/quote]"
                                & UTF8_String'(1 => Ada.Characters.Latin_1.LF));
         end if;
      end if;
      Render_Page (Response, Session, "thread", Data,
                   Status => (if Error'Length > 0 then Unprocessable_Content else OK));
   end Thread_Page;

   procedure Show_Thread (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
      Seen    : Statement;
   begin
      Prepare (Worker_Database (Request), Seen, "UPDATE threads SET views = views + 1 WHERE id = ?1");
      Bind (Seen, 1, Requests.Integer_Parameter (Request, "id"));
      Run (Seen);
      Thread_Page (Request, Response, Session);
   end Show_Thread;

   procedure Members (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
      Data    : Binding_Set;
      List    : Statement;
   begin
      Prepare (Worker_Database (Request), List,
               "SELECT name, strftime('%Y-%m-%d', joined, 'unixepoch') AS joined, posts, "
               & Rank_Of ("posts") & " AS rank"
               & "  FROM (SELECT u.name AS name, u.joined AS joined,"
               & "               (SELECT count(*) FROM posts WHERE author = u.id) AS posts FROM users u)"
               & " ORDER BY posts DESC, name LIMIT 500");
      Add_Rows (Data, "members", List);
      Set (Data, "title", "Members");
      Render_Page (Response, Session, "members", Data);
   end Members;

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
      Board   : constant Long_Long_Integer := Requests.Integer_Parameter (Request, "id");
      Here    : constant String := "/boards/" & Image (Board);
      Title   : constant UTF8_String := Trimmed (Requests.Form_Text (Request, "title"));
      Text_Of : constant UTF8_String := Trimmed (Requests.Form_Text (Request, "body"));
      Db      : Database renames Worker_Database (Request);
      Insert  : Statement;
      Id      : Long_Long_Integer;
   begin
      if not Form_Is_Ours (Request, Response, Session) then
         return;
      elsif not Logged_In (Session) then
         Redirect_With (Response, Session, "/login", "Log in to start a topic.");
         return;
      elsif Count_Of (Db, "SELECT count(*) FROM boards WHERE id = ?1", Board) = 0 then
         Responses.Send (Response, Not_Found, "There is no such forum.");
         return;
      elsif Title'Length not in 1 .. Max_Title or else Text_Of'Length not in 1 .. Max_Body then
         Redirect_With (Response, Session, Here, "A topic needs a subject (up to 120 bytes) and a first post.");
         return;
      end if;

      Begin_Transaction (Db);
      Prepare (Db, Insert, "INSERT INTO threads (title, author, board) VALUES (?1, ?2, ?3)");
      Bind (Insert, 1, Title);
      Bind (Insert, 2, User_Id (Session));
      Bind (Insert, 3, Board);
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
      Sparrow.Http.Event_Streams.Send (Watchers, UTF8_String (Image (Id)), Name => "thread");
      Redirect_With (Response, Session, "/threads/" & Image (Id), "");
   end New_Thread;

   procedure Reply (Request : Http_Request; Response : in out Http_Response) is
      Session : Sessions.Session := Visitors.Load (Request);
      Id      : constant Long_Long_Integer := Requests.Integer_Parameter (Request, "id");
      Text_Of : constant UTF8_String := Trimmed (Requests.Form_Text (Request, "body"));
      Db      : Database renames Worker_Database (Request);
      Insert  : Statement;
      Touch   : Statement;
      Post    : Long_Long_Integer;
      Page    : Long_Long_Integer;
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
         Responses.Send (Response, Not_Found, "There is no such topic.");
         return;
      end if;
      Prepare (Db, Insert, "INSERT INTO posts (thread, author, body) VALUES (?1, ?2, ?3)");
      Bind (Insert, 1, Id);
      Bind (Insert, 2, User_Id (Session));
      Bind (Insert, 3, Text_Of);
      Run (Insert);
      Post := Last_Insert_Id (Db);
      Page := Long_Long_Integer
        (Count_Of (Db, "SELECT " & Page_Holding ("count(*)") & " FROM posts WHERE thread = ?1", Id));
      Commit (Db);

      Sparrow.Http.Event_Streams.Send (Watchers, UTF8_String (Image (Id)), Name => "reply");
      Redirect_With (Response, Session, "/threads/" & Image (Id) & "?page=" & Image (Page) & "#post-" & Image (Post),
                     "");
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
