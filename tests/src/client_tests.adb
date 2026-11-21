--  The outbound client: its URL and response-head parsing, against a Sparrow server in this process (plain and
--  over TLS), and against a scripted server for the answers a well-behaved one never gives.
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Checks; use Checks;
with Http_Test_Handlers; use Http_Test_Handlers;
with Sparrow.Client;
with Sparrow.Client_Wire; use Sparrow.Client_Wire;
with Sparrow.Encoding;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.IO.Process;
with Sparrow.IO.Sockets; use Sparrow.IO.Sockets;
with Sparrow.IO; use Sparrow.IO;
with Sparrow.Tls;

procedure Client_Tests is

   package Client renames Sparrow.Client;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   Port   : constant := 18_477;
   Routes : Routers.Router (8);
   Server_Context : aliased Sparrow.Tls.Context;

   ---------------------------------------------------------------------------------------------------------------
   --  URLs and heads

   function Target_Of (Url : String) return String is
      Parts : constant Url_Parts := Split_Url (Url);
   begin
      return (if Parts.Valid then Sparrow.Encoding.Slice (Url, Parts.Target) else "!");
   end Target_Of;

   procedure Url_Tests is
      Parts : Url_Parts;
   begin
      Parts := Split_Url ("HTTPS://Example.com");
      Check (Parts.Valid and then Parts.Secure and then Parts.Port = 443
             and then Sparrow.Encoding.Slice ("HTTPS://Example.com", Parts.Host) = "Example.com"
             and then Sparrow.Encoding.Length (Parts.Target) = 0, "a URL: the scheme in any case, no path");
      Parts := Split_Url ("http://[::1]:8080/a?b#c");
      Check (Parts.Valid and then Parts.Bracketed and then Parts.Port = 8080
             and then Sparrow.Encoding.Slice ("http://[::1]:8080/a?b#c", Parts.Host) = "::1",
             "a URL: an IPv6 address and a port");
      Equal (Target_Of ("http://[::1]:8080/a?b#c"), "/a?b", "a URL: the fragment is dropped");
      Equal (Target_Of ("http://h?q=1"), "?q=1", "a URL: a query without a path");
      Equal (Target_Of ("http://h:/x"), "/x", "a URL: an empty port is the scheme's");
      Equal (Target_Of ("ftp://h/"), "!", "a URL: another scheme");
      Equal (Target_Of ("http://user:pass@h/"), "!", "a URL: credentials");
      Equal (Target_Of ("http:///x"), "!", "a URL: no host");
      Equal (Target_Of ("http://h:0/"), "!", "a URL: port 0");
      Equal (Target_Of ("http://h:65536/"), "!", "a URL: a port past 65535");
      Equal (Target_Of ("http://h/a b"), "!", "a URL: a space in the path");
      Equal (Target_Of ("http://h/a" & ASCII.CR & ASCII.LF & "X: y"), "!", "a URL: a line break in the path");
      Equal (Target_Of ("http://h%0d/"), "!", "a URL: a host that is not a name");
      Equal (Target_Of ("http://[::1/"), "!", "a URL: an address not closed");
   end Url_Tests;

   function Head_Of (Answer : String; Asked_Head : Boolean := False) return Response_Head is
     (Parse_Head (Answer, Asked_Head, Max_Head_Length => 4096));

   procedure Head_Tests is
      Plain : constant String := "HTTP/1.1 200 OK" & CRLF & "Content-Length: 5" & CRLF & "X-A:  b " & CRLF & CRLF
                                 & "hello";
      Head  : Response_Head := Head_Of (Plain);
   begin
      Check (Head.Outcome = Complete and then Head.Status = 200 and then Head.Minor_Version = 1
             and then Head.Framing = Sized and then Head.Body_Length = 5 and then Head.Head_Length = Plain'Length - 5
             and then Sparrow.Encoding.Slice (Plain, Header_Value (Plain, Head, "x-a")) = "b",
             "a head: status, length, a header trimmed and found in any case");
      Check (Head_Of (Plain (Plain'First .. Plain'Last - 7)).Outcome = Incomplete, "a head without its blank line");
      Head := Head_Of ("HTTP/1.0 204" & ASCII.LF & ASCII.LF);
      Check (Head.Outcome = Complete and then Head.Minor_Version = 0 and then Head.Framing = No_Body,
             "a head: HTTP/1.0, bare line feeds, no reason, no body for 204");
      Check (Head_Of (Plain, Asked_Head => True).Framing = No_Body, "a head: no body after HEAD");
      Check (Head_Of ("HTTP/1.1 200 OK" & CRLF & CRLF).Framing = Until_Close, "a head: neither length nor chunked");
      Check (Head_Of ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 3" & CRLF & "Transfer-Encoding: gzip, Chunked"
                      & CRLF & CRLF).Framing = Chunks, "a head: chunked last wins over a length");
      Check (Head_Of ("HTTP/1.1 200 OK" & CRLF & "Transfer-Encoding: chunked, gzip" & CRLF & CRLF).Framing
             = Until_Close, "a head: chunked not last");
      Check (Head_Of ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 3" & CRLF & "Content-Length: 3" & CRLF & CRLF)
             .Outcome = Complete, "a head: a length repeated alike");
      declare
         Bad_Heads : constant array (1 .. 11) of Unbounded_String :=
                    [To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 3" & CRLF & "Content-Length: 4"),
                     To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF & "Content-Length: -3"),
                     To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 99999999999999999999"),
                     To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF & "X-A: b" & CRLF & " folded"),
                     To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF & "X A: b"),
                     To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF & ": b"),
                     To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF & "X-A: b" & ASCII.NUL),
                     To_Unbounded_String ("HTTP/2.0 200 OK"),
                     To_Unbounded_String ("HTTP/1.1 20 OK"),
                     To_Unbounded_String ("HTTP/1.1 200OK"),
                     To_Unbounded_String ("SMTP ready")];
      begin
         for Bad of Bad_Heads loop
            Check (Head_Of (To_String (Bad) & CRLF & CRLF).Outcome = Invalid,
                   "a head refused: " & To_String (Bad) (1 .. Natural'Min (Length (Bad), 60)));
         end loop;
      end;
      declare
         Many : Unbounded_String := To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF);
      begin
         for Index in 1 .. Max_Headers + 1 loop
            Append (Many, "X: y" & CRLF);
         end loop;
         Check (Head_Of (To_String (Many) & CRLF).Outcome = Invalid, "a head: more than Max_Headers");
      end;
      Check (Head_Of ([1 .. 5000 => 'x']).Outcome = Invalid, "a head: longer than the limit");
   end Head_Tests;

   ---------------------------------------------------------------------------------------------------------------
   --  a scripted server: answers each connection with the next answer as written, and keeps what it was sent

   Script_Port : constant := 18_476;
   Silent      : constant String := "(silent)";   --  answer nothing, and hold the connection for 3 seconds

   type Answer_List is array (1 .. 4) of Unbounded_String;

   task type Script_Server is
      entry Start (Answers : Answer_List; Count : Positive);
      entry Finished (Requests : out Unbounded_String);
   end Script_Server;

   task body Script_Server is
      Listener : Descriptor;
      Failure  : Error;
      Script   : Answer_List;
      Total    : Positive;
      Seen     : Unbounded_String;
   begin
      --  Listening before Start returns, so the caller's client cannot connect first.
      accept Start (Answers : Answer_List; Count : Positive) do
         Script := Answers;
         Total  := Count;
         Open_Listener (Loopback, Script_Port, Listener, Failure, Share_Port => False);
      end Start;
      for Turn in 1 .. Total loop
         declare
            Socket   : Descriptor := No_Descriptor;
            Received : Unbounded_String;
            Room     : String (1 .. 4096);
            Count    : Integer;
         begin
            for Attempt in 1 .. 500 loop
               Accept_Client (Listener, Socket, Failure);
               exit when Socket /= No_Descriptor;
               Sparrow.IO.Process.Sleep (10);
            end loop;
            exit when Socket = No_Descriptor;
            for Attempt in 1 .. 500 loop
               Receive (Socket, Room, Count, Failure);
               if Count > 0 then
                  Append (Received, Room (1 .. Count));
               else
                  Sparrow.IO.Process.Sleep (2);
               end if;
               exit when Ada.Strings.Fixed.Index (To_String (Received), CRLF & CRLF) > 0 or else Count = 0;
            end loop;
            Append (Seen, Received);
            if Script (Turn) = Silent then
               Sparrow.IO.Process.Sleep (3000);
            else
               declare
                  Answer : constant String := To_String (Script (Turn));
                  Sent   : Natural := 0;
               begin
                  while Sent < Answer'Length loop
                     Send (Socket, Answer (Answer'First + Sent .. Answer'Last), Count, Failure);
                     exit when Count < 0 and then Failure.Kind /= Would_Block;
                     Sent := Sent + Integer'Max (Count, 0);
                  end loop;
               end;
            end if;
            Close (Socket);
         end;
      end loop;
      Close (Listener);
      accept Finished (Requests : out Unbounded_String) do
         Requests := Seen;
      end Finished;
   end Script_Server;

   --  The answers of Count connections, and what was sent; Problem is the client's Request_Error, if any.
   procedure Scripted
     (Answers  : Answer_List;
      Count    : Positive;
      Url      : String;
      Answer   : in out Client.Response;
      Problem  : out Unbounded_String;
      Requests : out Unbounded_String;
      Headers  : String := "";
      Using    : Client.Settings := Client.Default_Settings)
   is
      Server : Script_Server;
   begin
      Server.Start (Answers, Count);
      Problem := Null_Unbounded_String;
      begin
         Client.Get (Url, Answer, Headers => Headers, Using => Using);
      exception
         when Failure : Client.Request_Error =>
            Problem := To_Unbounded_String (Ada.Exceptions.Exception_Message (Failure));
      end;
      Server.Finished (Requests);
   end Scripted;

   procedure Script_Tests is
      Base     : constant String := "http://127.0.0.1:" & "18476";
      Answer   : Client.Response;
      Problem  : Unbounded_String;
      Requests : Unbounded_String;

      function Only (Text : String) return Answer_List is [1 => To_Unbounded_String (Text), others => <>];

      function Says (Fragment : String) return Boolean is
        (Ada.Strings.Fixed.Index (To_String (Problem), Fragment) > 0);
   begin
      Scripted (Only ("HTTP/1.1 100 Continue" & CRLF & CRLF & "HTTP/1.1 200 OK" & CRLF & "Content-Length: 2"
                      & CRLF & CRLF & "hi"), 1, Base & "/a?b=1", Answer, Problem, Requests);
      Check (Problem = "" and then Client.Status (Answer) = 200 and then Client.Content (Answer) = "hi",
             "scripted: an interim answer is passed over");
      Check (Ada.Strings.Fixed.Index (To_String (Requests), "GET /a?b=1 HTTP/1.1" & CRLF & "Host: 127.0.0.1:18476"
                                      & CRLF) = 1
             and then Ada.Strings.Fixed.Index (To_String (Requests), "Connection: close" & CRLF) > 0,
             "scripted: the request line, Host with its port, Connection: close");

      Scripted (Only ("HTTP/1.0 200 OK" & CRLF & CRLF & "all of it"), 1, Base & "/", Answer, Problem, Requests);
      Check (Problem = "" and then Client.Content (Answer) = "all of it" and then Client.Version (Answer) = 10,
             "scripted: content up to the end of the connection, HTTP/1.0");

      Scripted (Only ("HTTP/1.1 200 OK" & CRLF & "Transfer-Encoding: chunked" & CRLF & CRLF & "3" & CRLF & "abc"
                      & CRLF & "2;x=y" & CRLF & "de" & CRLF & "0" & CRLF & "T: 1" & CRLF & CRLF),
                1, Base & "/", Answer, Problem, Requests);
      Check (Problem = "" and then Client.Content (Answer) = "abcde", "scripted: chunked content");

      Scripted (Only ("HTTP/1.1 200 OK" & ASCII.LF & "X-A: b" & ASCII.LF & "Content-Length: 1" & ASCII.LF & ASCII.LF
                      & "z"), 1, Base & "/", Answer, Problem, Requests);
      Check (Problem = "" and then Client.Header (Answer, "X-A") = "b" and then Client.Content (Answer) = "z",
             "scripted: lines ended by bare line feeds");

      Scripted (Only ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 10" & CRLF & CRLF & "abc"), 1, Base & "/",
                Answer, Problem, Requests);
      Check (Says ("cut short"), "scripted: content shorter than its length raises");

      Scripted (Only ("HTTP/1.1 200 OK" & CRLF & "Transfer-Encoding: chunked" & CRLF & CRLF & "3" & CRLF & "ab"),
                1, Base & "/", Answer, Problem, Requests);
      Check (Says ("cut short"), "scripted: chunked content cut short raises");

      Scripted (Only ("HTTP/1.1 200 OK" & CRLF & "Transfer-Encoding: chunked" & CRLF & CRLF & "zz" & CRLF), 1,
                Base & "/", Answer, Problem, Requests);
      Check (Says ("malformed"), "scripted: malformed chunks raise");

      Scripted (Only ("220 smtp.example ESMTP" & CRLF & CRLF), 1, Base & "/", Answer, Problem, Requests);
      Check (Says ("not HTTP"), "scripted: an answer that is not HTTP raises");

      Scripted (Only (""), 1, Base & "/", Answer, Problem, Requests);
      Check (Says ("without answering"), "scripted: a connection closed without an answer raises");

      Scripted (Only ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 5000" & CRLF & CRLF), 1, Base & "/", Answer,
                Problem, Requests, Using => (Max_Response => 1000, others => <>));
      Check (Says ("larger than"), "scripted: a length past Max_Response raises before reading");

      Scripted (Only (Silent), 1, Base & "/", Answer, Problem, Requests, Using => (Timeout => 300, others => <>));
      Check (Says ("time ran out"), "scripted: a server that never answers runs out of time (said: "
             & To_String (Problem) & ")");

      Scripted ([To_Unbounded_String ("HTTP/1.1 302 Found" & CRLF & "Location: http://localhost:18476/next"
                                      & CRLF & "Content-Length: 0" & CRLF & CRLF),
                 To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 4" & CRLF & CRLF & "done"),
                 others => <>],
                2, Base & "/first", Answer, Problem, Requests, Headers => "Authorization: Bearer secret",
                Using => (Follow_Redirects => True, others => <>));
      Check (Problem = "" and then Client.Content (Answer) = "done"
             and then Ada.Strings.Fixed.Count (To_String (Requests), "Authorization: Bearer secret") = 1
             and then Ada.Strings.Fixed.Index (To_String (Requests), "GET /next HTTP/1.1" & CRLF
                                               & "Host: localhost:18476") > 0,
             "scripted: a redirect to another host is followed without the caller's headers");

      Scripted ([To_Unbounded_String ("HTTP/1.1 307 Temporary" & CRLF & "Location: again" & CRLF & CRLF),
                 To_Unbounded_String ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 2" & CRLF & CRLF & "ok"),
                 others => <>],
                2, Base & "/dir/first", Answer, Problem, Requests, Headers => "X-Kept: 1",
                Using => (Follow_Redirects => True, others => <>));
      Check (Problem = "" and then Client.Content (Answer) = "ok"
             and then Ada.Strings.Fixed.Count (To_String (Requests), "X-Kept: 1") = 2
             and then Ada.Strings.Fixed.Index (To_String (Requests), "GET /dir/again HTTP/1.1") > 0,
             "scripted: a relative redirect on the same origin keeps the caller's headers");
   end Script_Tests;

   procedure Refusal_Tests is
      Answer : Client.Response;

      procedure Refused (Url : String; Headers : String; Name : String; Method : String := "GET") is
      begin
         Client.Send (Method, Url, Answer, Headers => Headers);
         Check (False, Name);
      exception
         when Client.Request_Error => Check (True, Name);
      end Refused;
   begin
      Refused ("http://127.0.0.1:18478/", "", "a refused connection raises Request_Error");
      Refused ("ftp://127.0.0.1/", "", "another scheme raises Request_Error");
      Refused ("http://127.0.0.1/a b", "", "a space in the URL raises Request_Error");
      Refused ("http://127.0.0.1/", "X: a" & ASCII.CR & "Injected: b", "a CR inside a header line is refused");
      Refused ("http://127.0.0.1/", "No colon", "a header line without a name is refused");
      Refused ("http://127.0.0.1/", "Host: elsewhere", "a Host header from the caller is refused");
      Refused ("http://127.0.0.1/", "", "a method that is not a token is refused", Method => "GET /x");
      Refused ("http://no-such-host.invalid/", "", "a name that does not resolve raises Request_Error");
   end Refusal_Tests;

   ---------------------------------------------------------------------------------------------------------------
   --  against Sparrow's own server

   task type Server_Task is
      entry Start (Secure : Boolean);
      entry Finished;
   end Server_Task;

   task body Server_Task is
      Use_Tls : Boolean;
   begin
      accept Start (Secure : Boolean) do
         Use_Tls := Secure;
      end Start;
      Servers.Run (Settings => (Port => Port, Reactors => 1, Workers => 2, Catch_Signals => False, Access_Log => False,
                                others => <>),
                   Routes   => Routes,
                   Security => (if Use_Tls then Server_Context'Access else null));
      accept Finished;
   end Server_Task;

   procedure Await_Server is
      Socket  : Descriptor;
      Failure : Error;
   begin
      for Attempt in 1 .. 200 loop
         Connect (Loopback, Port, Socket, Failure);
         if Succeeded (Failure) then
            Close (Socket);
            return;
         end if;
         Sparrow.IO.Process.Sleep (10);
      end loop;
   end Await_Server;

   procedure Exchanges (Base : String; Using : Client.Settings; Mode : String) is
      Answer : Client.Response;
   begin
      Client.Get (Base & "/hello", Answer, Using => Using);
      Check (Client.Status (Answer) = 200 and then Client.Content (Answer) = "hello"
             and then Ada.Strings.Fixed.Index (Client.Header (Answer, "content-type"), "text/plain") = 1
             and then Client.Version (Answer) = 11,
             Mode & "GET, its status, content and a header in any case");

      declare
         Payload : constant String := [1 .. 100_000 => 'z'] & "end";
      begin
         Client.Post (Base & "/echo", Payload, Answer, Media_Type => "application/octet-stream", Using => Using);
         Check (Client.Status (Answer) = 200 and then Client.Content (Answer) = Payload, Mode & "POST 100 KB, echoed");
      end;

      Client.Send ("PUT", Base & "/echo", Answer, Content => "x", Using => Using);
      Check (Client.Status (Answer) = 405, Mode & "another method, answered 405 (not an error)");

      Client.Send ("HEAD", Base & "/hello", Answer, Using => Using);
      Check (Client.Status (Answer) = 200 and then Client.Content (Answer) = ""
             and then Client.Header (Answer, "Content-Length") = "5", Mode & "HEAD: the length, no content");

      Client.Get (Base & "/who/ada", Answer, Headers => "X-Extra: 1" & ASCII.LF & "Accept: text/plain",
                  Using => Using);
      Check (Client.Content (Answer) = "worker ada", Mode & "extra headers");

      Client.Get (Base & "/nowhere", Answer, Using => Using);
      Check (Client.Status (Answer) = 404, Mode & "404 is an answer");

      Client.Get (Base & "/moved", Answer, Using => Using);
      Check (Client.Status (Answer) = 303 and then Client.Header (Answer, "Location") = "/hello",
             Mode & "redirects are not followed by default");
      declare
         Following : Client.Settings := Using;
      begin
         Following.Follow_Redirects := True;
         Client.Get (Base & "/moved", Answer, Using => Following);
         Check (Client.Status (Answer) = 200 and then Client.Content (Answer) = "hello", Mode & "following one");
      end;

      declare
         Small : Client.Settings := Using;
      begin
         Small.Max_Response := 1000;
         Client.Post (Base & "/echo", [1 .. 5000 => 'q'], Answer, Using => Small);
         Check (False, Mode & "an answer past Max_Response raises");
      exception
         when Problem : Client.Request_Error =>
            Check (Ada.Strings.Fixed.Index (Ada.Exceptions.Exception_Message (Problem), "larger than") > 0,
                   Mode & "an answer past Max_Response raises");
      end;
   end Exchanges;

begin
   Check (Client.Url_Encode ("a b&c=d/é~") = "a%20b%26c%3Dd%2F%C3%A9~", "URL encoding");
   Check (Client.Form_Pair ("grant type", "x+y") = "grant%20type=x%2By", "a form pair");
   Url_Tests;
   Head_Tests;
   Refusal_Tests;
   Script_Tests;

   Routers.Add (Routes, Get, "/hello", Hello'Access, Routers.On_Reactor);
   Routers.Add (Routes, Post, "/echo", Echo'Access);
   Routers.Add (Routes, Get, "/who/:name", Who'Access);
   Routers.Add (Routes, Get, "/moved", Moved'Access);

   declare
      Plain : Server_Task;
   begin
      Plain.Start (Secure => False);
      Await_Server;
      Exchanges ("http://localhost:18477", Client.Default_Settings, "http: ");
      Servers.Stop;
      Plain.Finished;
   end;

   Sparrow.Tls.Open_Server (Server_Context, "data/cert.pem", "data/key.pem");
   declare
      Secure : Server_Task;
      Answer : Client.Response;
   begin
      Secure.Start (Secure => True);
      Await_Server;
      begin
         Client.Get ("https://localhost:18477/hello", Answer);
         Check (False, "https: a certificate the system does not trust is refused");
      exception
         when Client.Request_Error => Check (True, "https: a certificate the system does not trust is refused");
      end;
      begin
         Client.Get ("https://127.0.0.1:18477/hello", Answer,
                     Using => (Trust_File => new String'("data/cert.pem"), others => <>));
         Check (False, "https: an address the certificate does not name is refused");
      exception
         when Client.Request_Error => Check (True, "https: an address the certificate does not name is refused");
      end;
      Exchanges ("https://localhost:18477",
                 (Trust_File => new String'("data/cert.pem"), others => <>), "https: ");
      Servers.Stop;
      Secure.Finished;
   end;
   Sparrow.Tls.Close (Server_Context);
   Routers.Free (Routes);
   Finish ("client");
end Client_Tests;
