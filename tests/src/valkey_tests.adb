with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Checks; use Checks;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Encoding;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Http.Sessions;
with Sparrow.IO.Process;
with Sparrow.Times;
with Sparrow.Valkey; use Sparrow.Valkey;
with Sparrow.Http.Limits;
with Sparrow.Valkey.Limits;
with Sparrow.Valkey.Sessions;
with Sparrow.Valkey_Protocol; use Sparrow.Valkey_Protocol;

--  The protocol on its own, then against the server valkey_server.sh starts (skipped when nothing listens on
--  localhost:16379).
procedure Valkey_Tests is
   use Sparrow;

   CRLF : constant String := [ASCII.CR, ASCII.LF];

   Password : constant String := "sparrow%20p%C3%A4ssword";
   Plain    : constant String := "valkey://:" & Password & "@localhost:16379";
   Secure   : constant String := "valkeys://default:" & Password & "@localhost:16380/2";

   function Outcome_Of (Data : String) return Scan_Outcome is (Scan (Data).Outcome);

   procedure Protocol_Tests is
      Nested : constant String :=
        "*3" & CRLF & ":1" & CRLF & "*2" & CRLF & "$1" & CRLF & "x" & CRLF & "$-1" & CRLF & "+OK" & CRLF;
      Bulk   : constant String := "$5" & CRLF & "a" & CRLF & "b\" & CRLF;
      Every_Cut_Waits : Boolean := True;
   begin
      Check (Scan ("+OK" & CRLF & "extra") = (Outcome => Complete, Length => 5), "a status reply and its length");
      Check (Scan (Bulk) = (Outcome => Complete, Length => Bulk'Length), "a bulk string may hold CR and LF");
      declare
         Item : constant Element := Element_At (Bulk, 1);
      begin
         Check (Item.Kind = Bulk_Text and then Encoding.Slice (Bulk, Item.Text) = "a" & CRLF & "b\",
                "the bulk string's text");
      end;
      Check (Scan (Nested) = (Outcome => Complete, Length => Nested'Length), "nested lists end where they end");
      for Cut in 0 .. Nested'Length - 1 loop
         Every_Cut_Waits := Every_Cut_Waits and then Outcome_Of (Nested (1 .. Cut)) = Waiting;
      end loop;
      Check (Every_Cut_Waits, "a reply cut anywhere is waited for");
      Check (Outcome_Of ("*0" & CRLF) = Complete and then Outcome_Of ("*-1" & CRLF) = Complete
             and then Outcome_Of ("$0" & CRLF & CRLF) = Complete, "empty and nil lists, the empty string");
      Check (Outcome_Of ("?" & CRLF) = Refused and then Outcome_Of (":12a" & CRLF) = Refused
             and then Outcome_Of ("$-2" & CRLF) = Refused and then Outcome_Of ("$1" & CRLF & "ab" & CRLF) = Refused
             and then Outcome_Of (":" & CRLF) = Refused and then Outcome_Of (":1234567890123456789" & CRLF) = Refused,
             "malformed replies are refused");
      Check (Outcome_Of ("*1000001" & CRLF) = Refused and then Outcome_Of ("$536870913" & CRLF) = Refused,
             "lists and strings past the limits are refused");
      Check (Outcome_Of ("*1000000" & CRLF & "*1000000" & CRLF) = Refused,
             "nested lists together past the limit are refused");
      Check (Outcome_Of ("$536870912" & CRLF) = Waiting, "a large string is waited for, not read early");
      Check (Header (3) = "*3" & CRLF, "a command's header");
      declare
         Command : Buffer;
      begin
         Append_Argument (Command, "GET");
         Append_Argument (Command, "");
         Check (Content (Command) = "$3" & CRLF & "GET" & CRLF & "$0" & CRLF & CRLF, "arguments as bulk strings");
         Free (Command);
      end;
   end Protocol_Tests;

   procedure Url_Tests is
      function Refused (Url : String) return Boolean is
         Unused : Server;
      begin
         Unused := Server_At (Url);
         return False;
      exception
         when Constraint_Error =>
            return True;
      end Refused;
   begin
      Check (not Refused ("valkey://localhost") and then not Refused ("redis://h:1/15")
             and then not Refused ("rediss://user:p%40ss@[::1]:6380/0") and then not Refused ("valkeys://:pw@cache"),
             "server URLs of each form");
      Check (Refused ("http://localhost") and then Refused ("valkey://") and then Refused ("valkey://h:0")
             and then Refused ("valkey://h:65536") and then Refused ("valkey://h:x") and then Refused ("valkey://h/x")
             and then Refused ("valkey://[::1") and then Refused ("valkey://:%zz@h"),
             "malformed server URLs are refused");
   end Url_Tests;

   --  Whether connecting to Url fails with a message that holds Expected.
   function Connect_Refused (Url : String; Expected : String; Trust_File : String := "") return Boolean is
      Link : Connection;
   begin
      Connect (Link, Server_At (Url, Trust_File => Trust_File, Timeout => 2_000));
      return False;
   exception
      when Problem : Connection_Error =>
         declare
            Reason : constant String := Ada.Exceptions.Exception_Message (Problem);
         begin
            if Ada.Strings.Fixed.Index (Reason, Expected) = 0 then
               Ada.Text_IO.Put_Line ("   refused for another reason: " & Reason);
               return False;
            end if;
            return not Is_Connected (Link);
         end;
   end Connect_Refused;

   function Now return Long_Long_Integer is
      Seconds : Times.Unix_Seconds;
   begin
      IO.Process.Read_Clock (Seconds);
      return Long_Long_Integer (Seconds);
   end Now;

   Link   : Connection;
   Answer : Reply;
begin
   Protocol_Tests;
   Url_Tests;

   begin
      Connect (Link, Server_At (Plain, Timeout => 2_000));
   exception
      when Problem : Connection_Error =>
         Ada.Text_IO.Put_Line ("valkey: skipped, no test server (run tests/valkey_server.sh): "
                   & Ada.Exceptions.Exception_Message (Problem));
         Finish ("valkey");
         return;
   end;
   Check (Is_Connected (Link), "connect and sign in, unencrypted");

   Check (Connect_Refused ("valkey://:wrong@localhost:16379", "WRONGPASS"), "a wrong password is refused");
   Check (Connect_Refused ("valkey://localhost:16379", "NOAUTH")
          or else Connect_Refused ("valkey://localhost:16379", "authentication"),
          "no password: the first command is refused");
   Check (Connect_Refused ("valkey://localhost:16399", "refused"), "nothing listening");
   Check (Connect_Refused ("valkeys://:" & Password & "@localhost:16380", "certificate"),
          "TLS: a certificate the system does not trust is refused");

   --  The everyday commands.
   Delete (Link, "greeting");
   Check (Get (Link, "greeting", Default => "none") = "none" and then not Exists (Link, "greeting"),
          "a missing key gives the default");
   Set (Link, "greeting", "hello");
   Check (Get (Link, "greeting") = "hello" and then Exists (Link, "greeting"), "set, then get");
   declare
      Binary : constant String := "a" & ASCII.NUL & CRLF & "ü" & Character'Val (255);
      Large  : constant String (1 .. 5_000_000) := [others => 'v'];
   begin
      Set (Link, "binary", Binary);
      Check (Get (Link, "binary") = Binary, "any bytes come back as they went");
      Set (Link, "large", Large);
      Check (Get (Link, "large") = Large, "a 5 MB value");
      Delete (Link, "large");
   end;
   Delete (Link, "counter");
   Check (Increment (Link, "counter") = 1 and then Increment (Link, "counter", By => 41) = 42,
          "a counter");
   Check (Expire (Link, "counter", 100) and then not Expire (Link, "no such key", 100), "expiry");
   Set (Link, "short", "lived", Lifetime => 1);
   Start (Link, "TTL"); Add (Link, "short");
   Read_Reply (Link, Answer);
   Check (Kind (Answer) = Number and then Number (Answer) in 0 .. 1, "a value with a lifetime");
   begin
      Set (Link, "counter", "not a number");
      Check (Increment (Link, "counter") = 0, "a refused helper command raises Command_Error");
   exception
      when Command_Error =>
         Check (Is_Connected (Link), "a refused helper command raises Command_Error");
   end;

   --  A counter for a window, and setting only what is absent.
   Delete (Link, "window");
   Check (Increment (Link, "window", Lifetime => 100) = 1, "a window counter starts");
   Start (Link, "EXPIRE"); Add (Link, "window"); Add (Link, 30);
   Read_Reply (Link, Answer);
   Check (Increment (Link, "window", By => 4, Lifetime => 100) = 5, "a window counter counts");
   Start (Link, "TTL"); Add (Link, "window");
   Read_Reply (Link, Answer);
   Check (Number (Answer) in 29 .. 30, "a window counter keeps the end it has");
   Set (Link, "window", "not a number");
   begin
      Check (Increment (Link, "window", Lifetime => 100) = 0, "a window counter of text is refused");
   exception
      when Command_Error =>
         Check (Is_Connected (Link) and then Replies_Due (Link) = 0, "a window counter of text is refused");
   end;
   Delete (Link, "once");
   Check (Set_If_Absent (Link, "once", "first", Lifetime => 60), "set when absent");
   Check (not Set_If_Absent (Link, "once", "second") and then Get (Link, "once") = "first",
          "not set when present");

   --  Any command, pipelined.
   Delete (Link, "list");
   for Position in 1 .. 1_000 loop
      Start (Link, "RPUSH"); Add (Link, "list"); Add (Link, Long_Long_Integer (Position));
   end loop;
   Check (Replies_Due (Link) = 1_000, "a thousand commands built");
   declare
      Every_Reply : Boolean := True;
   begin
      for Position in 1 .. 1_000 loop
         Read_Reply (Link, Answer);
         Every_Reply := Every_Reply and then Kind (Answer) = Number
                        and then Number (Answer) = Long_Long_Integer (Position);
      end loop;
      Check (Every_Reply and then Replies_Due (Link) = 0, "a thousand replies, in order");
   end;
   Start (Link, "LRANGE"); Add (Link, "list"); Add (Link, 0); Add (Link, -1);
   Read_Reply (Link, Answer);
   Check (Kind (Answer) = List and then Count (Answer) = 1_000 and then Text (Link, Item (Link, Answer, 1)) = "1"
          and then Text (Link, Item (Link, Answer, 1_000)) = "1000", "a list reply");
   Start (Link, "EVAL"); Add (Link, "return {1, {'x', false}, 'y'}"); Add (Link, 0);
   Read_Reply (Link, Answer);
   declare
      Inner : constant Reply := Item (Link, Answer, 2);
   begin
      Check (Kind (Answer) = List and then Count (Answer) = 3 and then Number (Item (Link, Answer, 1)) = 1
             and then Kind (Inner) = List and then Count (Inner) = 2 and then Text (Link, Item (Link, Inner, 1)) = "x"
             and then Kind (Item (Link, Inner, 2)) = Nil and then Text (Link, Item (Link, Answer, 3)) = "y",
             "a nested reply");
   end;
   Start (Link, "NO-SUCH-COMMAND");
   Read_Reply (Link, Answer);
   Check (Kind (Answer) = Error and then Ada.Strings.Fixed.Index (Text (Link, Answer), "unknown command") > 0,
          "a refused command is an Error reply");
   Start (Link, "PING");
   Read_Reply (Link, Answer);
   Check (Kind (Answer) = Status and then Text (Link, Answer) = "PONG", "the connection goes on after a refusal");

   --  TLS, with the test certificate trusted, on database 2.
   declare
      Safe : Connection;
   begin
      Connect (Safe, Server_At (Secure, Trust_File => "data/cert.pem"));
      Set (Safe, "greeting", "over TLS");
      Check (Get (Safe, "greeting") = "over TLS" and then Get (Link, "greeting") = "hello",
             "TLS, on its own database");
      Close (Safe);
      Check (not Is_Connected (Safe), "close");
   exception
      when Problem : Connection_Error =>
         Check (False, "TLS: " & Ada.Exceptions.Exception_Message (Problem));
   end;

   --  The server ends the connection: Connection_Error, and the connection is closed.
   declare
      Victim : Connection;
   begin
      Connect (Victim, Server_At (Plain));
      Start (Victim, "CLIENT"); Add (Victim, "SETNAME"); Add (Victim, "victim");
      Read_Reply (Victim, Answer);
      Start (Link, "CLIENT"); Add (Link, "KILL"); Add (Link, "SKIPME"); Add (Link, "yes");
      Add (Link, "TYPE"); Add (Link, "normal");
      Read_Reply (Link, Answer);
      begin
         Check (Get (Victim, "greeting") = "", "a lost connection raises Connection_Error");
      exception
         when Connection_Error =>
            Check (not Is_Connected (Victim), "a lost connection raises Connection_Error, and is closed");
      end;
   end;
   Check (Is_Connected (Link), "the connection that killed the others lives");

   --  Sessions kept in Valkey.
   declare
      package Requests renames Sparrow.Http.Requests;
      package Responses renames Sparrow.Http.Responses;
      package Sessions renames Sparrow.Http.Sessions;
      Table : constant Sessions.Session_Table_Access :=
        Valkey.Sessions.Table (Plain, Prefix => "test:", Connections => 2);
      Kept  : constant Sessions.Store := Sessions.Table_Store (Table);
      Ends  : constant Long_Long_Integer := Now + 600;

      Request : Requests.Request;
      Bytes   : Buffer;

      function Loaded (Id : String) return Sessions.Session is
         Valid : Boolean;
      begin
         Requests.Free (Request);
         Clear (Bytes);
         Append (Bytes, "GET / HTTP/1.1" & CRLF & "Host: localhost" & CRLF
                        & (if Id = "" then "" else "Cookie: session=" & Id & CRLF) & CRLF);
         Requests.Load (Request, Bytes, Valid);
         return Kept.Load (Request);
      end Loaded;

      --  Saves Session; the id the cookie carries.
      function Saved (Session : in out Sessions.Session) return String is
         Response : Responses.Response;
         Head     : Buffer;
      begin
         Kept.Save (Session, Response);
         Responses.Write_Head (Response, Head, 0, Keep_Alive => True);
         declare
            Text  : constant String := Content (Head);
            First : constant Natural := Ada.Strings.Fixed.Index (Text, "session=");
         begin
            Free (Head);
            Responses.Free (Response);
            return (if First = 0 then "" else Text (First + 8 .. First + 8 + 42));
         end;
      end Saved;
   begin
      Table.Write ("a", "", "data a", Ends);
      Table.Write ("b", "7", "data b", Ends);
      Table.Write ("c", "7", "data c", Ends);
      Table.Write ("d", "8", "data d", Ends);
      Check (Table.Read ("a") = "data a" and then Table.Read ("b") = "data b" and then Table.Read ("none") = "",
             "the table: write, read");
      Check (Get (Link, "test:session:b") = "data b" and then Exists (Link, "test:user:7"),
             "the table: one key a session, one set a user");
      Start (Link, "TTL"); Add (Link, "test:session:b");
      Read_Reply (Link, Answer);
      Check (Number (Answer) in 590 .. 600, "the table: Valkey ends the session on time");
      Start (Link, "TTL"); Add (Link, "test:user:7");
      Read_Reply (Link, Answer);
      Check (Number (Answer) in 590 .. 600, "the table: and the user's set with it");
      Table.Delete ("a");
      Table.Delete_User ("7");
      Check (Table.Read ("a") = "" and then Table.Read ("b") = "" and then Table.Read ("c") = ""
             and then Table.Read ("d") = "data d" and then not Exists (Link, "test:user:7"),
             "the table: delete one, then every session of user 7 and only those");
      Table.Delete_User ("8");

      declare
         Session : Sessions.Session := Loaded ("");
         Id      : Buffer;
      begin
         Sessions.Set (Session, "user", "9");
         Sessions.Set (Session, "cart", "3 apples");
         Append (Id, Saved (Session));
         Check (Id.Length = 43 and then Sessions.Get (Loaded (Content (Id)), "cart") = "3 apples",
                "a Table_Store over Valkey: the session comes back by its id");
         Kept.Revoke_User ("9");
         Check (not Sessions.Has (Loaded (Content (Id)), "cart"), "and Revoke_User ends it");
         Free (Id);
      end;

      --  Valkey restarts under the table: the next call connects again.
      Start (Link, "CLIENT"); Add (Link, "KILL"); Add (Link, "SKIPME"); Add (Link, "yes");
      Add (Link, "TYPE"); Add (Link, "normal");
      Read_Reply (Link, Answer);
      Table.Write ("e", "", "data e", Ends);
      Check (Table.Read ("e") = "data e", "the table connects again after losing its connections");
      Table.Delete ("e");

      --  Many tasks at once share the table's two connections.
      declare
         task type Visitor is
            entry Visit (Number : Positive);
         end Visitor;
         task body Visitor is
            Order : Positive;
         begin
            accept Visit (Number : Positive) do
               Order := Number;
            end Visit;
            declare
               Id : constant String := "visitor" & Encoding.Decimal_Image (Long_Long_Integer (Order));
            begin
            for Round in 1 .. 50 loop
               Table.Write (Id, "", Id & Encoding.Decimal_Image (Long_Long_Integer (Round)), Ends);
               if Table.Read (Id) /= Id & Encoding.Decimal_Image (Long_Long_Integer (Round)) then
                  Ada.Text_IO.Put_Line ("   " & Id & " read another's write");
               end if;
            end loop;
            Table.Delete (Id);
            end;
         exception
            when Problem : others =>
               Ada.Text_IO.Put_Line ("   visitor: " & Ada.Exceptions.Exception_Information (Problem));
         end Visitor;
         Visitors : array (1 .. 8) of Visitor;
      begin
         for Index in Visitors'Range loop
            Visitors (Index).Visit (Index);
         end loop;
      end;
      Check (Table.Read ("visitor1") = "" and then Table.Read ("visitor8") = "",
             "eight tasks share two connections");
      Requests.Free (Request);
      Free (Bytes);
   end;

   --  Rate limits counted in Valkey: two limits of the same name stand for two servers.
   declare
      package Limits renames Sparrow.Http.Limits;
      First_Server  : constant Limits.Limit :=
        Limits.Per_Client (0.001, 3, Store => Valkey.Limits.Buckets (Plain, Name => "test-shared"));
      Second_Server : constant Limits.Limit :=
        Limits.Per_Client (0.001, 3, Store => Valkey.Limits.Buckets (Plain, Name => "test-shared"));
      Other_Limit   : constant Limits.Limit :=
        Limits.Per_Client (0.001, 1, Store => Valkey.Limits.Buckets (Plain, Name => "test-other"));
      Unreachable   : constant Limits.Limit :=
        Limits.Per_Client (0.001, 1, Store => Valkey.Limits.Buckets ("valkey://localhost:16399", Name => "x"));
      Allowed       : Boolean;
      Retry_After   : Natural;
      Every         : Boolean;
   begin
      Delete (Link, "sparrow:limit:test-shared:192.0.2.1");
      Delete (Link, "sparrow:limit:test-other:192.0.2.1");
      Delete (Link, "sparrow:limit:test-shared:192.0.2.2");
      Limits.Take (First_Server, "192.0.2.1", Allowed, Retry_After);
      Every := Allowed;
      Limits.Take (Second_Server, "192.0.2.1", Allowed, Retry_After);
      Every := Every and then Allowed;
      Limits.Take (First_Server, "192.0.2.1", Allowed, Retry_After);
      Check (Every and then Allowed, "a shared bucket gives its burst, whichever server asks");
      Limits.Take (Second_Server, "192.0.2.1", Allowed, Retry_After);
      Check (not Allowed and then Retry_After in 999 .. 1000, "then refuses on every server, and says how long");
      Limits.Take (First_Server, "192.0.2.2", Allowed, Retry_After);
      Check (Allowed, "another client has its own bucket");
      Limits.Take (Other_Limit, "192.0.2.1", Allowed, Retry_After);
      Check (Allowed, "another limit has its own buckets");
      Start (Link, "PTTL"); Add (Link, "sparrow:limit:test-shared:192.0.2.1");
      Read_Reply (Link, Answer);
      Check (Number (Answer) in 2_000_000 .. 3_001_000, "an empty bucket expires once it would be full again");
      Limits.Take (Unreachable, "192.0.2.1", Allowed, Retry_After);
      Limits.Take (Unreachable, "192.0.2.1", Allowed, Retry_After);
      Check (Allowed and then Retry_After = 0, "with Valkey out of reach, requests are let through");
   end;

   Close (Link);
   Finish ("valkey");
end Valkey_Tests;
