with Sparrow.Json;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Interfaces; use type Interfaces.Unsigned_8;
with Checks; use Checks;
with Log_Capture;
with Sparrow.Logs;
with Sparrow.Http.Log;
with Http_Test_Handlers; use Http_Test_Handlers;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Parser; use Sparrow.Http.Parser;
with Sparrow.Chunked; use type Sparrow.Chunked.Decoder_State;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Http.Routers;
with Sparrow.Http.Compression;
with Sparrow.Http.Cors;
with Sparrow.Http.Ranges;
with Sparrow.Http.Event_Streams;
with Sparrow.Http.Frames;
with Sparrow.Http.Limits;
with Sparrow.Http.Multipart;
with Sparrow.Http.Multipart_Scanning;
with Sparrow.Http.Route_Patterns;
with Sparrow.Http.Session_Envelope;
with Sparrow.Http.Sessions;
with Sparrow.Http.Servers;
with Sparrow.Http.Streams;
with Sparrow.Http.Websockets;
with Sparrow.Http.Static;
with Sparrow.IO; use Sparrow.IO;
with Sparrow.IO.Process;
with Sparrow.IO.Sockets; use Sparrow.IO.Sockets;
with Sparrow.Encoding;
with Sparrow.Tls;
with Zlib_Check;

procedure Http_Tests is
   use Sparrow;
   use type Routers.Placement;
   use type Tls.Outcome;

   function Contains (Text, Part : String) return Boolean is (Ada.Strings.Fixed.Index (Text, Part) > 0);

   --  OK for a complete head, 100 for an incomplete one, else the status it is refused with.
   function Status_Of (Request : String; Within_Limits : Parser.Limits := Default_Limits) return Status_Code is
      Head : constant Request_Head := Parse_Head (Request, Within_Limits);
   begin
      return (case Head.Outcome is when Complete => OK, when Incomplete => 100, when Invalid => Head.Status);
   end Status_Of;

   ---------------------------------------------------------------------------------------------------------------

   --  A chunked body decoded as it would arrive, Step bytes at a time: its bytes, or "!" and the status.
   function Decoded (Framed : String; Step : Positive := 1_000_000; Limit : Body_Size := 1000) return String is
      package Chunking renames Sparrow.Chunked;
      Chunks   : Chunking.Decoder := Chunking.New_Decoder (Limit, Max_Framing => 200);
      Result   : Buffer;
      First    : Positive := Framed'First;
      Position : Positive;
      Last     : Natural;
      Consumed : Natural;
      Part     : Encoding.Span;
   begin
      while First <= Framed'Last and then Chunks.State not in Chunking.Done | Chunking.Failed loop
         Last     := Natural'Min (Framed'Last, First + Step - 1);
         Position := First;
         while Position <= Last and then Chunks.State not in Chunking.Done | Chunking.Failed loop
            Chunking.Decode (Chunks, Framed (Position .. Last), Consumed, Part);
            Append (Result, Encoding.Slice (Framed, Part));
            Position := Position + Consumed;
         end loop;
         First := (if Chunks.State in Chunking.Done | Chunking.Failed then Position else Last + 1);
      end loop;
      return Text : constant String :=
        (case Chunks.State is
            when Chunking.Done   => Content (Result) & (if First <= Framed'Last then "+" & Framed (First .. Framed'Last)
                                        else ""),
            when Chunking.Failed => "!" & (if Chunks.Too_Large then " 413" else " 400"),
            when others => "?" & Content (Result))
      do
         Free (Result);
      end return;
   end Decoded;

   procedure Chunk_Tests is
      Framed : constant String :=
        "5" & CRLF & "hello" & CRLF & "6;name=value" & CRLF & " world" & CRLF & "0" & CRLF
        & "Trailer: x" & CRLF & CRLF;
   begin
      Equal (Decoded (Framed), "hello world", "chunked: sizes, an extension, a trailer");
      Equal (Decoded (Framed, Step => 1), "hello world", "chunked: the same a byte at a time");
      Equal (Decoded (Framed, Step => 7), "hello world", "chunked: seven bytes at a time");
      Equal (Decoded ("A" & CRLF & "0123456789" & CRLF & "0" & CRLF & CRLF), "0123456789", "chunked: hex sizes");
      Equal (Decoded ("0" & CRLF & CRLF & "GET"), "+GET", "chunked: what follows the body is left");
      Equal (Decoded ("5" & CRLF & "hel"), "?hel", "chunked: not finished");
      Equal (Decoded ("x" & CRLF), "! 400", "chunked: a size that is not hex");
      Equal (Decoded ("5" & CRLF & "helloX"), "! 400", "chunked: data longer than its size");
      Equal (Decoded ("5" & ASCII.LF & "hello"), "! 400", "chunked: a bare LF");
      Equal (Decoded ("3E9" & CRLF), "! 413", "chunked: a chunk past the limit");
      Equal (Decoded ("FFFFFFFFFFFFFFFFFFFF" & CRLF), "! 413", "chunked: a size that overflows");
      Equal (Decoded ("1F4" & CRLF & [1 .. 500 => 'a'] & CRLF & "1F4" & CRLF & [1 .. 500 => 'b'] & CRLF & "1"
                      & CRLF), "! 413", "chunked: chunks that add up past the limit");
      Equal (Decoded ("1;" & [1 .. 300 => 'e'] & CRLF), "! 413", "chunked: endless framing");
   end Chunk_Tests;

   procedure Parser_Tests is
      Simple : constant String :=
        "GET /a/b?x=1&y=two HTTP/1.1" & CRLF & "Host: h" & CRLF & "X-Thing:  spaced value  " & CRLF & CRLF;
      Head   : constant Request_Head := Parse_Head (Simple);
      Many   : Buffer;
   begin
      Check (Head.Outcome = Complete, "parse a simple GET");
      if Head.Outcome = Complete then
         Check (Head.Verb = Get and then Encoding.Slice (Simple, Head.Path) = "/a/b", "method and path");
         Check (Encoding.Slice (Simple, Head.Query) = "x=1&y=two", "query");
         Check (Encoding.Slice (Simple, Header_Value (Simple, Head, "x-thing")) = "spaced value", "trimmed header");
         Check (Head.Keep_Alive and then Head.Head_Length = Simple'Length and then Head.Header_Total = 2,
                "keep-alive by default, head length");
      end if;

      Check (Status_Of ("GET / HTTP/1.1" & CRLF & "Host: h" & CRLF) = 100, "incomplete head");
      Check (Status_Of ("GET / HTTP/1.0" & CRLF & CRLF) = OK, "HTTP/1.0 needs no Host");
      Check (Status_Of ("GET / HTTP/1.1" & CRLF & CRLF) = Bad_Request, "HTTP/1.1 without Host");
      Check (Status_Of ("GET / HTTP/1.1" & CRLF & "Host: a" & CRLF & "Host: b" & CRLF & CRLF) = Bad_Request,
             "two Host headers");
      Check (Status_Of ("GET / HTTP/1.1" & ASCII.LF & "Host: h" & CRLF & CRLF) = Bad_Request, "a bare LF");
      Check (Status_Of ("GET / HTTP/1.1" & CRLF & "Host : h" & CRLF & CRLF) = Bad_Request, "a blank before ':'");
      Check (Status_Of ("GET / HTTP/1.1" & CRLF & "Host: h" & CRLF & " folded" & CRLF & CRLF) = Bad_Request,
             "an obs-fold line");
      Check (Status_Of ("GET / HTTP/2.0" & CRLF & "Host: h" & CRLF & CRLF) = Bad_Request, "an unknown version");
      Check (Status_Of ("GET http://x/ HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF) = Bad_Request,
             "an absolute-form target");
      Check (Status_Of ("GET /a b HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF) = Bad_Request, "a blank in the target");
      declare
         Chunked : constant String :=
           "POST / HTTP/1.1" & CRLF & "Host: h" & CRLF & "Transfer-Encoding: chunked" & CRLF & CRLF;
         Head    : constant Request_Head := Parse_Head (Chunked);
      begin
         Check (Head.Outcome = Complete and then Head.Chunked and then Head.Body_Length = 0, "a chunked body");
      end;
      Check (Status_Of ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF & "Transfer-Encoding: gzip, chunked" & CRLF
                        & CRLF) = Not_Implemented, "other transfer codings are not implemented");
      Check (Status_Of ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF & "Transfer-Encoding: chunked" & CRLF
                        & "Content-Length: 5" & CRLF & CRLF) = Bad_Request
             and then Status_Of ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 5" & CRLF
                                 & "Transfer-Encoding: chunked" & CRLF & CRLF) = Bad_Request,
             "chunked with a length, either order: refused (request smuggling)");
      Check (Status_Of ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 2000000" & CRLF & CRLF,
                        (Max_Head_Length => 1000, Max_Body_Length => 1000, Max_Streamed_Length => 0))
             = Payload_Too_Large
             and then Status_Of ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 2000000" & CRLF
                                 & CRLF, (Max_Head_Length => 1000, Max_Body_Length => 1000,
                                          Max_Streamed_Length => 2_000_000)) = OK,
             "a length past both limits is refused; one a streamed route may take is not");
      Check (Status_Of ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 1" & CRLF
                        & "Content-Length: 2" & CRLF & CRLF) = Bad_Request, "two different lengths");
      Check (Status_Of ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: -1" & CRLF & CRLF)
             = Bad_Request, "a negative length");
      Check (Status_Of ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 99999999999999999999"
                        & CRLF & CRLF) = Payload_Too_Large, "a huge length");
      Check (Status_Of ("GET / HTTP/1.1" & CRLF & "Host: h" & CRLF & "X: a" & ASCII.NUL & "b" & CRLF & CRLF)
             = Bad_Request, "a control character in a value");
      Check (Status_Of ("GET /" & [1 .. 20_000 => 'a']) = Header_Fields_Too_Large, "an endless head");
      Check (Status_Of ("GET / HTTP/1.1" & CRLF & "Host: h" & CRLF & [1 .. 100 => 'b'] & ": c" & CRLF & CRLF,
                        (Max_Head_Length => 64, Max_Body_Length => 0, Max_Streamed_Length => 0))
             = Header_Fields_Too_Large,
             "a head over the limit");

      Append (Many, "GET / HTTP/1.1" & CRLF & "Host: h" & CRLF);
      for Index in 1 .. Max_Headers loop
         Append (Many, "X: y" & CRLF);
      end loop;
      Append (Many, CRLF);
      Check (Status_Of (Content (Many)) = Header_Fields_Too_Large, "too many headers");
      Free (Many);

      Chunk_Tests;
   end Parser_Tests;

   ---------------------------------------------------------------------------------------------------------------

   --  WebSocket frames, from RFC 6455 5.7.
   procedure Frame_Tests is
      use Sparrow.Http.Frames;

      Hello : constant String :=   --  a masked text frame, "Hello"
        ([Character'Val (16#81#), Character'Val (16#85#), Character'Val (16#37#), Character'Val (16#FA#),
                Character'Val (16#21#), Character'Val (16#3D#), Character'Val (16#7F#), Character'Val (16#9F#),
                Character'Val (16#4D#), Character'Val (16#51#), Character'Val (16#58#)]);
      Head  : constant Frame_Head := Read_Head (Hello, Largest => 1000);
   begin
      Check (Head.Outcome = Whole_Head and then Head.Final and then Head.Kind = Text
             and then Head.Payload_Length = 5 and then Total_Length (Head) = Hello'Length, "frame head");
      Equal (Unmasked (Hello, Head), "Hello", "frame payload unmasked");
      Check (Read_Head (Hello (1 .. 1), 1000).Outcome = Short, "one byte is short of a head");
      Check (Read_Head (Hello, Largest => 4) = (Outcome => Refused, Close_Code => 1009), "too big: 1009");
      Check (Read_Head ([Character'Val (16#81#), Character'Val (16#05#)], 1000)
             = (Outcome => Refused, Close_Code => 1002), "an unmasked client frame: 1002");
      Check (Read_Head ([Character'Val (16#09#), Character'Val (16#80#)], 1000)
             = (Outcome => Refused, Close_Code => 1002), "a fragmented ping: 1002");
      Check (Read_Head ([Character'Val (16#82#), Character'Val (16#FE#), Character'Val (1), Character'Val (0)], 1000)
             = (Outcome => Whole_Head, Final => True, Kind => Binary, Payload_First => 9, Payload_Length => 256),
             "a 16-bit length");
      Check (Read_Head (Character'Val (16#82#) & [1 .. 13 => Character'Val (16#FF#)], 1000)
             = (Outcome => Refused, Close_Code => 1009), "the largest 64-bit length: 1009, no overflow");
   end Frame_Tests;

   procedure Compression_And_Range_Tests is
      use Sparrow.Http.Compression;
      use Sparrow.Http.Ranges;

      function Parse_Of (Header : String; Size : Byte_Count := 1000) return Byte_Range renames Parse;
      Answer : Responses.Response;
   begin
      Check (Accepts_Gzip ("gzip") and then Accepts_Gzip ("GZIP") and then Accepts_Gzip ("deflate, gzip;q=0.5")
             and then Accepts_Gzip ("br;q=1.0, gzip ; q=0.1") and then Accepts_Gzip ("x-gzip")
             and then Accepts_Gzip ("*") and then Accepts_Gzip ("*;q=0.2, br"), "Accept-Encoding: gzip taken");
      Check (not Accepts_Gzip ("") and then not Accepts_Gzip ("identity") and then not Accepts_Gzip ("gzip;q=0")
             and then not Accepts_Gzip ("gzip; Q=0.000") and then not Accepts_Gzip ("br, *;q=0")
             and then not Accepts_Gzip ("gzip;q=0, *") and then not Accepts_Gzip ("gzipx, br")
             and then not Accepts_Gzip (",,;"), "Accept-Encoding: gzip refused");
      Check (Compressible ("text/html; charset=utf-8") and then Compressible ("application/json")
             and then Compressible ("application/problem+json") and then Compressible ("image/svg+xml")
             and then Compressible ("Text/CSS"), "compressible types");
      Check (not Compressible ("image/png") and then not Compressible ("text/event-stream")
             and then not Compressible ("") and then not Compressible ("application/octet-stream")
             and then not Compressible ("video/mp4"), "types left alone");

      Check (Parse_Of ("bytes=0-499") = (Part, 0, 499) and then Parse_Of ("bytes=500-") = (Part, 500, 999)
             and then Parse_Of ("BYTES=1-2") = (Part, 1, 2) and then Parse_Of (" bytes=7-7 ") = (Part, 7, 7),
             "ranges");
      Check (Parse_Of ("bytes=-100") = (Part, 900, 999) and then Parse_Of ("bytes=-5000") = (Part, 0, 999)
             and then Parse_Of ("bytes=900-5000") = (Part, 900, 999), "suffix ranges, and ends past the size");
      Check (Parse_Of ("bytes=1000-").Kind = Unsatisfiable and then Parse_Of ("bytes=-0").Kind = Unsatisfiable
             and then Parse_Of ("bytes=0-0", 0).Kind = Unsatisfiable
             and then Parse_Of ("bytes=99999999999999999999999-").Kind = Unsatisfiable, "unsatisfiable ranges");
      Check (Parse_Of ("bytes=5-1").Kind = Whole and then Parse_Of ("bytes=0-1,5-6").Kind = Whole
             and then Parse_Of ("items=0-1").Kind = Whole and then Parse_Of ("bytes=a-b").Kind = Whole
             and then Parse_Of ("bytes=").Kind = Whole and then Parse_Of ("bytes=-").Kind = Whole
             and then Parse_Of ("").Kind = Whole and then Parse_Of ("bytes=1-x").Kind = Whole,
             "ranges read as the whole: reversed, several, other units, malformed");

      Responses.Set_Header (Answer, "X-One", "a");
      Responses.Set_Header (Answer, "Content-Type", "  text/plain ");
      Responses.Set_Header (Answer, "X-One", "b");
      Equal (Responses.Header (Answer, "content-type"), "text/plain", "a response header, any case, trimmed");
      Equal (Responses.Header (Answer, "X-One"), "a", "the first of two");
      Responses.Remove_Header (Answer, "x-ONE");
      Check (Responses.Header (Answer, "X-One") = "" and then Responses.Header (Answer, "Content-Type") = "text/plain",
             "removing a header removes every line of it, and only those");
      Responses.Free (Answer);
   end Compression_And_Range_Tests;

   procedure Static_Tests is
      use Sparrow.Http.Static;
   begin
      Check (Is_Safe_Path ("index.html") and then Is_Safe_Path ("css/site.css") and then Is_Safe_Path ("a/b/c.v2.js"),
             "safe paths");
      Check (not Is_Safe_Path ("../etc/passwd") and then not Is_Safe_Path ("a/../../b")
             and then not Is_Safe_Path ("a/.."), "no way up");
      Check (not Is_Safe_Path ("/etc/passwd") and then not Is_Safe_Path ("c:/x") and then not Is_Safe_Path ("a\b"),
             "no absolute paths, drives or backslashes");
      Check (not Is_Safe_Path (".env") and then not Is_Safe_Path ("a/.git/config"), "no hidden files");
      Check (not Is_Safe_Path ("a//b") and then not Is_Safe_Path ("a/") and then not Is_Safe_Path (""),
             "no empty segments");
      Check (not Is_Safe_Path ("a" & ASCII.NUL & "b") and then not Is_Safe_Path ("a" & ASCII.LF), "no control bytes");
      Equal (Media_Type_Of ("site.CSS"), "text/css; charset=utf-8", "media type, any case");
      Equal (Media_Type_Of ("app.min.js"), "text/javascript; charset=utf-8", "media type, last extension");
      Equal (Media_Type_Of ("v1.2/README"), "application/octet-stream", "media type, no extension");
      Equal (Media_Type_Of ("logo.svg"), "image/svg+xml", "media type, svg");
   end Static_Tests;

   procedure Request_And_Router_Tests is
      Routes  : Routers.Router (8);   --  hides the server's
      Request : Requests.Request;
      Bytes   : Buffer;
      Valid   : Boolean;
      Found   : Routers.Route_Match;

      use type Routers.Route_Handler_Access;

      procedure Load (Raw : String) is begin
         Append (Bytes, Raw);
         Requests.Load (Request, Bytes, Valid);
      end Load;

      --  What the matched route's handler answers to the current request: which handler it is.
      function Answer_Of (Match : Routers.Route_Match) return String is
         Response : Responses.Response;
      begin
         if Match.Action = null then
            return "(none)";
         end if;
         Match.Action.Handle (Request, Response);
         return Result : constant String := Content (Response.Content) do
            Responses.Free (Response);
         end return;
      end Answer_Of;
   begin
      Routers.Add (Routes, Get, "/articles", Hello'Access, Routers.On_Reactor);
      Routers.Add (Routes, Get, "/articles/:slug/comments/:id", Hello'Access);
      Routers.Add (Routes, Post, "/articles/:slug", Echo'Access);
      Routers.Add (Routes, Get, "/static/*file", Hello'Access);

      begin
         Routers.Add (Routes, Get, "/a/:x/:x", Hello'Access);
         Check (False, "a repeated capture name is refused");
      exception
         when Routers.Invalid_Pattern => Check (True, "a repeated capture name is refused");
      end;
      begin
         Routers.Add (Routes, Get, "/a/*rest/b", Hello'Access);
         Check (False, "a '*' segment before the end is refused");
      exception
         when Routers.Invalid_Pattern => Check (True, "a '*' segment before the end is refused");
      end;
      begin
         Routers.Add (Routes, Get, "relative", Hello'Access);
         Check (False, "a pattern without '/' is refused");
      exception
         when Routers.Invalid_Pattern => Check (True, "a pattern without '/' is refused");
      end;

      Load ("GET /articles/hello%20world/comments/42?sort=new&q=a+b%21&flag HTTP/1.1" & CRLF & "Host: h" & CRLF
            & "Cookie: session=abc; theme=""dark""" & CRLF & CRLF);
      Check (Valid, "load a request");
      Routers.Find (Routes, Request, Found);
      Check (Found.Action /= null and then Found.Run = Routers.On_Worker, "route with captures");
      Equal (Requests.Parameter (Request, "slug"), "hello world", "capture, decoded");
      Equal (Requests.Parameter (Request, "id"), "42", "second capture");
      Equal (Requests.Query_Value (Request, "q"), "a b!", "query value, decoded");
      Check (Requests.Has_Query_Value (Request, "flag") and then not Requests.Has_Query_Value (Request, "nope"),
             "a query name without a value");
      Equal (Requests.Cookie (Request, "session"), "abc", "cookie");
      Equal (Requests.Cookie (Request, "theme"), "dark", "quoted cookie");
      Equal (Requests.Header (Request, "HOST"), "h", "header, any case");
      Check (Requests.Content (Request) = "", "no body");

      Load ("POST /articles/x HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 13" & CRLF & CRLF
            & "name=A+B&c=%3D");
      Check (not Valid, "a body shorter than its length is refused");
      Free (Bytes);
      Load ("POST /articles/x HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 14" & CRLF & CRLF
            & "name=A+B&c=%3D");
      Check (Valid, "load a request with a body");
      Equal (Requests.Form_Value (Request, "name"), "A B", "form value");
      Equal (Requests.Form_Value (Request, "c"), "=", "form value, decoded");
      Routers.Find (Routes, Request, Found);
      Check (Answer_Of (Found) = "name=A+B&c=%3D", "POST route");

      Load ("GET /static/css/site.css HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);
      Routers.Find (Routes, Request, Found);
      Equal (Requests.Parameter (Request, "file"), "css/site.css", "a '*' capture takes the rest");

      Load ("POST /articles/7 HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Type: Application/JSON; charset=utf-8"
            & CRLF & "Content-Length: 23" & CRLF & CRLF & "title=caf%C3%A9&bad=%FF");
      Routers.Find (Routes, Request, Found);
      Check (Requests.Has_Content_Type (Request, "application/json"), "content type, ignoring case and parameters");
      Check (not Requests.Has_Content_Type (Request, "application/js"), "content type, whole");
      Check (String (Requests.Form_Text (Request, "title")) = "caf" & Character'Val (16#C3#) & Character'Val (16#A9#),
             "form text, checked UTF-8");
      Check (String (Requests.Form_Text (Request, "bad", Default => "?")) = "?", "form text, not UTF-8: the default");
      Check (Requests.Integer_Parameter (Request, "slug") = 7, "integer capture");
      Check (Requests.Integer_Parameter (Request, "none", Default => -1) = -1, "integer capture, absent: the default");

      --  a JSON body, parsed into a document sized to it
      Load ("POST /articles/7 HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Type: application/json" & CRLF
            & "Content-Length: 38" & CRLF & CRLF & "{""a"": [1, 2, {""c"": true}], ""b"": ""x,y""}");
      declare
         Fields : constant Sparrow.Json.Document := Requests.Json_Body (Request);
      begin
         Check (Sparrow.Json.Is_Valid (Fields) and then Sparrow.Json.Length (Fields, "a") = 3
                and then Sparrow.Json.Boolean_Value (Fields, "a.2.c")
                and then String (Sparrow.Json.Text (Fields, "b")) = "x,y", "a JSON body");
      end;
      Load ("POST /articles/7 HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 5" & CRLF & CRLF & "[1, }");
      Check (not Sparrow.Json.Is_Valid (Requests.Json_Body (Request)), "a body that is not JSON");
      Load ("GET /articles/7 HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);
      Check (not Sparrow.Json.Is_Valid (Requests.Json_Body (Request)), "no body is not JSON");
      Check (Requests.Integer_Query (Request, "page", Default => 1) = 1, "integer query, absent: the default");

      Load ("DELETE /articles HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);
      Routers.Find (Routes, Request, Found);
      Check (Found.Action = null and then Found.Path_Matched, "the path under another method");

      Load ("HEAD /articles HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);
      Routers.Find (Routes, Request, Found);
      Check (Answer_Of (Found) = "hello" and then Found.Run = Routers.On_Reactor, "HEAD takes the GET route");

      Load ("GET /articles/x/comments HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);
      Routers.Find (Routes, Request, Found);
      Check (Found.Action = null and then not Found.Path_Matched, "no route");

      Load ("GET /articles//comments/1 HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);
      Routers.Find (Routes, Request, Found);
      Check (Found.Action = null, "a capture never matches an empty segment");

      Requests.Free (Request);
      Routers.Free (Routes);
   end Request_And_Router_Tests;

   ---------------------------------------------------------------------------------------------------------------

   --  The proved scanners, on what the client controls: malformed input is reported, never raised.
   procedure Scanner_Tests is
      use Sparrow.Encoding;
      package Patterns renames Sparrow.Http.Route_Patterns;
      package Scanning renames Sparrow.Http.Multipart_Scanning;
      package Envelope renames Sparrow.Http.Session_Envelope;
      use type Patterns.Problem;
      use type Scanning.Step_Kind;
   begin
      Check (Patterns.Check ("/a/:id/*rest") = Patterns.None, "a pattern with captures");
      Check (Patterns.Check ("a") = Patterns.No_Leading_Slash and then Patterns.Check ("") = Patterns.No_Leading_Slash,
             "a pattern without '/'");
      Check (Patterns.Check ("/a/:") = Patterns.Bad_Capture_Name
             and then Patterns.Check ("/:" & [1 .. 33 => 'n']) = Patterns.Bad_Capture_Name, "capture names 1 .. 32");
      Check (Patterns.Check ("/*a/b") = Patterns.Star_Not_Last, "'*' last");
      Check (Patterns.Check ("/:a/:b/:c/:d/:e/:f/:g/:h/:i") = Patterns.Too_Many_Captures, "at most 8 captures");
      Check (Patterns.Check ("/:a/x/:a") = Patterns.Repeated_Name, "no repeated name");
      Check (Patterns.Matches ("/a/:id", "/a/7") and then not Patterns.Matches ("/a/:id", "/a/")
             and then not Patterns.Matches ("/a/:id", "/a/7/8") and then Patterns.Matches ("/s/*f", "/s/")
             and then Patterns.Matches ("/s/*f", "/s/x/y") and then not Patterns.Matches ("/a", "a")
             and then not Patterns.Matches ("/a", ""), "matching");
      declare
         Pattern  : constant String := "/a/:id/*rest";
         Path     : constant String := "/a/7/x/y";
         Captures : Patterns.Capture_List;
         Count    : Natural;
      begin
         Patterns.Find_Captures (Pattern, Path, Captures, Count);
         Check (Count = 2 and then Slice (Pattern, Captures (1).Name) = "id"
                and then Slice (Path, Captures (1).Value) = "7" and then Slice (Pattern, Captures (2).Name) = "rest"
                and then Slice (Path, Captures (2).Value) = "x/y", "captures");
      end;

      declare
         Value : constant String := "form-data; NAME =""a b""; filename=C:\dir\f.txt ;x=1";
         Head  : constant String := "Content-Disposition: " & Value & CRLF & "content-type:  text/plain ";
         Found : constant Scanning.Part_Head := Scanning.Read_Head (Head);
      begin
         Check (Slice (Value, Scanning.Parameter (Value, "name")) = "a b"
                and then Slice (Value, Scanning.Parameter (Value, "x")) = "1"
                and then Length (Scanning.Parameter (Value, "none")) = 0, "header parameters");
         Check (Slice (Head, Found.Name) = "a b" and then Slice (Head, Found.File_Name) = "f.txt"
                and then Slice (Head, Found.Kind) = "text/plain", "a part's head");
         Check (Length (Scanning.Parameter ("a; name=""open", "name")) = 0, "an unclosed quote");
      end;
      declare
         Marker : constant String := "--b";
         Data   : constant String := "--b" & CRLF & "X: 1" & CRLF & CRLF & "body" & CRLF & "--b--";
         Next   : constant Scanning.Step := Scanning.Next_Part (Data, Marker, 1);
      begin
         Check (Next.Kind = Scanning.Part_Found and then Slice (Data, Next.Head) = "X: 1"
                and then Slice (Data, Next.Content) = "body"
                and then Scanning.Next_Part (Data, Marker, Next.Next).Kind = Scanning.Closed, "a part, then the end");
         Check (Scanning.Next_Part ("--b" & CRLF & "X: 1", Marker, 1).Kind = Scanning.Malformed
                and then Scanning.Next_Part ("--bx", Marker, 1).Kind = Scanning.Malformed
                and then Scanning.Next_Part ("--b" & CRLF & CRLF & "no end", Marker, 1).Kind = Scanning.Malformed,
                "parts that break off");
      end;

      declare
         type Text_Access is access constant String;
         Bad_Fields : constant array (1 .. 5) of Text_Access :=
           [new String'("9:ab"), new String'("x:a"), new String'(":a"), new String'("99999999999999999999:a"),
            new String'("3")];
         Token  : constant String := [1 .. Envelope.Token_Length => 't'];
         Good   : constant String := "1700000000" & ASCII.LF & Token & "1:a2:bc";
         Issued : Long_Long_Integer;
         Place  : Span;
         Next   : Positive;
         Field  : Span;
         Valid  : Boolean;
      begin
         Envelope.Read_Head (Good, Issued, Place, Next, Valid);
         Check (Valid and then Issued = 1_700_000_000 and then Slice (Good, Place) = Token, "an envelope's head");
         Envelope.Read_Field (Good, Next, Field, Valid);
         Check (Valid and then Slice (Good, Field) = "a", "its first field");
         Envelope.Read_Field (Good, Next, Field, Valid);
         Check (Valid and then Slice (Good, Field) = "bc" and then Next = Good'Last + 1, "its last field");
         Envelope.Read_Head ("-5" & ASCII.LF & Token, Issued, Place, Next, Valid);
         Check (not Valid, "a negative time");
         Envelope.Read_Head ("17" & ASCII.LF & "short", Issued, Place, Next, Valid);
         Check (not Valid, "a token cut short");
         for Bad of Bad_Fields loop
            Next := 1;
            Envelope.Read_Field (Bad.all, Next, Field, Valid);
            Check (not Valid, "a malformed field: " & Bad.all);
         end loop;
      end;
   end Scanner_Tests;

   procedure Response_Tests is
      Answer : Responses.Response;
      Head   : Buffer;
   begin
      Responses.Set_Header (Answer, "X-Bad", "a" & CRLF & "Injected: yes");
      Responses.Set_Header (Answer, "Bad Name", "x");
      Responses.Set_Header (Answer, "X-Good", "fine");
      Responses.Set_Cookie (Answer, "id", "abc", Max_Age => 60);
      Responses.Set_Cookie (Answer, "bad", "a;b");
      Responses.Send (Answer, Created, "made");
      Responses.Write_Head (Answer, Head, 784_111_777, Keep_Alive => False);
      declare
         Text : constant String := Content (Head);
      begin
         Check (Text'Length > 9 and then Text (1 .. 21) = "HTTP/1.1 201 Created" & ASCII.CR, "status line");
         Check (Contains (Text, "Date: Sun, 06 Nov 1994 08:49:37 GMT" & CRLF), "Date");
         Check (Contains (Text, "Content-Length: 4" & CRLF) and then Contains (Text, "Connection: close" & CRLF),
                "length and close");
         Check (Contains (Text, "X-Good: fine" & CRLF) and then not Contains (Text, "Injected")
                and then not Contains (Text, "Bad Name"), "header injection is dropped");
         Check (Contains (Text, "Set-Cookie: id=abc; Path=/; Max-Age=60; HttpOnly; Secure; SameSite=Lax" & CRLF)
                and then not Contains (Text, "bad="), "cookies");
         Check (Text (Text'Last - 3 .. Text'Last) = CRLF & CRLF, "ends with a blank line");
      end;

      Responses.Clear (Answer);
      Clear (Head);
      Answer.Status := No_Content;
      Responses.Write_Head (Answer, Head, 0, Keep_Alive => True);
      Check (not Contains (Content (Head), "Content-Length"), "204 has no length");
      Free (Head);
      Responses.Free (Answer);
   end Response_Tests;

   ---------------------------------------------------------------------------------------------------------------
   --  Sessions, CSRF, CORS and multipart, on requests parsed from text.

   procedure Limit_Tests is
      Allowed     : Boolean;
      Retry_After : Natural;

      function Takes (Rule : Sparrow.Http.Limits.Limit; Key : String) return Boolean is begin
         Sparrow.Http.Limits.Take (Rule, Key, Allowed, Retry_After);
         return Allowed;
      end Takes;

      Slow  : constant Sparrow.Http.Limits.Limit := Sparrow.Http.Limits.Per_Key (0.001, 3, Key => Any_Key'Access);
      Quick : constant Sparrow.Http.Limits.Limit := Sparrow.Http.Limits.Per_Key (50.0, 1, Key => Any_Key'Access);
      Small : constant Sparrow.Http.Limits.Limit :=
        Sparrow.Http.Limits.Per_Key (0.001, 1, Key => Any_Key'Access, Max_Keys => 16);
   begin
      Check (Takes (Slow, "a") and then Takes (Slow, "a") and then Takes (Slow, "a"), "limit: a burst of three");
      Check (not Takes (Slow, "a") and then Retry_After = 1000, "limit: the fourth waits, told how long");
      Check (Takes (Slow, "b"), "limit: keys have their own buckets");
      Check (Takes (Quick, "a") and then not Takes (Quick, "a"), "limit: an empty bucket");
      Sparrow.IO.Process.Sleep (40);
      Check (Takes (Quick, "a"), "limit: refilled at its rate");
      Check (Takes (Small, "a") and then not Takes (Small, "a"), "limit: one key spent");
      for Index in 1 .. 2000 loop
         Allowed := Takes (Small, "k" & Index'Image);
      end loop;
      Check (Takes (Small, "a"), "limit: past Max_Keys, the least recently used bucket is forgotten");
   end Limit_Tests;

   procedure Helper_Tests is
      Visits    : constant Sessions.Store := Sessions.Cookie_Store (Secret => [1 .. 32 => 's']);
      Other_Key : constant Sessions.Store := Sessions.Cookie_Store (Secret => [1 .. 32 => 't']);
      Rotated   : constant Sessions.Store :=
        Sessions.Cookie_Store (Secret => [1 .. 32 => 't'], Previous_Secret => [1 .. 32 => 's']);
      Table     : aliased Sessions.Memory_Table;
      Kept      : constant Sessions.Store := Sessions.Table_Store (Table'Unchecked_Access);
      Shared    : constant Cors.Policy :=
        Cors.Allow ("https://app.example https://admin.example", Credentials => True, Exposed => "X-Total");

      function Get_Text (Path : String; Extra : String := "") return String is
        ("GET " & Path & " HTTP/1.1" & CRLF & "Host: localhost" & CRLF & Extra & CRLF);

      Request : Requests.Request;
      Bytes   : Buffer;
      Valid   : Boolean;

      procedure Load (Raw : String) is begin
         Requests.Free (Request);
         Clear (Bytes);
         Append (Bytes, Raw);
         Requests.Load (Request, Bytes, Valid);
         Check (Valid, "a test request parses");
      end Load;

      --  The head Response would send.
      function Head_Of (Response : in out Responses.Response) return String is
         Head : Buffer;
      begin
         Responses.Write_Head (Response, Head, 0, Keep_Alive => True);
         return Text : constant String := Content (Head) do
            Free (Head);
         end return;
      end Head_Of;

      --  The value of the session cookie a response sets; "" for none.
      function Cookie_Set (Head : String) return String is
         First : constant Natural := Ada.Strings.Fixed.Index (Head, "Set-Cookie: session=");
      begin
         if First = 0 then
            return "";
         end if;
         return Head (First + 20 .. Ada.Strings.Fixed.Index (Head (First .. Head'Last), ";") - 1);
      end Cookie_Set;

      Cookie : Buffer;
      Token  : String (1 .. 24);
   begin
      --  Sessions: a new one, saved, comes back with its values and token.
      Load (Get_Text ("/"));
      declare
         Session  : Sessions.Session := Visits.Load (Request);
         Response : Responses.Response;
      begin
         Check (not Sessions.Has (Session, "user") and then Sessions.Csrf_Token (Session)'Length = 24,
                "a new session is empty and has a token");
         Sessions.Set (Session, "user", "42");
         Sessions.Set (Session, "name", "Zoë" & ASCII.LF & "x:9:y");
         Visits.Save (Session, Response);
         declare
            Head : constant String := Head_Of (Response);
         begin
            Append (Cookie, Cookie_Set (Head));
            Check (Cookie.Length > 0 and then Contains (Head, "HttpOnly; Secure; SameSite=Lax"),
                   "saving a changed session sets its cookie");
         end;
         Token := Sessions.Csrf_Token (Session);
         Check (not Contains (Content (Cookie), "user"), "the cookie does not show the session");
         Responses.Free (Response);
      end;
      Load (Get_Text ("/", "Cookie: theme=dark; session=" & Content (Cookie) & CRLF));
      declare
         Session  : Sessions.Session := Visits.Load (Request);
         Response : Responses.Response;
      begin
         Check (Sessions.Get (Session, "user") = "42"
                and then Sessions.Get (Session, "name") = "Zoë" & ASCII.LF & "x:9:y"
                and then Sessions.Csrf_Token (Session) = Token, "a session survives the round trip");
         Visits.Save (Session, Response);
         Check (Cookie_Set (Head_Of (Response)) = "", "an unchanged, fresh session is not sent again");
         Responses.Free (Response);
      end;
      Load (Get_Text ("/", "Cookie: session=" & Content (Cookie) & CRLF));
      Check (not Sessions.Has (Other_Key.Load (Request), "user"), "another key cannot open the session");
      declare
         Forged : String := Content (Cookie);
      begin
         Forged (Forged'Last - 3) := (if Forged (Forged'Last - 3) = 'A' then 'B' else 'A');
         Load (Get_Text ("/", "Cookie: session=" & Forged & CRLF));
         Check (not Sessions.Has (Visits.Load (Request), "user"), "a changed cookie is refused");
      end;
      Load (Get_Text ("/", "Cookie: session=!!!not-base64" & CRLF));
      Check (not Sessions.Has (Visits.Load (Request), "user"), "a garbage cookie gives a new session");

      --  CSRF: header or form field, and only this session's token.
      Load (Get_Text ("/", "Cookie: session=" & Content (Cookie) & CRLF & "X-CSRF-Token: " & Token & CRLF));
      Check (Sessions.Csrf_Valid (Visits.Load (Request), Request), "CSRF token in the header");
      Load ("POST / HTTP/1.1" & CRLF & "Host: x" & CRLF & "Cookie: session=" & Content (Cookie) & CRLF
            & "Content-Type: application/x-www-form-urlencoded" & CRLF & "Content-Length: 35" & CRLF & CRLF
            & "csrf_token=" & Token);
      Check (Sessions.Csrf_Valid (Visits.Load (Request), Request), "CSRF token in the form");
      Load (Get_Text ("/", "Cookie: session=" & Content (Cookie) & CRLF & "X-CSRF-Token: " & [1 .. 24 => 'A'] & CRLF));
      Check (not Sessions.Csrf_Valid (Visits.Load (Request), Request), "a wrong CSRF token");
      Load (Get_Text ("/", "X-CSRF-Token: " & Token & CRLF));
      Check (not Sessions.Csrf_Valid (Visits.Load (Request), Request), "a token without its session");
      declare
         Session : Sessions.Session := Visits.Load (Request);
         Before  : constant String := Sessions.Csrf_Token (Session);
      begin
         Sessions.Set (Session, "user", "1");
         Sessions.Renew (Session);
         Check (Sessions.Csrf_Token (Session) /= Before and then Sessions.Has (Session, "user"),
                "renewing draws a new token and keeps the values");
         Sessions.Clear (Session);
         Check (not Sessions.Has (Session, "user"), "clearing forgets the values");
         Check (Contains (Sessions.Csrf_Field (Session), "name=""csrf_token"" value="""
                                                     & Sessions.Csrf_Token (Session) & """"), "the CSRF field");
         Sessions.Set (Session, "user", "1");
         Sessions.Set_Generation (Session, 3);
         Sessions.Check_Generation (Session, 3);
         Check (Sessions.Get (Session, "user") = "1" and then Sessions.Generation (Session) = 3,
                "a session of the current generation stays");
         Sessions.Check_Generation (Session, 4);
         Check (not Sessions.Has (Session, "user"), "a session of an older generation is logged out");
      end;

      --  Rotating the secret: a cookie sealed with the previous one is read, and sealed again.
      Load (Get_Text ("/", "Cookie: session=" & Content (Cookie) & CRLF));
      declare
         Session  : Sessions.Session := Rotated.Load (Request);
         Response : Responses.Response;
      begin
         Check (Sessions.Get (Session, "user") = "42", "a session sealed with the previous secret is read");
         Rotated.Save (Session, Response);
         declare
            Again : constant String := Cookie_Set (Head_Of (Response));
         begin
            Load (Get_Text ("/", "Cookie: session=" & Again & CRLF));
            Check (Again /= "" and then Sessions.Get (Other_Key.Load (Request), "user") = "42",
                   "and sealed again with the new one");
         end;
         Responses.Free (Response);
      end;
      Check (not Sessions.Has (Rotated.Load (Request), "nothing"), "rotation: a session with no values");

      --  A table store: the cookie is only an id.
      declare
         First_Id, Second_Id : Buffer;

         --  Saves Session; the cookie set, if any.
         function Saved (Session : in out Sessions.Session) return String is
            Response : Responses.Response;
         begin
            Kept.Save (Session, Response);
            return Result : constant String := Cookie_Set (Head_Of (Response)) do
               Responses.Free (Response);
            end return;
         end Saved;

         function Loaded (Id : String) return Sessions.Session is begin
            Load (Get_Text ("/", "Cookie: session=" & Id & CRLF));
            return Kept.Load (Request);
         end Loaded;
      begin
         Load (Get_Text ("/"));
         declare
            Session : Sessions.Session := Kept.Load (Request);
         begin
            Sessions.Set (Session, "user", "7");
            Sessions.Set (Session, "cart", "3 apples");
            Append (First_Id, Saved (Session));
            Check (First_Id.Length = 43 and then not Contains (Content (First_Id), "apples")
                   and then Sessions.Count (Table) = 1, "table: the cookie holds a random id");
         end;
         declare
            Session : Sessions.Session := Loaded (Content (First_Id));
         begin
            Check (Sessions.Get (Session, "cart") = "3 apples", "table: the session comes back by its id");
            Check (Saved (Session) = "", "table: an unchanged session is not written again");
            Sessions.Renew (Session);
            Append (Second_Id, Saved (Session));
            Check (Second_Id.Length = 43 and then Content (Second_Id) /= Content (First_Id)
                   and then Sessions.Count (Table) = 1, "table: renewing moves the session to a new id");
         end;
         Check (not Sessions.Has (Loaded (Content (First_Id)), "user")
                and then Sessions.Get (Loaded (Content (Second_Id)), "cart") = "3 apples",
                "table: the old id is gone");
         Check (not Sessions.Has (Loaded ([1 .. 43 => 'A']), "user") and then not Sessions.Has (Loaded ("x"), "user"),
                "table: an unknown id gives a new session");
         declare
            Other   : Sessions.Session := Loaded ("");
            Another : Sessions.Session := Loaded ("");
         begin
            Sessions.Set (Other, "user", "7");
            Sessions.Set (Another, "user", "8");
            Clear (First_Id);
            Append (First_Id, Saved (Other));
            Clear (First_Id);
            Append (First_Id, Saved (Another));
         end;
         Check (Sessions.Count (Table) = 3, "table: three sessions, two of user 7");
         Kept.Revoke_User ("7");
         Check (Sessions.Count (Table) = 1 and then not Sessions.Has (Loaded (Content (Second_Id)), "user")
                and then Sessions.Get (Loaded (Content (First_Id)), "user") = "8",
                "table: Revoke_User ends every session of that user, and only those");
         begin
            Visits.Revoke_User ("7");
            Check (False, "a cookie store cannot revoke");
         exception
            when Program_Error =>
               Check (True, "a cookie store cannot revoke");
         end;
         Free (First_Id);
         Free (Second_Id);
      end;

      --  CORS.
      Load (Get_Text ("/api", "Origin: https://app.example" & CRLF));
      declare
         Response : Responses.Response;
      begin
         Shared.Apply (Request, Response);
         declare
            Head : constant String := Head_Of (Response);
         begin
            Check (Contains (Head, "Access-Control-Allow-Origin: https://app.example" & CRLF)
                   and then Contains (Head, "Access-Control-Allow-Credentials: true" & CRLF)
                   and then Contains (Head, "Access-Control-Expose-Headers: X-Total" & CRLF)
                   and then Contains (Head, "Vary: Origin" & CRLF), "CORS: a listed origin may read");
         end;
         Responses.Free (Response);
      end;
      Load (Get_Text ("/api", "Origin: https://app.example.evil" & CRLF));
      declare
         Response : Responses.Response;
      begin
         Shared.Apply (Request, Response);
         Check (not Contains (Head_Of (Response), "Access-Control"), "CORS: other origins get nothing");
         Responses.Free (Response);
      end;
      Load ("OPTIONS /api/items HTTP/1.1" & CRLF & "Host: x" & CRLF & "Origin: https://admin.example" & CRLF
            & "Access-Control-Request-Method: DELETE" & CRLF & CRLF);
      declare
         Response : Responses.Response;
      begin
         Cors.Preflight (Shared).Handle (Request, Response);
         declare
            Head : constant String := Head_Of (Response);
         begin
            Check (Contains (Head, " 204 ") and then Contains (Head, "Access-Control-Allow-Methods: GET, POST")
                   and then Contains (Head, "Access-Control-Max-Age: 600" & CRLF), "CORS preflight");
         end;
         Responses.Free (Response);
      end;
      Check (Cors.Listed ("https://b.example", "*") and then not Cors.Listed ("", "*")
             and then not Cors.Listed ("https://B.example", "https://b.example"), "CORS origin lists");

      --  Multipart.
      declare
         Body_Text : constant String :=
           "preamble" & CRLF
           & "--XyZ" & CRLF
           & "Content-Disposition: form-data; name=""title""" & CRLF & CRLF
           & "Holiday" & CRLF
           & "--XyZ" & CRLF
           & "Content-Disposition: form-data; name=""photo""; filename=""C:\pics\beach.png""" & CRLF
           & "Content-Type: image/png" & CRLF & CRLF
           & "PNG" & CRLF & "--X not the end" & CRLF
           & "--XyZ" & CRLF
           & "Content-Disposition: form-data; name=""empty""; filename=""""" & CRLF
           & "Content-Type: application/octet-stream" & CRLF & CRLF
           & CRLF
           & "--XyZ--" & CRLF;
         Upload : Multipart.Form;
      begin
         Load ("POST /up HTTP/1.1" & CRLF & "Host: x" & CRLF
               & "Content-Type: multipart/form-data; boundary=XyZ" & CRLF
               & "Content-Length:" & Body_Text'Length'Image & CRLF & CRLF & Body_Text);
         Multipart.Parse (Request, Upload, Valid);
         Check (Valid and then Multipart.Part_Count (Upload) = 3, "multipart: three parts");
         Check (Multipart.Field (Upload, "title") = "Holiday" and then Multipart.Field (Upload, "photo") = ""
                and then Multipart.Field (Upload, "none", "?") = "?", "multipart: fields");
         Check (Multipart.Has_File (Upload, "photo") and then not Multipart.Has_File (Upload, "empty")
                and then Multipart.File_Name (Upload, 2) = "beach.png"
                and then Multipart.Content_Type (Upload, 2) = "image/png"
                and then Multipart.Content (Upload, 2) = "PNG" & CRLF & "--X not the end",
                "multipart: a file part, its name without directories");
         Multipart.Save (Upload, "photo", "obj/upload.bin");
         declare
            use Ada.Streams.Stream_IO;
            File : File_Type;
         begin
            Open (File, In_File, "obj/upload.bin");
            Check (Size (File) = 20, "multipart: saved to a file");
            Delete (File);
         end;
         Check (Multipart.Boundary_Of ("multipart/form-data; boundary=""a b""") = "a b",
                "multipart: a quoted boundary");

         Load ("POST /up HTTP/1.1" & CRLF & "Host: x" & CRLF
               & "Content-Type: multipart/form-data; boundary=XyZ" & CRLF & "Content-Length: 39" & CRLF & CRLF
               & "--XyZ" & CRLF & "Content-Disposition: form-data; ");
         Multipart.Parse (Request, Upload, Valid);
         Check (not Valid, "multipart: a cut-off body is refused");
         Load (Get_Text ("/"));
         Multipart.Parse (Request, Upload, Valid);
         Check (not Valid, "multipart: not multipart");
      end;

      Requests.Free (Request);
      Free (Bytes);
      Free (Cookie);
   end Helper_Tests;

   ---------------------------------------------------------------------------------------------------------------
   --  A live server, spoken to over a socket.

   Port : constant Port_Number := 18_475;

   type Client is limited record
      Socket  : Descriptor := No_Descriptor;
      Channel : Tls.Session;
      Pending : Buffer;   --  received and not yet returned
   end record;

   Trust : Tls.Context;

   procedure Open (This : in out Client; Secure : Boolean := False) is
      Failure : Error;
      Result  : Tls.Outcome;
   begin
      Connect (Loopback, Port, This.Socket, Failure, Timeout => 5000);
      if Secure and then Succeeded (Failure) then
         Tls.Start_Client (This.Channel, Trust, Tls.Socket_Handle (This.Socket), "localhost");
         Tls.Handshake (This.Channel, Result);
         Check (Result = Tls.Done, "client handshake: " & Tls.Last_Failure (This.Channel));
      end if;
   end Open;

   procedure Close (This : in out Client) is begin
      Tls.Free (This.Channel);
      Close (This.Socket);
      This.Socket := No_Descriptor;
      Free (This.Pending);
   end Close;

   procedure Send (This : in out Client; Data : String) is
      Count   : Integer;
      Done    : Natural;
      Result  : Tls.Outcome;
      Failure : Error;
      Sent    : Natural := 0;
   begin
      while Sent < Data'Length loop   --  a send may take only part (TLS: one record)
         if Tls.Is_Active (This.Channel) then
            Tls.Send (This.Channel, Data (Data'First + Sent .. Data'Last), Done, Result);
            exit when Result /= Tls.Done;
            Sent := Sent + Done;
         else
            Send (This.Socket, Data (Data'First + Sent .. Data'Last), Count, Failure);
            exit when Count <= 0;
            Sent := Sent + Count;
         end if;
      end loop;
   end Send;

   --  More bytes into Pending; False at the end of the stream (or after the 5 s timeout).
   function Receive_More (This : in out Client) return Boolean is
      Into    : String (1 .. 65_536);
      Count   : Integer;
      Done    : Natural;
      Result  : Tls.Outcome;
      Failure : Error;
   begin
      if Tls.Is_Active (This.Channel) then
         Tls.Receive (This.Channel, Into, Done, Result);
         Count := (if Result = Tls.Done then Done else 0);
      else
         Receive (This.Socket, Into, Count, Failure);
      end if;
      if Count > 0 then
         Append (This.Pending, Into (1 .. Count));
      end if;
      return Count > 0;
   end Receive_More;

   --  The next whole response (head and Content-Length body); "" if the connection ended first.
   function Next_Response (This : in out Client; No_Body : Boolean := False) return String is
   begin
      loop
         declare
            Text     : constant String := Content (This.Pending);
            Head_End : constant Natural := Ada.Strings.Fixed.Index (Text, CRLF & CRLF);
         begin
            if Head_End > 0 then
               declare
                  Length_At : constant Natural :=
                    Ada.Strings.Fixed.Index (Text (1 .. Head_End), "Content-Length: ");
                  Length    : Natural := 0;
                  Position  : Natural;
               begin
                  if Length_At > 0 and then not No_Body then
                     Position := Length_At + 16;
                     while Text (Position) in '0' .. '9' loop
                        Length   := Length * 10 + Character'Pos (Text (Position)) - Character'Pos ('0');
                        Position := Position + 1;
                     end loop;
                  end if;
                  if Text'Length >= Head_End + 3 + Length then
                     Consume (This.Pending, Head_End + 3 + Length);
                     return Text (1 .. Head_End + 3 + Length);
                  end if;
               end;
            end if;
         end;
         if not Receive_More (This) then
            return "";
         end if;
      end loop;
   end Next_Response;

   function Exchange (This : in out Client; Request : String) return String is begin
      Send (This, Request);
      return Next_Response (This);
   end Exchange;

   function Body_Of (Response : String) return String is
      Head_End : constant Natural := Ada.Strings.Fixed.Index (Response, CRLF & CRLF);
   begin
      return (if Head_End = 0 then "" else Response (Head_End + 4 .. Response'Last));
   end Body_Of;

   function Get (Path : String; Extra : String := "") return String is
     ("GET " & Path & " HTTP/1.1" & CRLF & "Host: localhost" & CRLF & Extra & CRLF);

   Routes : Routers.Router (28);

   Server_Context : aliased Tls.Context;

   task type Server_Task is
      entry Start (Secure : Boolean);
      entry Finished (Problem : out Boolean);
   end Server_Task;

   task body Server_Task is
      Use_Tls : Boolean;
      Failed  : Boolean := False;
   begin
      accept Start (Secure : Boolean) do
         Use_Tls := Secure;
      end Start;
      begin
         Servers.Run (Settings => (Port => Port, Reactors => 2, Workers => 3, Idle_Timeout => 2_000,
                                   Catch_Signals => False, Behind_Proxy => True, others => <>),
                      Routes   => Routes,
                      Hooks    => (On_Start => Count_Start'Access, On_Stop => Count_Stop'Access),
                      Security => (if Use_Tls then Server_Context'Access else null));
      exception
         when others =>
            Failed := True;
      end;
      accept Finished (Problem : out Boolean) do
         Problem := Failed;
      end Finished;
   end Server_Task;

   --  Wait until something listens on Port.
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

   function Image (Value : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Left));

   --  Chunked and streamed request bodies; Web is open, and left open.
   procedure Body_Tests (Web : in out Client; Mode : String) is
      Post_Head : constant String := " HTTP/1.1" & CRLF & "Host: h" & CRLF;
      Chunked   : constant String := "Transfer-Encoding: chunked" & CRLF & CRLF;

      --  Size bytes of a pattern, and what Upload_Sum answers for them.
      function Pattern (Size : Natural) return String_Access is
         Bytes : constant String_Access := new String (1 .. Size);
      begin
         for Index in Bytes'Range loop
            Bytes (Index) := Character'Val (Index mod 251);
         end loop;
         return Bytes;
      end Pattern;

      function Summary (Bytes : String) return String is
         Sum : Long_Long_Integer := 0;
      begin
         for Byte of Bytes loop
            Sum := Sum + Character'Pos (Byte);
         end loop;
         return Image (Bytes'Length) & " " & Image (Sum);
      end Summary;

      Payload : String_Access := Pattern (3_000_000);
      Errors  : constant Natural := Body_Errors.Total;
   begin
      --  Chunked, buffered: decoded before the handler runs.
      Send (Web, "POST /echo" & Post_Head & Chunked & "5" & CRLF & "hello" & CRLF & "6;x=y" & CRLF & " world" & CRLF
                 & "0" & CRLF & "T: 1" & CRLF & CRLF & Get ("/hello"));
      Equal (Body_Of (Next_Response (Web)), "hello world", Mode & "a chunked body, decoded");
      Equal (Body_Of (Next_Response (Web)), "hello", Mode & "and the request pipelined after it");
      Send (Web, "POST /echo" & Post_Head & Chunked);
      for Part in 0 .. 2 loop
         Send (Web, "186A0" & CRLF & Payload (Part * 100_000 + 1 .. Part * 100_000 + 100_000) & CRLF);
      end loop;
      Send (Web, "0" & CRLF & CRLF);
      Check (Body_Of (Next_Response (Web)) = Payload (1 .. 300_000), Mode & "a 300 kB chunked body");

      --  Streamed: the handler reads 3 MB 4 KiB at a time, more slowly than it comes.
      Send (Web, "POST /upload" & Post_Head & "Content-Length: 3000000" & CRLF & CRLF);
      Send (Web, Payload.all);
      Equal (Body_Of (Next_Response (Web)), Summary (Payload.all), Mode & "a 3 MB streamed body");
      Send (Web, "POST /upload" & Post_Head & Chunked);
      for Part in 0 .. 15 loop
         Send (Web, "10000" & CRLF & Payload (Part * 65_536 + 1 .. Part * 65_536 + 65_536) & CRLF);
      end loop;
      Send (Web, "0" & CRLF & CRLF);
      Equal (Body_Of (Next_Response (Web)), Summary (Payload (1 .. 1_048_576)), Mode & "a 1 MB chunked stream");
      Equal (Body_Of (Exchange (Web, "POST /upload" & Post_Head & "Content-Length: 0" & CRLF & CRLF)), "0 0",
             Mode & "a streamed route with no body");
      Send (Web, "POST /upload" & Post_Head & "Content-Length: 5" & CRLF & "Expect: 100-continue" & CRLF & CRLF);
      Check (Contains (Next_Response (Web, No_Body => True), "100 Continue"), Mode & "100 Continue, streamed");
      Send (Web, "abcde");
      Equal (Body_Of (Next_Response (Web)), "5 495", Mode & "the streamed body after 100 Continue");
      Equal (Body_Of (Exchange (Web, Get ("/hello"))), "hello", Mode & "the connection carries on after them");

      --  A multipart upload written to disk as it arrives.
      declare
         Boundary : constant String := "BoUnDaRy42";
         Form_Type : constant String := "Content-Type: multipart/form-data; boundary=" & Boundary & CRLF;
         Before   : constant String :=
           "--" & Boundary & CRLF & "Content-Disposition: form-data; name=""title""" & CRLF & CRLF & "Holiday"
           & CRLF & "--" & Boundary & CRLF
           & "Content-Disposition: form-data; name=""file""; filename=""../a.bin""" & CRLF
           & "Content-Type: application/octet-stream" & CRLF & CRLF;
         After    : constant String :=
           CRLF & "--" & Boundary & CRLF & "Content-Disposition: form-data; name=""other""; filename=""b.bin"""
           & CRLF & CRLF & "x" & CRLF & "--BoUnDa" & CRLF & "--" & Boundary & "--" & CRLF;
         Total    : constant Natural := Before'Length + 1_000_000 + After'Length;

         --  The files Save_Stream left in obj/.
         function Leftovers return Natural is
            use Ada.Directories;
            Search : Search_Type;
            Item   : Directory_Entry_Type;
            Count  : Natural := 0;
         begin
            Start_Search (Search, "obj", "upload-*", [Ordinary_File => True, others => False]);
            while More_Entries (Search) loop
               Get_Next_Entry (Search, Item);
               if Simple_Name (Item) /= "upload-moved.bin" then
                  Count := Count + 1;
               end if;
            end loop;
            End_Search (Search);
            return Count;
         end Leftovers;
      begin
         Send (Web, "POST /upload-form" & Post_Head & Form_Type & "Content-Length:" & Total'Image & CRLF & CRLF
                    & Before);
         Send (Web, Payload (1 .. 500_000));
         Send (Web, Payload (500_001 .. 1_000_000) & After);
         Equal (Body_Of (Next_Response (Web)), "Holiday 3 1000000 a.bin", Mode & "Save_Stream: fields and files");
         declare
            use Ada.Streams.Stream_IO;
            File  : File_Type;
            Saved : String (1 .. 1_000_000);
         begin
            Open (File, In_File, "obj/upload-moved.bin");
            String'Read (Stream (File), Saved);
            Check (Size (File) = 1_000_000 and then Saved = Payload (1 .. 1_000_000),
                   Mode & "Save_Stream: the file whole, moved by Save");
            Delete (File);
         end;
         Check (Leftovers = 0, Mode & "Save_Stream: Discard deletes the files not moved");
         declare
            Long_Field : constant String :=
              "--" & Boundary & CRLF & "Content-Disposition: form-data; name=""file""; filename=""c""" & CRLF
              & CRLF & "abc" & CRLF & "--" & Boundary & CRLF & "Content-Disposition: form-data; name=""title"""
              & CRLF & CRLF & [1 .. 200 => 't'] & CRLF & "--" & Boundary & "--" & CRLF;
         begin
            Check (Contains (Exchange (Web, "POST /upload-form" & Post_Head & Form_Type & "Content-Length:"
                                            & Long_Field'Length'Image & CRLF & CRLF & Long_Field), " 400 ")
                   and then Leftovers = 0, Mode & "Save_Stream: a field too long; the files written are deleted");
         end;
      end;
      Free (Payload);

      --  Bodies that end early or run long.
      Close (Web);
      Open (Web, Mode = "https: ");
      Send (Web, "POST /upload-part" & Post_Head & "Content-Length: 1000" & CRLF & CRLF & "0123456789abcdef");
      declare
         Answer : constant String := Next_Response (Web);
      begin
         Check (Body_Of (Answer) = "part 0123456789" and then Contains (Answer, "Connection: close")
                and then not Receive_More (Web), Mode & "a handler that reads part: answered, then closed");
      end;
      Close (Web);
      Open (Web, Mode = "https: ");
      declare
         Answer : constant String :=
           Exchange (Web, "POST /upload-all" & Post_Head & "Content-Length: 2000" & CRLF & CRLF
                          & [1 .. 2000 => 'q']);
      begin
         Check (Contains (Answer, " 413 ") and then Body_Errors.Total = Errors + 1,
                Mode & "Read_All past its limit raises Body_Error");
      end;
      Close (Web);
      Open (Web, Mode = "https: ");
      Send (Web, "POST /upload" & Post_Head & "Content-Length: 1000000" & CRLF & CRLF & [1 .. 1000 => 'r']);
      Sparrow.IO.Process.Sleep (100);
      Close (Web);
      for Attempt in 1 .. 100 loop
         exit when Body_Errors.Total = Errors + 2;
         Sparrow.IO.Process.Sleep (20);
      end loop;
      Check (Body_Errors.Total = Errors + 2, Mode & "a client that leaves mid-upload: Body_Error");
      Open (Web, Mode = "https: ");
      declare
         Answer : constant String :=
           Exchange (Web, "POST /echo" & Post_Head & "Content-Length: 2000000" & CRLF & CRLF);
      begin
         Check (Contains (Answer, " 413 ") and then not Receive_More (Web),
                Mode & "a buffered route refuses a body past Max_Body_Length before it comes");
      end;
      Close (Web);
      Open (Web, Mode = "https: ");
      Check (Contains (Exchange (Web, "POST /echo" & Post_Head & Chunked & "zz" & CRLF), " 400 ")
             and then not Receive_More (Web), Mode & "a malformed chunked body: 400");
      Close (Web);
      Open (Web, Mode = "https: ");
   end Body_Tests;

   --  One session against a running server; Secure speaks TLS.
   procedure Converse (Secure : Boolean) is
      Mode : constant String := (if Secure then "https: " else "http: ");
      Web  : Client;
   begin
      Open (Web, Secure);
      declare
         Answer : constant String := Exchange (Web, Get ("/hello"));
      begin
         Check (Contains (Answer, "HTTP/1.1 200 OK" & CRLF) and then Body_Of (Answer) = "hello",
                Mode & "GET on the reactor");
         Check (Contains (Answer, "Content-Type: text/plain; charset=utf-8" & CRLF)
                and then Contains (Answer, "Date: "), Mode & "content type and date");
      end;
      Equal (Body_Of (Exchange (Web, Get ("/who/ada%20lovelace"))), "worker ada lovelace", Mode & "on a worker");
      Equal (Body_Of (Exchange (Web, Get ("/here/x"))), "reactor x", Mode & "On_Reactor");

      --  Three requests in one write: answered in order on one connection.
      Send (Web, Get ("/slow/1") & Get ("/here/2") & Get ("/who/3"));
      Equal (Body_Of (Next_Response (Web)), "worker 1", Mode & "pipelined 1 (slow)");
      Equal (Body_Of (Next_Response (Web)), "reactor 2", Mode & "pipelined 2 waits its turn");
      Equal (Body_Of (Next_Response (Web)), "worker 3", Mode & "pipelined 3");

      declare
         Payload : constant String := [1 .. 200_000 => 'z'];
         Answer  : constant String :=
           Exchange (Web, "POST /echo HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 200000" & CRLF & CRLF
                          & Payload);
      begin
         Check (Body_Of (Answer) = Payload, Mode & "a 200 kB body both ways");
      end;

      Send (Web, "POST /echo HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 5" & CRLF
                 & "Expect: 100-continue" & CRLF & CRLF);
      Check (Contains (Next_Response (Web, No_Body => True), "100 Continue"), Mode & "100 Continue");
      Send (Web, "12345");
      Equal (Body_Of (Next_Response (Web)), "12345", Mode & "the body after 100 Continue");

      Body_Tests (Web, Mode);

      --  gzip, decided per response.
      declare
         Takes  : constant String := "Accept-Encoding: br, gzip;q=0.8" & CRLF;
         Zipped : constant String := Exchange (Web, Get ("/text", Takes));
         Plain  : constant String := Exchange (Web, Get ("/text"));
         Kept   : constant String := Exchange (Web, Get ("/text-kept", Takes));
         Small  : constant String := Exchange (Web, Get ("/hello", Takes));
      begin
         Check (Contains (Zipped, "Content-Encoding: gzip" & CRLF) and then Contains (Zipped, "Vary: Accept-Encoding")
                and then Zlib_Check.Inflated (Body_Of (Zipped)) = Long_Text
                and then Body_Of (Zipped)'Length < Long_Text'Length / 2, Mode & "gzip when the client takes it");
         Check (not Contains (Plain, "Content-Encoding") and then Contains (Plain, "Vary: Accept-Encoding")
                and then Body_Of (Plain) = Long_Text, Mode & "the same bytes, and Vary, when it does not");
         Check (not Contains (Kept, "Content-Encoding") and then Body_Of (Kept) = Long_Text,
                Mode & "Cache-Control: no-transform is kept as it is");
         Check (not Contains (Small, "Content-Encoding") and then Body_Of (Small) = "hello",
                Mode & "a small body is left alone");
      exception
         when Zlib_Check.Not_Gzip => Check (False, Mode & "gzip when the client takes it: zlib refused it");
      end;

      --  Ranges of a static file.
      declare
         use Ada.Streams.Stream_IO;
         File : File_Type;
         Size : Natural;
      begin
         Open (File, In_File, "data/cert.pem");
         Size := Natural (Ada.Streams.Stream_IO.Size (File));
         declare
            Whole  : String (1 .. Size);
            Length : constant String := Sparrow.Encoding.Decimal_Image (Long_Long_Integer (Size));
         begin
            String'Read (Stream (File), Whole);
            Close (File);
            declare
               First : constant String := Exchange (Web, Get ("/files/cert.pem", "Range: bytes=0-9" & CRLF));
               Tail  : constant String := Exchange (Web, Get ("/files/cert.pem", "Range: bytes=-5" & CRLF));
               Past  : constant String :=
                 Exchange (Web, Get ("/files/cert.pem", "Range: bytes=" & Length & "-" & CRLF));
               Stale : constant String :=
                 Exchange (Web, Get ("/files/cert.pem", "Range: bytes=0-9" & CRLF & "If-Range: ""old""" & CRLF));
            begin
               Check (Contains (First, "206 Partial Content") and then Body_Of (First) = Whole (1 .. 10)
                      and then Contains (First, "Content-Range: bytes 0-9/" & Length & CRLF)
                      and then Contains (First, "Accept-Ranges: bytes"), Mode & "a range: 206 and its bytes");
               Check (Contains (Tail, "206") and then Body_Of (Tail) = Whole (Size - 4 .. Size),
                      Mode & "the last bytes");
               Check (Contains (Past, "416 Range Not Satisfiable")
                      and then Contains (Past, "Content-Range: bytes */" & Length & CRLF), Mode & "past the end: 416");
               Check (Contains (Stale, "200 OK") and then Body_Of (Stale) = Whole,
                      Mode & "If-Range for another version: the whole file");
            end;
         end;
      end;

      --  A rate limit, per client: the server is Behind_Proxy, so X-Forwarded-For names the client.
      declare
         From : constant String := "X-Forwarded-For: 192.0.2." & (if Secure then "2" else "1") & CRLF;
      begin
         Check (Contains (Exchange (Web, Get ("/limited", From)), " 200 ")
                and then Contains (Exchange (Web, Get ("/limited", From)), " 200 "), Mode & "limit: the burst");
         declare
            Answer : constant String := Exchange (Web, Get ("/limited", From));
         begin
            Check (Contains (Answer, " 429 ") and then Contains (Answer, "Retry-After: 1000" & CRLF),
                   Mode & "limit: then 429 with Retry-After");
         end;
         Check (Contains (Exchange (Web, Get ("/limited", "X-Forwarded-For: 198.51.100.7" & CRLF)), " 200 "),
                Mode & "limit: another client has its own bucket");
      end;

      Check (Contains (Exchange (Web, Get ("/nowhere")), "404 Not Found"), Mode & "404");
      Check (Contains (Exchange (Web, "DELETE /hello HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF),
                       "405 Method Not Allowed"), Mode & "405");
      Check (Contains (Exchange (Web, Get ("/boom")), "500 Internal Server Error"), Mode & "an exception is a 500");

      Send (Web, "HEAD /hello HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);
      declare
         Answer : constant String := Next_Response (Web, No_Body => True);
      begin
         Check (Contains (Answer, "Content-Length: 5") and then Body_Of (Answer) = "", Mode & "HEAD has no body");
      end;
      Equal (Body_Of (Exchange (Web, Get ("/hello"))), "hello", Mode & "still in step after HEAD");

      declare
         Answer : constant String := Exchange (Web, Get ("/leave"));
      begin
         Check (Contains (Answer, "Connection: close"), Mode & "a handler closes the connection");
         Check (not Receive_More (Web), Mode & "and it is closed");
      end;
      Close (Web);

      Open (Web, Secure);
      declare
         Answer : constant String := Exchange (Web, "GET / HTTP/1.1" & CRLF & CRLF);
      begin
         Check (Contains (Answer, "400 Bad Request") and then Contains (Answer, "Connection: close")
                and then not Receive_More (Web), Mode & "a bad request is answered, then closed");
      end;
      Close (Web);

      Open (Web, Secure);
      Check (Contains (Exchange (Web, "GET /hello HTTP/1.0" & CRLF & CRLF), "Connection: close")
             and then not Receive_More (Web), Mode & "HTTP/1.0 closes by default");
      Close (Web);

      Open (Web, Secure);
      Send (Web, "GET /hel");
      Check (not Receive_More (Web) and then Content (Web.Pending) = "", Mode & "an idle connection times out");
      Close (Web);
   end Converse;

   --  Everything received up to and including Marker; "" if the connection ended first.
   function Read_Until (This : in out Client; Marker : String) return String is begin
      loop
         declare
            Text : constant String := Content (This.Pending);
            Found  : constant Natural := Ada.Strings.Fixed.Index (Text, Marker);
         begin
            if Found > 0 then
               Consume (This.Pending, Found + Marker'Length - 1);
               return Text (1 .. Found + Marker'Length - 1);
            end if;
         end;
         if not Receive_More (This) then
            return "";
         end if;
      end loop;
   end Read_Until;

   --  Whether the server closes the connection (rather than sending more, or nothing for 5 s).
   function Ends (This : in out Client) return Boolean is
     (This.Pending.Length = 0 and then not Receive_More (This));

   --  A client frame: masked unless told otherwise.
   function Frame (Opcode : Natural; Payload : String; Final : Boolean := True; Masked : Boolean := True)
     return String
   is
      Mask   : constant String := "k3y!";
      Header : constant String :=
        [Character'Val ((if Final then 16#80# else 0) + Opcode)]
        & (if Payload'Length < 126
           then [Character'Val ((if Masked then 16#80# else 0) + Payload'Length)]
           else [Character'Val ((if Masked then 16#80# else 0) + 126),
                 Character'Val (Payload'Length / 256), Character'Val (Payload'Length mod 256)]);
      Body_Of_Frame : String (1 .. Payload'Length);
   begin
      for Index in Body_Of_Frame'Range loop
         Body_Of_Frame (Index) :=
           (if Masked
            then Character'Val (Interfaces.Unsigned_8 (Character'Pos (Payload (Payload'First + Index - 1)))
                                xor Interfaces.Unsigned_8 (Character'Pos (Mask ((Index - 1) mod 4 + 1))))
            else Payload (Payload'First + Index - 1));
      end loop;
      return Header & (if Masked then Mask else "") & Body_Of_Frame;
   end Frame;

   --  The next server frame as its opcode (one character) then its payload; "" if the connection ended.
   function Next_Frame (This : in out Client) return String is begin
      loop
         declare
            Text : constant String := Content (This.Pending);
         begin
            if Text'Length >= 2 then
               declare
                  Short  : constant Natural := Character'Pos (Text (2)) mod 128;
                  Header : constant Natural := (if Short = 126 then 4 else 2);
                  Length : constant Natural :=
                    (if Short /= 126 then Short
                     elsif Text'Length >= 4 then Character'Pos (Text (3)) * 256 + Character'Pos (Text (4))
                     else Natural'Last - 8);
               begin
                  if Text'Length >= Header + Length then
                     Consume (This.Pending, Header + Length);
                     return Character'Val (Character'Pos (Text (1)) mod 16) & Text (Header + 1 .. Header + Length);
                  end if;
               end;
            end if;
         end;
         if not Receive_More (This) then
            return "";
         end if;
      end loop;
   end Next_Frame;

   function Close_Frame (Code : Natural) return String is
     [Character'Val (8), Character'Val (Code / 256), Character'Val (Code mod 256)];

   function Wait_For (Condition : access function return Boolean) return Boolean is begin
      for Attempt in 1 .. 300 loop
         if Condition.all then
            return True;
         end if;
         Sparrow.IO.Process.Sleep (10);
      end loop;
      return False;
   end Wait_For;

   --  Streams, event streams and WebSockets against a running server.
   procedure Push_Tests (Secure : Boolean) is
      Mode       : constant String := (if Secure then "https: " else "http: ");
      Upgrade    : constant String :=
        "Upgrade: websocket" & CRLF & "Connection: Upgrade" & CRLF
        & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & "Sec-WebSocket-Version: 13" & CRLF;
      Expected_Stream : constant String :=
        "4" & CRLF & "one;" & CRLF & "4" & CRLF & "two;" & CRLF & "6" & CRLF & "three;" & CRLF & "0" & CRLF & CRLF;

      function One_Watcher return Boolean is (Streams.Count (Watchers) = 1);
      function No_Watcher return Boolean is (Streams.Count (Watchers) = 0);
      Closes_Before : constant Natural := Socket_Events.Closes;
      function Socket_Closed return Boolean is (Socket_Events.Closes > Closes_Before);
   begin
      declare
         procedure Read_Stream (Path : String) is
            Web : Client;
         begin
            Open (Web, Secure);
            Send (Web, Get (Path));
            declare
               Answer : constant String := Read_Until (Web, CRLF & "0" & CRLF & CRLF);   --  the last chunk
            begin
               Check (Contains (Answer, "Transfer-Encoding: chunked" & CRLF)
                      and then not Contains (Answer, "Content-Length")
                      and then Body_Of (Answer) = Expected_Stream,
                      Mode & "a stream from " & Path & " arrives in order, then ends");
            end;
            Check (Ends (Web), Mode & "the connection closes after a stream ends");
            Close (Web);
         end Read_Stream;
      begin
         Read_Stream ("/count");
         Read_Stream ("/count-here");
      end;

      declare   --  an event stream, sent to from this task
         Web : Client;
      begin
         Open (Web, Secure);
         Send (Web, Get ("/events"));
         Check (Contains (Read_Until (Web, "retry: 500" & ASCII.LF & ASCII.LF), "text/event-stream"),
                Mode & "an event stream starts with its retry");
         Check (Wait_For (One_Watcher'Access), Mode & "the stream joins its group");
         Event_Streams.Send (Watchers, "hi" & ASCII.LF & "there", Name => "note", Id => "7");
         Check (Contains (Read_Until (Web, "data: there" & ASCII.LF & ASCII.LF),
                          "event: note" & ASCII.LF & "id: 7" & ASCII.LF & "data: hi" & ASCII.LF),
                Mode & "an event reaches the group's members");
         Close (Web);
         Check (Wait_For (No_Watcher'Access), Mode & "a client that leaves drops out of the group");
      end;

      declare   --  a WebSocket conversation
         Web : Client;
      begin
         Open (Web, Secure);
         declare
            Answer : constant String := Exchange (Web, Get ("/socket", Upgrade));
         begin
            Check (Contains (Answer, "HTTP/1.1 101 Switching Protocols" & CRLF)
                   and then Contains (Answer, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" & CRLF),
                   Mode & "the WebSocket handshake");
         end;
         Send (Web, Frame (1, "hello"));
         Check (Next_Frame (Web) = Character'Val (1) & "HELLO", Mode & "a text message and its answer");
         declare
            Bytes : String (1 .. 300);
         begin
            for Index in Bytes'Range loop
               Bytes (Index) := Character'Val (Index mod 256);
            end loop;
            Send (Web, Frame (2, Bytes));
            Check (Next_Frame (Web) = Character'Val (2) & Bytes, Mode & "a 300-byte binary message");
         end;
         Send (Web, Frame (1, "ab", Final => False) & Frame (9, "ping?") & Frame (0, "cd"));
         Check (Next_Frame (Web) = Character'Val (10) & "ping?", Mode & "a ping inside a fragmented message");
         Check (Next_Frame (Web) = Character'Val (1) & "ABCD", Mode & "a fragmented message is joined");
         Send (Web, Frame (1, "bye"));
         Check (Next_Frame (Web) = Close_Frame (1000), Mode & "the server closes when asked");
         Check (Ends (Web), Mode & "the connection ends after the close");
         Close (Web);
         Check (Wait_For (Socket_Closed'Access), Mode & "the endpoint hears of the close");
      end;

      declare
         procedure Expect_Close (Sent : String; Code : Natural; Name : String) is
            Web : Client;
         begin
            Open (Web, Secure);
            if Contains (Exchange (Web, Get ("/socket", Upgrade)), " 101 ") then
               Send (Web, Sent);
               Check (Next_Frame (Web) = Close_Frame (Code), Mode & Name);
            else
               Check (False, Mode & Name & " (no handshake)");
            end if;
            Close (Web);
         end Expect_Close;
      begin
         Expect_Close (Frame (1, "boom"), 1011, "a failing handler closes with 1011");
         Expect_Close (Frame (1, "hi", Masked => False), 1002, "an unmasked frame closes with 1002");
         Expect_Close (Frame (1, [Character'Val (16#C3#)]), 1007, "text that is not UTF-8 closes with 1007");
         Expect_Close (Frame (2, [1 .. 1001 => 'x']), 1009, "a message past Max_Message closes with 1009");
         Expect_Close (Frame (0, "stray"), 1002, "a continuation of nothing closes with 1002");
         Expect_Close (Frame (8, Close_Frame (1000) (2 .. 3)), 1000, "a client's close is echoed");
      end;

      declare   --  refused handshakes
         Web : Client;
      begin
         Open (Web, Secure);
         Check (Contains (Exchange (Web, Get ("/socket", Upgrade & "Origin: https://elsewhere.example" & CRLF)),
                          " 403 "), Mode & "another site's page may not connect");
         Check (Contains (Exchange (Web, Get ("/socket")), " 400 "), Mode & "a plain GET of a socket is refused");
         Close (Web);
      end;
   end Push_Tests;

   --  The value of header Name in a response's head; "" without one.
   function Header_Of (Answer, Name : String) return String is
      Start : constant Natural := Ada.Strings.Fixed.Index (Answer, CRLF & Name & ": ");
      Stop  : Natural;
   begin
      if Start = 0 then
         return "";
      end if;
      Stop := Ada.Strings.Fixed.Index (Answer (Start + 2 .. Answer'Last), CRLF);
      return Answer (Start + Name'Length + 4 .. Stop - 1);
   end Header_Of;

   --  Request ids, traces and the access log, against a running plain server.
   procedure Trace_Tests is
      Web    : Client;
      Parent : constant String := "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
   begin
      Open (Web);
      declare
         Answer : constant String := Exchange (Web, Get ("/hello"));
         Id     : constant String := Header_Of (Answer, "X-Request-Id");
      begin
         Check (Id'Length = 32 and then (for all C of Id => C in '0' .. '9' | 'a' .. 'f'),
                "each answer carries a new request id");
         Check (Log_Capture.Find ("request request_id=" & Id & " method=GET path=/hello status=200 bytes=5 ms=",
                                  "client=127.0.0.1") /= "",
                "the access log has the request, with its id");
      end;
      declare
         Answer : constant String := Exchange (Web, Get ("/hello", "X-Request-Id: from-the-proxy.7" & CRLF));
      begin
         Check (Header_Of (Answer, "X-Request-Id") = "from-the-proxy.7"
                and then Log_Capture.Find ("request_id=from-the-proxy.7 trace_id=", "path=/hello") /= "",
                "a caller's request id is kept");
      end;
      --  Behind a proxy, the client is the last X-Forwarded-For entry, written canonically; anything that is not
      --  an address leaves the connection's own peer.
      for Case_Number in 1 .. 6 loop
         declare
            Forwarded : constant String :=
              (case Case_Number is
                  when 1 => "198.51.100.1, 203.0.113.5", when 2 => "2001:DB8:0::1",
                  when 3 => "[2001:db8::2]:443",          when 4 => "198.51.100.7:8080",
                  when 5 => "::ffff:192.0.2.9",           when others => "not an address");
            Expected  : constant String :=
              (case Case_Number is
                  when 1 => "203.0.113.5", when 2 => "2001:db8::1", when 3 => "2001:db8::2",
                  when 4 => "198.51.100.7", when 5 => "192.0.2.9",  when others => "127.0.0.1");
            Answer    : constant String :=
              Exchange (Web, Get ("/hello", "X-Forwarded-For: " & Forwarded & CRLF));
            Id        : constant String := Header_Of (Answer, "X-Request-Id");
         begin
            Check (Log_Capture.Find ("request_id=" & Id, "client=" & Expected) /= "", "forwarded client: " & Forwarded);
         end;
      end loop;
      declare
         Answer : constant String := Exchange (Web, Get ("/hello", "X-Request-Id: bad id" & CRLF));
      begin
         Check (Header_Of (Answer, "X-Request-Id")'Length = 32, "a malformed request id is replaced");
      end;
      declare
         Answer : constant String := Exchange (Web, Get ("/traced", "traceparent: " & Parent & CRLF));
         Passed : constant String (1 .. Body_Of (Answer)'Length) := Body_Of (Answer);
      begin
         Check (Header_Of (Answer, "X-Request-Id") = "4bf92f3577b34da6a3ce929d0e0e4736",
                "a traceparent's trace id becomes the request id");
         Check (Log_Capture.Find ("INFO    handled request_id=4bf92f3577b34da6a3ce929d0e0e4736 n=7") /= "",
                "a handler's log line carries the request id");
         Check (Ada.Strings.Fixed.Index (Passed, "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-") = 1
                and then Passed'Length > 70
                and then Passed (50 .. 65) /= "00f067aa0ba902b7" and then Passed (66 .. 69) = "-01" & ASCII.LF
                and then Ada.Strings.Fixed.Index (Passed, "X-Request-Id: 4bf92f3577b34da6a3ce929d0e0e4736") > 0,
                "Trace_Headers passes the trace on, with this request as the parent");
      end;
      declare
         Answer : constant String :=
           Exchange (Web, Get ("/hello", "traceparent: 00-00000000000000000000000000000000-00f067aa0ba902b7-01"
                                         & CRLF));
      begin
         Check (Header_Of (Answer, "X-Request-Id") /= "00000000000000000000000000000000",
                "an invalid traceparent starts a new trace");
      end;
      declare
         Answer : constant String := Exchange (Web, Get ("/boom"));
         Id     : constant String := Header_Of (Answer, "X-Request-Id");
      begin
         Check (Log_Capture.Find ("ERROR   handler failed request_id=" & Id, "path=/boom",
                                  "exception=CONSTRAINT_ERROR") /= ""
                and then Log_Capture.Find ("ERROR   request request_id=" & Id, "status=500") /= "",
                "a failing handler is logged with its request's id, and its 500 as an error");
      end;
      Check (Contains (Exchange (Web, Get ("/nowhere/at/all")), " 404 ")
             and then Log_Capture.Find ("path=/nowhere/at/all status=404") /= "", "a 404 is logged");
      Close (Web);

      Open (Web);
      Send (Web, Get ("/slow/gone"));
      Close (Web);
      declare
         function Logged return Boolean is (Log_Capture.Find ("path=/slow/gone") /= "");
      begin
         Check (Wait_For (Logged'Access), "a request whose client hung up meanwhile is still logged");
      end;

      Open (Web);
      Check (Contains (Exchange (Web, "BROKEN" & CRLF & CRLF), " 400 ")
             and then Log_Capture.Find ("method=- path=- status=400") /= "", "a malformed request is logged");
      Close (Web);
   end Trace_Tests;

   procedure Live_Tests is
      Problem : Boolean;
   begin
      Routers.Add (Routes, Get, "/hello", Hello'Access, Routers.On_Reactor);
      Routers.Add (Routes, Get, "/who/:name", Who'Access);
      Routers.Add (Routes, Get, "/here/:name", Who'Access, Routers.On_Reactor);
      Routers.Add (Routes, Get, "/slow/:name", Slow'Access);
      Routers.Add (Routes, Post, "/echo", Echo'Access);
      Routers.Add (Routes, Get, "/boom", Boom'Access);
      Routers.Add (Routes, Get, "/leave", Leave'Access);
      Routers.Add (Routes, Get, "/count", Count_Up'Access);
      Routers.Add (Routes, Get, "/count-here", Count_Up'Access, Routers.On_Reactor);
      Routers.Add (Routes, Get, "/events", Watch'Access);
      Routers.Add (Routes, Get, "/socket", Sparrow.Http.Websockets.Serve (new Echo_Socket, Max_Message => 1000));
      Routers.Add (Routes, Get, "/traced", Traced'Access);
      Routers.Add (Routes, Post, "/upload", Upload_Sum'Access, Body_Mode => Routers.Streamed);
      Routers.Add (Routes, Post, "/upload-part", Upload_Part'Access, Body_Mode => Routers.Streamed);
      Routers.Add (Routes, Post, "/upload-all", Upload_All'Access, Body_Mode => Routers.Streamed);
      Routers.Add (Routes, Post, "/upload-form", Upload_Form'Access, Body_Mode => Routers.Streamed);
      Routers.Add (Routes, Get, "/limited", Sparrow.Http.Limits.Wrap (Tight, Who'Access), Routers.On_Reactor);
      Routers.Add (Routes, Get, "/text", Long_Text_Route'Access);
      Routers.Add (Routes, Get, "/text-kept", Kept_Text'Access, Routers.On_Reactor);
      Routers.Add (Routes, Get, "/files/*file", Sparrow.Http.Static.Folder ("data"));
      Sparrow.Logs.Configure (Threshold => Sparrow.Logs.Info, Style => Sparrow.Logs.Text);
      Sparrow.Logs.Set_Sink (Log_Capture.Keep'Access);

      declare
         Plain : Server_Task;
      begin
         Plain.Start (Secure => False);
         Await_Server;
         Converse (Secure => False);
         Push_Tests (Secure => False);
         Trace_Tests;
         Servers.Stop;
         Plain.Finished (Problem);
         Check (not Problem, "the plain server stops cleanly");
         Check (Counters.Starts = 3 and then Counters.Stops = 3, "worker hooks ran on every worker");
      end;

      Tls.Open_Server (Server_Context, "data/cert.pem", "data/key.pem");
      Tls.Open_Client (Trust, Trust_File => "data/cert.pem");
      declare
         Secure : Server_Task;
      begin
         Secure.Start (Secure => True);
         Await_Server;
         Converse (Secure => True);
         Push_Tests (Secure => True);

         declare   --  a client that never finishes its handshake
            Socket  : Descriptor;
            Failure : Error;
            Bytes   : String (1 .. 16);
            Count   : Integer;
         begin
            Connect (Loopback, Port, Socket, Failure, Timeout => 5000);
            Send (Socket, "not a TLS hello" & CRLF, Count, Failure);
            Receive (Socket, Bytes, Count, Failure);
            Check (Count <= 0 or else Bytes (1) /= 'H', "https: plain text gets no HTTP answer");
            Close (Socket);
         end;

         Servers.Stop;
         Secure.Finished (Problem);
         Check (not Problem, "the TLS server stops cleanly");
      end;
      Tls.Close (Trust);
      Tls.Close (Server_Context);
      Routers.Free (Routes);
      Sparrow.Logs.Set_Sink (null);
   end Live_Tests;

begin
   Parser_Tests;
   Request_And_Router_Tests;
   Static_Tests;
   Compression_And_Range_Tests;
   Frame_Tests;
   Scanner_Tests;
   Response_Tests;
   Helper_Tests;
   Limit_Tests;
   Live_Tests;
   Check (Websockets.Accept_Key ("dGhlIHNhbXBsZSBub25jZQ==") = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
          "the WebSocket accept key (RFC 6455 1.3)");
   Check (Websockets.Origin_Allowed ("http://Example.com:8080", "example.com:8080", "")
          and then not Websockets.Origin_Allowed ("http://evil.example", "example.com", "")
          and then Websockets.Origin_Allowed ("", "example.com", "")
          and then Websockets.Origin_Allowed ("https://b.example", "a.example", "https://a.example https://b.example")
          and then not Websockets.Origin_Allowed ("https://c.example", "a.example", "https://b.example")
          and then Websockets.Origin_Allowed ("https://c.example", "a.example", "*"),
          "WebSocket origin rules");
   Check (Event_Streams.Event ("a" & ASCII.CR & ASCII.LF & "b", Name => "x" & ASCII.LF & "y")
          = "event: xy" & ASCII.LF & "data: a" & ASCII.LF & "data: b" & ASCII.LF & ASCII.LF,
          "an event's lines, and a name kept on one line");
   Check (Sparrow.Http.Log.Valid_Traceparent ("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
          and then not Sparrow.Http.Log.Valid_Traceparent ("00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01")
          and then not Sparrow.Http.Log.Valid_Traceparent ("00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01")
          and then not Sparrow.Http.Log.Valid_Traceparent ("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7"),
          "traceparent syntax");
   Check (Sparrow.Http.Log.Valid_Request_Id ("req:42/a.b_c-d@e")
          and then not Sparrow.Http.Log.Valid_Request_Id ("")
          and then not Sparrow.Http.Log.Valid_Request_Id ("a b")
          and then not Sparrow.Http.Log.Valid_Request_Id ([1 .. 65 => 'x']), "request id syntax");
   Finish ("http");
end Http_Tests;
