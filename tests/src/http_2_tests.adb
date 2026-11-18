with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;
with Checks; use Checks;
with Sparrow.Http.Static;
with Http_Test_Handlers; use Http_Test_Handlers;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.IO; use Sparrow.IO;
with Sparrow.IO.Process;
with Sparrow.IO.Sockets; use Sparrow.IO.Sockets;
with Sparrow.Tls;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Hpack;
with Sparrow.Http.Http_2; use Sparrow.Http.Http_2;
with Sparrow.Http.Parser;
with Sparrow.Times; use Sparrow.Times;

--  HPACK against RFC 7541's examples; the HTTP/2 session frame by frame, after the cases of h2spec (the HTTP/2
--  conformance suite); then a live server, over plain TCP and TLS, through libcurl.
procedure Http_2_Tests is

   CRLF : constant String := ASCII.CR & ASCII.LF;

   function From_Hex (Text : String) return String is
      Digits_Of : constant String := "0123456789abcdef";
      Result    : String (1 .. Text'Length / 2);
      function Value (Item : Character) return Natural is
      begin
         for Index in Digits_Of'Range loop
            if Digits_Of (Index) = Item then
               return Index - 1;
            end if;
         end loop;
         raise Constraint_Error;
      end Value;
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val (Value (Text (Text'First + 2 * (Index - 1))) * 16
                                          + Value (Text (Text'First + 2 * (Index - 1) + 1)));
      end loop;
      return Result;
   end From_Hex;

   ---------------------------------------------------------------------------------------------------------------
   --  HPACK

   --  The fields of a decoded block, as "name: value" lines.
   function Decoded (Table : in out Hpack.Decoder; Block : String; Result : out Hpack.Outcome) return String is
      Text   : String (1 .. 4096);
      Last   : Natural;
      Fields : Hpack.Field_Array (1 .. 64);
      Count  : Natural;
      Lines  : Buffer;
      Source : constant String (1 .. Block'Length) := Block;
   begin
      Hpack.Decode (Table, Source, Text, Last, Fields, Count, Result);
      for Index in 1 .. Count loop
         Append (Lines, Text (Fields (Index).Name_First .. Fields (Index).Name_Last) & ": "
                 & Text (Fields (Index).Value_First .. Fields (Index).Value_Last) & ASCII.LF);
      end loop;
      return Result_Text : constant String := Content (Lines) do
         Free (Lines);
      end return;
   end Decoded;

   procedure Hpack_Tests is
      use type Hpack.Outcome;
      LF       : constant Character := ASCII.LF;
      Result   : Hpack.Outcome;
      Requests : Hpack.Decoder := Hpack.New_Decoder;
      Answers  : Hpack.Decoder := Hpack.New_Decoder;
      Plain    : Hpack.Decoder := Hpack.New_Decoder;
      Date_1   : constant String := "date: Mon, 21 Oct 2013 20:13:21 GMT" & LF;
      Location : constant String := "location: https://www.example.com" & LF;
   begin
      --  C.3: requests without Huffman coding; C.4: the same with it. One table each, across the three.
      Equal (Decoded (Plain, From_Hex ("828684410f7777772e6578616d706c652e636f6d"), Result),
             ":method: GET" & LF & ":scheme: http" & LF & ":path: /" & LF & ":authority: www.example.com" & LF,
             "RFC 7541 C.3.1");
      Equal (Decoded (Plain, From_Hex ("828684be58086e6f2d6361636865"), Result),
             ":method: GET" & LF & ":scheme: http" & LF & ":path: /" & LF & ":authority: www.example.com" & LF
             & "cache-control: no-cache" & LF, "RFC 7541 C.3.2 (the table remembers)");
      Equal (Decoded (Plain, From_Hex ("828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565"), Result),
             ":method: GET" & LF & ":scheme: https" & LF & ":path: /index.html" & LF
             & ":authority: www.example.com" & LF & "custom-key: custom-value" & LF, "RFC 7541 C.3.3");
      Equal (Decoded (Requests, From_Hex ("828684418cf1e3c2e5f23a6ba0ab90f4ff"), Result),
             ":method: GET" & LF & ":scheme: http" & LF & ":path: /" & LF & ":authority: www.example.com" & LF,
             "RFC 7541 C.4.1 (Huffman)");
      Equal (Decoded (Requests, From_Hex ("828684be5886a8eb10649cbf"), Result),
             ":method: GET" & LF & ":scheme: http" & LF & ":path: /" & LF & ":authority: www.example.com" & LF
             & "cache-control: no-cache" & LF, "RFC 7541 C.4.2");
      Equal (Decoded (Requests, From_Hex ("828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf"), Result),
             ":method: GET" & LF & ":scheme: https" & LF & ":path: /index.html" & LF
             & ":authority: www.example.com" & LF & "custom-key: custom-value" & LF, "RFC 7541 C.4.3");

      --  C.6: responses with Huffman coding and evictions (the example's table is 256 bytes).
      Equal (Decoded (Answers, From_Hex ("488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e9"
                                         & "19d29ad171863c78f0b97c8e9ae82ae43d3"), Result),
             ":status: 302" & LF & "cache-control: private" & LF & Date_1 & Location, "RFC 7541 C.6.1");
      Equal (Decoded (Answers, From_Hex ("4883640effc1c0bf"), Result),
             ":status: 307" & LF & "cache-control: private" & LF & Date_1 & Location, "RFC 7541 C.6.2");
      Equal (Decoded (Answers, From_Hex ("88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7"
                                         & "821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c00"
                                         & "3ed4ee5b1063d5007"), Result),
             ":status: 200" & LF & "cache-control: private" & LF & "date: Mon, 21 Oct 2013 20:13:22 GMT" & LF
             & Location & "content-encoding: gzip" & LF
             & "set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1" & LF, "RFC 7541 C.6.3");

      --  C.1: integers.
      declare
         Into : Buffer;
      begin
         Hpack.Encode_Integer (Into, 10, 5, 0);
         Hpack.Encode_Integer (Into, 1337, 5, 0);
         Hpack.Encode_Integer (Into, 42, 8, 0);
         Equal (Content (Into), From_Hex ("0a1f9a0a2a"), "RFC 7541 C.1: integers");
         Free (Into);
      end;

      --  The encoder, read back by the decoder.
      declare
         Into  : Buffer;
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
      begin
         Hpack.Encode_Status (Into, 200);
         Hpack.Encode_Status (Into, 418);
         Hpack.Encode_Field (Into, "content-type", "text/plain");
         Hpack.Encode_Field (Into, "x-custom", "a value");
         Equal (Decoded (Fresh, Content (Into), Result),
                ":status: 200" & LF & ":status: 418" & LF & "content-type: text/plain" & LF & "x-custom: a value" & LF,
                "the encoder's fields decode");
         Free (Into);
      end;

      --  Malformed blocks.
      declare
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
         Text  : constant String := Decoded (Fresh, From_Hex ("80"), Result);
      begin
         Check (Result = Hpack.Malformed and then Text = "", "index 0 is malformed");
      end;
      declare
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
         Text  : constant String := Decoded (Fresh, From_Hex ("be"), Result);
      begin
         Check (Result = Hpack.Malformed and then Text = "", "an index past both tables");
      end;
      declare
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
         Text  : constant String := Decoded (Fresh, From_Hex ("0085f2b24a87ff"), Result);   --  a name, then
      begin
         Check (Result = Hpack.Malformed and then Text = "", "Huffman padding that is not all ones");
      end;
      declare
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
         Text  : constant String := Decoded (Fresh, From_Hex ("0084ffffffff"), Result);
      begin
         Check (Result = Hpack.Malformed and then Text = "", "EOS inside a Huffman string");
      end;
      declare
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
         Text  : constant String := Decoded (Fresh, From_Hex ("82" & "3fe11f"), Result);
      begin
         Check (Result = Hpack.Malformed and then Text = ":method: GET" & LF, "a size update after a field");
      end;
      declare
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
         Text  : constant String := Decoded (Fresh, From_Hex ("3fe21f82"), Result);
      begin
         Check (Result = Hpack.Malformed and then Text = "", "a size update past what was announced");
      end;
      declare
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
         Text  : constant String := Decoded (Fresh, From_Hex ("0f8180808080808001"), Result);
      begin
         Check (Result = Hpack.Malformed and then Text = "", "an integer too long");
      end;
      declare
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
         Text  : constant String := Decoded (Fresh, From_Hex ("000a61"), Result);
      begin
         Check (Result = Hpack.Malformed and then Text = "", "a string past the block's end");
      end;
      --  30-bit codes (ASCII 10, 13 and 22) decode: the end of a "\r" in Huffman.
      declare
         Fresh : Hpack.Decoder := Hpack.New_Decoder;
         Text  : constant String := Decoded (Fresh, From_Hex ("00016184fffffff7"), Result);
      begin
         Check (Result = Hpack.Decoded and then Text = "a: " & ASCII.CR & LF, "a 30-bit Huffman code");
      end;
   end Hpack_Tests;

   ---------------------------------------------------------------------------------------------------------------
   --  frames

   function Frame (Kind, Flags, Stream : Natural; Payload : String) return String is
     (Character'Val (Payload'Length / 65_536) & Character'Val (Payload'Length / 256 mod 256)
      & Character'Val (Payload'Length mod 256) & Character'Val (Kind) & Character'Val (Flags)
      & Character'Val (Stream / 2 ** 24 mod 128) & Character'Val (Stream / 2 ** 16 mod 256)
      & Character'Val (Stream / 256 mod 256) & Character'Val (Stream mod 256) & Payload);

   function Four (Value : Long_Long_Integer) return String is
     (Character'Val (Value / 2 ** 24 mod 256) & Character'Val (Value / 2 ** 16 mod 256)
      & Character'Val (Value / 256 mod 256) & Character'Val (Value mod 256));

   function Setting (Identifier : Natural; Value : Long_Long_Integer) return String is
     (Character'Val (Identifier / 256) & Character'Val (Identifier mod 256) & Four (Value));

   Data_Kind : constant := 0; Headers_Kind : constant := 1; Priority_Kind : constant := 2; Reset_Kind : constant := 3;
   Settings_Kind : constant := 4; Push_Kind : constant := 5; Ping_Kind : constant := 6; Goaway_Kind : constant := 7;
   Window_Kind : constant := 8; Continuation_Kind : constant := 9;
   End_Stream : constant := 1; End_Headers : constant := 4; Padded : constant := 8; Prioritised : constant := 16#20#;

   No_Error_Code : constant := 0; Protocol : constant := 1; Flow_Control : constant := 3; Closed : constant := 5;
   Frame_Size_Code : constant := 6; Refused_Code : constant := 7; Compression : constant := 9; Calm : constant := 11;

   --  A header block of literal fields: "name" & ASCII.LF & "value" & ASCII.LF ...
   function Block (Lines : String) return String is
      Into  : Buffer;
      First : Positive := Lines'First;   --  the start of the field's name
      Name  : Natural := 0;              --  the line break after its name; 0: not seen yet
   begin
      for Index in Lines'Range loop
         if Lines (Index) = ASCII.LF then
            if Name = 0 then
               Name := Index;
            else
               Hpack.Encode_Field (Into, Lines (First .. Name - 1), Lines (Name + 1 .. Index - 1));
               Name  := 0;
               First := Index + 1;
            end if;
         end if;
      end loop;
      return Result : constant String := Content (Into) do
         Free (Into);
      end return;
   end Block;

   function Get_Block (Path : String := "/") return String is
     (Block (":method" & ASCII.LF & "GET" & ASCII.LF & ":scheme" & ASCII.LF & "http" & ASCII.LF & ":path" & ASCII.LF
             & Path & ASCII.LF & ":authority" & ASCII.LF & "example.com" & ASCII.LF));

   function Post_Block (Extra : String := "") return String is
     (Block (":method" & ASCII.LF & "POST" & ASCII.LF & ":scheme" & ASCII.LF & "http" & ASCII.LF & ":path"
             & ASCII.LF & "/up" & ASCII.LF & ":authority" & ASCII.LF & "example.com" & ASCII.LF & Extra));

   --  A frame of the server's output.
   type Frame_Info is record
      Kind, Flags, Stream : Natural := 0;
      First, Last         : Natural := 0;   --  its payload in the output
   end record;
   type Frame_List is array (1 .. 256) of Frame_Info;

   procedure Parse_Frames (Text : String; List : out Frame_List; Count : out Natural) is
      Position : Natural := Text'First;
   begin
      Count := 0;
      while Position + 8 <= Text'Last and then Count < List'Last loop
         declare
            Length : constant Natural := Character'Pos (Text (Position)) * 65_536
              + Character'Pos (Text (Position + 1)) * 256 + Character'Pos (Text (Position + 2));
         begin
            Count := Count + 1;
            List (Count) := (Kind   => Character'Pos (Text (Position + 3)),
                             Flags  => Character'Pos (Text (Position + 4)),
                             Stream => Character'Pos (Text (Position + 5)) mod 128 * 2 ** 24
                                       + Character'Pos (Text (Position + 6)) * 2 ** 16
                                       + Character'Pos (Text (Position + 7)) * 256
                                       + Character'Pos (Text (Position + 8)),
                             First  => Position + 9,
                             Last   => Position + 8 + Length);
            Position := Position + 9 + Length;
         end;
      end loop;
   end Parse_Frames;

   function Code_At (Text : String; Position : Positive) return Natural is
     (Character'Pos (Text (Position)) * 2 ** 24 + Character'Pos (Text (Position + 1)) * 2 ** 16
      + Character'Pos (Text (Position + 2)) * 256 + Character'Pos (Text (Position + 3)));

   --  Whether Output holds a GOAWAY with Code.
   function Went_Away (Output : Buffer; Code : Natural) return Boolean is
      Text  : constant String := Content (Output);
      List  : Frame_List;
      Count : Natural;
   begin
      Parse_Frames (Text, List, Count);
      return (for some Index in 1 .. Count =>
                List (Index).Kind = Goaway_Kind and then Code_At (Text, List (Index).First + 4) = Code);
   end Went_Away;

   --  Whether Output holds a RST_STREAM for Stream with Code.
   function Was_Reset (Output : Buffer; Stream, Code : Natural) return Boolean is
      Text  : constant String := Content (Output);
      List  : Frame_List;
      Count : Natural;
   begin
      Parse_Frames (Text, List, Count);
      return (for some Index in 1 .. Count =>
                List (Index).Kind = Reset_Kind and then List (Index).Stream = Stream
                and then Code_At (Text, List (Index).First) = Code);
   end Was_Reset;

   --  The frames of Kind in Output, and their payloads joined.
   procedure Frames_Of (Output : Buffer; Kind : Natural; Count : out Natural; Payload : out Buffer;
                        Last_Flags : out Natural) is
      Text  : constant String := Content (Output);
      List  : Frame_List;
      Total : Natural;
   begin
      Parse_Frames (Text, List, Total);
      Count      := 0;
      Last_Flags := 0;
      Clear (Payload);
      for Index in 1 .. Total loop
         if List (Index).Kind = Kind then
            Count := Count + 1;
            Append (Payload, Text (List (Index).First .. List (Index).Last));
            Last_Flags := List (Index).Flags;
         end if;
      end loop;
   end Frames_Of;

   Limits : constant Parser.Limits := (Max_Head_Length => 4096, Max_Body_Length => 1000, others => <>);
   Now    : constant Milliseconds := 1_000;

   --  A session past the client's preface and SETTINGS, its output cleared.
   procedure Open (This : in out Session; Output : in out Buffer; Client_Settings : String := "") is
      Used : Natural;
      Text : constant String := Preface & Frame (Settings_Kind, 0, 0, Client_Settings);
   begin
      Clear (Output);
      Start (This, Limits, Output);
      Receive (This, Text, Now, Used, Output);
      Clear (Output);
   end Open;

   procedure Send (This : in out Session; Data : String; Output : in out Buffer) is
      Used : Natural;
      Own  : constant String (1 .. Data'Length) := Data;
   begin
      Receive (This, Own, Now, Used, Output);
      if Used /= Data'Length and then not Failed (This) then
         Ada.Text_IO.Put_Line ("   (" & Natural'Image (Data'Length - Used) & " bytes left unread)");
      end if;
   end Send;

   function Next (This : in out Session) return Event is
      Item : Event;
   begin
      Next_Event (This, Item);
      return Item;
   end Next;

   --  The session ends the connection with Code after Data.
   procedure Expect_Goaway (Data : String; Code : Natural; Name : String; Client_Settings : String := "") is
      This   : Session;
      Output : Buffer;
   begin
      Open (This, Output, Client_Settings);
      Send (This, Data, Output);
      Check (Failed (This) and then Went_Away (Output, Code), Name);
      Free (This);
      Free (Output);
   end Expect_Goaway;

   --  The session resets Stream with Code after Data, and goes on.
   procedure Expect_Reset (Data : String; Stream, Code : Natural; Name : String) is
      This   : Session;
      Output : Buffer;
   begin
      Open (This, Output);
      Send (This, Data, Output);
      Check (not Failed (This) and then Was_Reset (Output, Stream, Code), Name);
      Free (This);
      Free (Output);
   end Expect_Reset;

   procedure Session_Tests is
      This   : Session;
      Output : Buffer;
      Into   : Buffer;
      Item   : Event;
      Count  : Natural;
      Flags  : Natural;
   begin
      --  The server's preface: SETTINGS, then a connection window update.
      Start (This, Limits, Output);
      declare
         List  : Frame_List;
         Total : Natural;
      begin
         Parse_Frames (Content (Output), List, Total);
         Check (Total = 2 and then List (1).Kind = Settings_Kind and then List (2).Kind = Window_Kind,
                "the server's preface: SETTINGS and WINDOW_UPDATE");
      end;
      Free (This);

      --  A GET: one HEADERS frame with END_STREAM.
      Open (This, Output);
      Send (This, Frame (Headers_Kind, End_Stream + End_Headers, 1, Get_Block ("/a?b=c")), Output);
      Item := Next (This);
      Check (Item.Kind = Request_Ready and then Item.Stream = 1, "a GET is a whole request at once");
      Take_Request (This, Item.Place, Into);
      Equal (Content (Into), "GET /a?b=c HTTP/1.1" & CRLF & "Host: example.com" & CRLF & CRLF,
             "in HTTP/1.1 form, :authority as Host");

      --  The answer: HEADERS, then DATA as the window allows.
      Clear (Output);
      declare
         Body_Text : Buffer;
      begin
         Append (Body_Text, "hello");
         Respond (This, Item.Place, 200, "Content-Type: text/plain" & CRLF & "Connection: close" & CRLF, Body_Text,
                  5, Finished => True, Output => Output);
         Fill (This, Output, 65_536);
         declare
            Payload : Buffer;
            Table   : Hpack.Decoder := Hpack.New_Decoder;
            Result  : Hpack.Outcome;
         begin
            Frames_Of (Output, Headers_Kind, Count, Payload, Flags);
            Equal (Decoded (Table, Content (Payload), Result),
                   ":status: 200" & ASCII.LF & "content-type: text/plain" & ASCII.LF & "content-length: 5" & ASCII.LF,
                   "the response's head, lower case, without Connection");
            Frames_Of (Output, Data_Kind, Count, Payload, Flags);
            Check (Content (Payload) = "hello" and then Flags = End_Stream, "the body, ending the stream");
            Free (Payload);
         end;
      end;
      Check (Open_Streams (This) = 0, "the stream is closed");

      --  PING is echoed; SETTINGS are acknowledged.
      Clear (Output);
      Send (This, Frame (Ping_Kind, 0, 0, "12345678") & Frame (Settings_Kind, 0, 0, Setting (4, 100)), Output);
      Frames_Of (Output, Ping_Kind, Count, Into, Flags);
      Check (Count = 1 and then Flags = 1 and then Content (Into) = "12345678", "PING is echoed");
      Frames_Of (Output, Settings_Kind, Count, Into, Flags);
      Check (Count = 1 and then Flags = 1, "SETTINGS are acknowledged");
      Free (This);

      --  A POST with a body in two DATA frames, one padded.
      Open (This, Output);
      Send (This, Frame (Headers_Kind, End_Headers, 3, Post_Block ("content-length" & ASCII.LF & "11" & ASCII.LF))
            & Frame (Data_Kind, 0, 3, "hello"), Output);
      Item := Next (This);
      Check (Item.Kind = Head_Ready and then Head (This, Item.Place) =
               "POST /up HTTP/1.1" & CRLF & "Host: example.com" & CRLF & "content-length: 11" & CRLF,
             "a request with a body: its head first");
      Buffer_Body (This, Item.Place, Output);
      Send (This, Frame (Data_Kind, End_Stream + Padded, 3, Character'Val (3) & " world" & "pad"), Output);
      Item := Next (This);
      Check (Item.Kind = Request_Ready, "then the whole request");
      Take_Request (This, Item.Place, Into);
      Equal (Content (Into), "POST /up HTTP/1.1" & CRLF & "Host: example.com" & CRLF & "content-length: 11" & CRLF
                             & "Content-Length: 11" & CRLF & CRLF & "hello world", "its body, padding dropped");
      Free (This);

      --  Cookies are joined; trailers end the request and are dropped.
      Open (This, Output);
      Send (This, Frame (Headers_Kind, End_Headers, 1,
                         Post_Block ("cookie" & ASCII.LF & "a=1" & ASCII.LF & "cookie" & ASCII.LF & "b=2" & ASCII.LF))
            & Frame (Data_Kind, 0, 1, "x")
            & Frame (Headers_Kind, End_Stream + End_Headers, 1, Block ("x-trailer" & ASCII.LF & "1" & ASCII.LF)),
            Output);
      Item := Next (This);
      Buffer_Body (This, Item.Place, Output);
      Item := Next (This);
      Check (Item.Kind = Request_Ready, "trailers end the request");
      Take_Request (This, Item.Place, Into);
      Equal (Content (Into), "POST /up HTTP/1.1" & CRLF & "Host: example.com" & CRLF & "Cookie: a=1; b=2" & CRLF
                             & "Content-Length: 1" & CRLF & CRLF & "x", "cookies joined (RFC 9113 8.2.3)");
      Free (This);

      --  A header block in CONTINUATION frames.
      Open (This, Output);
      declare
         Whole : constant String := Get_Block;
      begin
         Send (This, Frame (Headers_Kind, End_Stream, 1, Whole (Whole'First .. Whole'First + 4))
               & Frame (Continuation_Kind, 0, 1, Whole (Whole'First + 5 .. Whole'First + 9))
               & Frame (Continuation_Kind, End_Headers, 1, Whole (Whole'First + 10 .. Whole'Last)), Output);
         Check (Next (This).Kind = Request_Ready, "a header block in CONTINUATION frames");
      end;
      Free (This);

      --  Flow control: the client's window holds the body back.
      Open (This, Output, Client_Settings => Setting (4, 3));
      Send (This, Frame (Headers_Kind, End_Stream + End_Headers, 1, Get_Block), Output);
      Item := Next (This);
      Clear (Output);
      declare
         Body_Text : Buffer;
      begin
         Append (Body_Text, "abcdefgh");
         Respond (This, Item.Place, 200, "", Body_Text, 8, Finished => True, Output => Output);
      end;
      Fill (This, Output, 65_536);
      Frames_Of (Output, Data_Kind, Count, Into, Flags);
      Check (Content (Into) = "abc" and then Flags = 0, "only what the stream's window allows");
      Clear (Output);
      Send (This, Frame (Window_Kind, 0, 1, Four (100)), Output);
      Fill (This, Output, 65_536);
      Frames_Of (Output, Data_Kind, Count, Into, Flags);
      Check (Content (Into) = "defgh" and then Flags = End_Stream, "the rest after WINDOW_UPDATE");
      Free (This);

      --  An event stream: open after its head, data as it is pushed, then its end.
      Open (This, Output);
      Send (This, Frame (Headers_Kind, End_Stream + End_Headers, 1, Get_Block ("/events")), Output);
      Item := Next (This);
      declare
         First_Piece : Buffer;
      begin
         Append (First_Piece, "data: 1" & ASCII.LF & ASCII.LF);
         Respond (This, Item.Place, 200, "Content-Type: text/event-stream" & CRLF, First_Piece, -1,
                  Finished => False, Output => Output);
      end;
      Push (This, Item.Place, "data: 2" & ASCII.LF & ASCII.LF);
      Clear (Output);
      Fill (This, Output, 65_536);
      Frames_Of (Output, Data_Kind, Count, Into, Flags);
      Check (Content (Into) = "data: 1" & ASCII.LF & ASCII.LF & "data: 2" & ASCII.LF & ASCII.LF and then Flags = 0
             and then Open_Streams (This) = 1, "an event stream stays open");
      Finish (This, Item.Place);
      Clear (Output);
      Fill (This, Output, 65_536);
      Frames_Of (Output, Data_Kind, Count, Into, Flags);
      Check (Count = 1 and then Flags = End_Stream and then Open_Streams (This) = 0, "and ends");
      Free (This);

      --  Limits: a body past Max_Body_Length is refused with 413, a head past Max_Head_Length with 431.
      Open (This, Output);
      Send (This, Frame (Headers_Kind, End_Headers, 1, Post_Block), Output);
      Item := Next (This);
      Buffer_Body (This, Item.Place, Output);
      Send (This, Frame (Data_Kind, End_Stream, 1, [1 .. 1001 => 'x']), Output);
      Item := Next (This);
      Check (Item.Kind = Refused and then Item.Status = 413, "a body too long: 413");
      Free (This);
      Open (This, Output);
      Send (This, Frame (Headers_Kind, End_Headers, 1, Post_Block ("content-length" & ASCII.LF & "5000" & ASCII.LF)),
            Output);
      Item := Next (This);
      Buffer_Body (This, Item.Place, Output);
      Item := Next (This);
      Check (Item.Kind = Refused and then Item.Status = 413, "a declared length too long: 413 at once");
      Free (This);
      Open (This, Output);
      Send (This, Frame (Headers_Kind, End_Stream + End_Headers, 1,
                         Block (":method" & ASCII.LF & "GET" & ASCII.LF & ":scheme" & ASCII.LF & "http" & ASCII.LF
                                & ":path" & ASCII.LF & "/" & ASCII.LF & "x-big" & ASCII.LF & [1 .. 5000 => 'b']
                                & ASCII.LF)), Output);
      Item := Next (This);
      Check (Item.Kind = Refused and then Item.Status = 431 and then not Failed (This), "a head too large: 431");
      Free (This);

      --  A stream the client resets after the server heard of it.
      Open (This, Output);
      Send (This, Frame (Headers_Kind, End_Stream + End_Headers, 1, Get_Block), Output);
      Item := Next (This);
      Send (This, Frame (Reset_Kind, 0, 1, Four (8)), Output);
      Item := Next (This);
      Check (Item.Kind = Stream_Reset and then Item.Stream = 1 and then Open_Streams (This) = 0,
             "a reset the server is told of");
      Free (This);

      --  More streams than announced are refused.
      Open (This, Output);
      for Index in 1 .. Max_Streams + 1 loop
         Send (This, Frame (Headers_Kind, End_Stream + End_Headers, 2 * Index - 1, Get_Block), Output);
      end loop;
      Check (Was_Reset (Output, 2 * Max_Streams + 1, Refused_Code) and then not Failed (This),
             "stream" & Natural'Image (Max_Streams + 1) & ": REFUSED_STREAM");
      Free (This);

      --  Graceful shutdown.
      Open (This, Output);
      Send (This, Frame (Headers_Kind, End_Stream + End_Headers, 1, Get_Block), Output);
      Go_Away (This, Output);
      Check (Went_Away (Output, No_Error_Code) and then Going_Away (This), "GOAWAY on shutdown");
      Clear (Output);
      Send (This, Frame (Headers_Kind, End_Stream + End_Headers, 3, Get_Block), Output);
      Check (Was_Reset (Output, 3, Refused_Code), "no new streams after it");
      Free (This);
      Free (Output);
      Free (Into);
   end Session_Tests;

   --  The cases of h2spec that end a stream or the connection, by RFC 9113 section.
   procedure Error_Tests is
      Get : constant String := Get_Block;
   begin
      --  3.4 and 3.5: the preface.
      declare
         This   : Session;
         Output : Buffer;
         Used   : Natural;
      begin
         Start (This, Limits, Output);
         Receive (This, "GET / HTTP/1.1" & CRLF & CRLF & "0123456789", Now, Used, Output);
         Check (Failed (This) and then Went_Away (Output, Protocol), "3.5: not the preface");
         Free (This);
         Free (Output);
      end;
      declare
         This   : Session;
         Output : Buffer;
         Used   : Natural;
      begin
         Start (This, Limits, Output);
         Receive (This, Preface & Frame (Ping_Kind, 0, 0, "12345678"), Now, Used, Output);
         Check (Failed (This) and then Went_Away (Output, Protocol), "3.4: the preface must end with SETTINGS");
         Free (This);
         Free (Output);
      end;

      --  4.1: unknown frame types and flags are ignored.
      declare
         This   : Session;
         Output : Buffer;
      begin
         Open (This, Output);
         Send (This, Frame (16#33#, 16#FF#, 0, "ignored") & Frame (Ping_Kind, 16#F0#, 0, "12345678"), Output);
         Check (not Failed (This), "4.1: an unknown frame type and unknown flags");
         Free (This);
         Free (Output);
      end;

      --  4.2: frame sizes.
      Expect_Goaway (Frame (Data_Kind, 0, 1, [1 .. 16_385 => 'x']), Frame_Size_Code, "4.2: a frame past 16384");
      Expect_Goaway (Frame (Ping_Kind, 0, 0, "1234567"), Frame_Size_Code, "6.7: PING of 7 bytes");
      Expect_Goaway (Frame (Settings_Kind, 0, 0, "12345"), Frame_Size_Code, "6.5: SETTINGS not of 6-byte entries");
      Expect_Goaway (Frame (Settings_Kind, 1, 0, Setting (4, 1)), Frame_Size_Code, "6.5: an ACK with a payload");
      Expect_Goaway (Frame (Reset_Kind, 0, 1, "123"), Frame_Size_Code, "6.4: RST_STREAM of 3 bytes");
      Expect_Goaway (Frame (Window_Kind, 0, 0, "123"), Frame_Size_Code, "6.9: WINDOW_UPDATE of 3 bytes");
      Expect_Reset (Frame (Priority_Kind, 0, 1, "1234"), 1, Frame_Size_Code, "6.3: PRIORITY of 4 bytes");

      --  4.3: the header compression.
      Expect_Goaway (Frame (Headers_Kind, End_Stream + End_Headers, 1, From_Hex ("be")), Compression,
                     "4.3: a block that does not decode");

      --  5.1: stream states.
      Expect_Goaway (Frame (Data_Kind, 0, 1, "x"), Protocol, "5.1: DATA on an idle stream");
      Expect_Goaway (Frame (Reset_Kind, 0, 1, Four (8)), Protocol, "5.1: RST_STREAM on an idle stream");
      Expect_Goaway (Frame (Window_Kind, 0, 1, Four (1)), Protocol, "5.1: WINDOW_UPDATE on an idle stream");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1, Get) & Frame (Data_Kind, 0, 1, "x"), 1, Closed,
                    "5.1: DATA after END_STREAM");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1, Get)
                    & Frame (Headers_Kind, End_Stream + End_Headers, 1, Get), 1, Closed,
                    "5.1: HEADERS after END_STREAM");
      Expect_Goaway (Frame (Headers_Kind, End_Stream + End_Headers, 5, Get)
                     & Frame (Headers_Kind, End_Stream + End_Headers, 3, Get), Closed,
                     "5.1.1: a stream number lower than one already used");
      Expect_Goaway (Frame (Headers_Kind, End_Stream + End_Headers, 2, Get), Protocol, "5.1.1: an even stream");

      --  5.3: priorities.
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers + Prioritised, 1, Four (1) & "x" & Get), 1,
                    Protocol, "5.3.1: HEADERS depending on its own stream");
      Expect_Reset (Frame (Priority_Kind, 0, 1, Four (1) & "x"), 1, Protocol,
                    "5.3.1: PRIORITY depending on its own stream");

      --  5.5: an unknown frame in a header block.
      Expect_Goaway (Frame (Headers_Kind, End_Stream, 1, Get) & Frame (16#33#, 0, 1, ""), Protocol,
                     "5.5: an unknown frame in a header block");

      --  6.1 and 6.2: padding, stream 0.
      Expect_Goaway (Frame (Data_Kind, 0, 0, "x"), Protocol, "6.1: DATA on stream 0");
      Expect_Goaway (Frame (Headers_Kind, End_Headers, 1, Post_Block) & Frame (Data_Kind, Padded, 1, Character'Val (5)
                     & "abc"), Protocol, "6.1: padding as long as the payload");
      Expect_Goaway (Frame (Headers_Kind, End_Stream + End_Headers, 0, Get), Protocol, "6.2: HEADERS on stream 0");
      Expect_Goaway (Frame (Headers_Kind, End_Stream + End_Headers + Padded, 1, Character'Val (200) & Get), Protocol,
                     "6.2: padding past the payload");

      --  6.4, 6.5, 6.6, 6.7, 6.8.
      Expect_Goaway (Frame (Reset_Kind, 0, 0, Four (8)), Protocol, "6.4: RST_STREAM on stream 0");
      Expect_Goaway (Frame (Settings_Kind, 0, 1, ""), Protocol, "6.5: SETTINGS on a stream");
      Expect_Goaway (Frame (Settings_Kind, 0, 0, Setting (2, 2)), Protocol, "6.5.2: ENABLE_PUSH of 2");
      Expect_Goaway (Frame (Settings_Kind, 0, 0, Setting (4, 2 ** 31)), Flow_Control,
                     "6.5.2: INITIAL_WINDOW_SIZE past 2^31-1");
      Expect_Goaway (Frame (Settings_Kind, 0, 0, Setting (5, 16_383)), Protocol, "6.5.2: MAX_FRAME_SIZE below 16384");
      Expect_Goaway (Frame (Settings_Kind, 0, 0, Setting (5, 2 ** 24)), Protocol, "6.5.2: MAX_FRAME_SIZE past 2^24-1");
      Expect_Goaway (Frame (Push_Kind, End_Headers, 1, Four (2) & Get), Protocol, "6.6: a client's PUSH_PROMISE");
      Expect_Goaway (Frame (Ping_Kind, 0, 1, "12345678"), Protocol, "6.7: PING on a stream");
      Expect_Goaway (Frame (Goaway_Kind, 0, 1, Four (0) & Four (0)), Protocol, "6.8: GOAWAY on a stream");

      --  6.9: windows.
      Expect_Goaway (Frame (Window_Kind, 0, 0, Four (0)), Protocol, "6.9: a connection increment of 0");
      Expect_Reset (Frame (Headers_Kind, End_Headers, 1, Post_Block) & Frame (Window_Kind, 0, 1, Four (0)), 1, Protocol,
                    "6.9: a stream increment of 0");
      Expect_Goaway (Frame (Window_Kind, 0, 0, Four (2 ** 31 - 1)), Flow_Control,
                     "6.9.1: a connection window overflow");
      Expect_Reset (Frame (Headers_Kind, End_Headers, 1, Post_Block) & Frame (Window_Kind, 0, 1, Four (2 ** 31 - 1)), 1,
                    Flow_Control, "6.9.1: a stream window overflow");
      Expect_Goaway (Frame (Headers_Kind, End_Headers, 1, Post_Block)
                     & Frame (Window_Kind, 0, 1, Four (1))
                     & Frame (Settings_Kind, 0, 0, Setting (4, 2 ** 31 - 1)), Flow_Control,
                     "6.9.2: SETTINGS that would push a stream's window past 2^31-1");

      --  6.10: CONTINUATION.
      Expect_Goaway (Frame (Continuation_Kind, End_Headers, 1, Get), Protocol, "6.10: CONTINUATION without HEADERS");
      Expect_Goaway (Frame (Headers_Kind, End_Stream, 1, Get) & Frame (Continuation_Kind, End_Headers, 3, ""), Protocol,
                     "6.10: CONTINUATION on another stream");
      Expect_Goaway (Frame (Headers_Kind, End_Stream, 1, Get) & Frame (Data_Kind, 0, 1, "x"), Protocol,
                     "6.10: DATA in a header block");

      --  8.1: malformed requests.
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1,
                           Block (":method" & ASCII.LF & "GET" & ASCII.LF & ":scheme" & ASCII.LF & "http" & ASCII.LF
                                  & "X-Upper" & ASCII.LF & "1" & ASCII.LF & ":path" & ASCII.LF & "/" & ASCII.LF)),
                    1, Protocol, "8.2: an upper-case name");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1,
                           Block (":method" & ASCII.LF & "GET" & ASCII.LF & ":scheme" & ASCII.LF & "http" & ASCII.LF
                                  & "x" & ASCII.LF & "1" & ASCII.LF & ":path" & ASCII.LF & "/" & ASCII.LF)),
                    1, Protocol, "8.3: a pseudo-header field after a regular one");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1,
                           Block (":method" & ASCII.LF & "GET" & ASCII.LF & ":scheme" & ASCII.LF & "http" & ASCII.LF)),
                    1, Protocol, "8.3.1: no :path");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1,
                           Get_Block & Block (":status" & ASCII.LF & "200" & ASCII.LF)),
                    1, Protocol, "8.3: a response's pseudo-header field");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1,
                           Block (":method" & ASCII.LF & "GET" & ASCII.LF & ":method" & ASCII.LF & "GET" & ASCII.LF
                                  & ":scheme" & ASCII.LF & "http" & ASCII.LF & ":path" & ASCII.LF & "/" & ASCII.LF)),
                    1, Protocol, "8.3.1: :method twice");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1,
                           Get_Block & Block ("connection" & ASCII.LF & "keep-alive" & ASCII.LF)),
                    1, Protocol, "8.2.2: a connection-specific field");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1,
                           Get_Block & Block ("te" & ASCII.LF & "gzip" & ASCII.LF)),
                    1, Protocol, "8.2.2: TE other than trailers");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1,
                           Get_Block & Block ("x" & ASCII.LF & "a" & ASCII.CR & ASCII.LF & "b" & ASCII.LF)),
                    1, Protocol, "8.2.1: a line break in a value");
      Expect_Reset (Frame (Headers_Kind, End_Stream + End_Headers, 1,
                           Get_Block & Block ("host" & ASCII.LF & "other.example" & ASCII.LF)),
                    1, Protocol, "8.3.1: Host that differs from :authority");
      Expect_Reset (Frame (Headers_Kind, End_Headers, 1, Post_Block ("content-length" & ASCII.LF & "1" & ASCII.LF))
                    & Frame (Data_Kind, End_Stream, 1, "ab"), 1, Protocol,
                    "8.1.1: a body longer than its content-length");
      Expect_Reset (Frame (Headers_Kind, End_Headers, 1, Post_Block ("content-length" & ASCII.LF & "3" & ASCII.LF))
                    & Frame (Data_Kind, End_Stream, 1, "ab"), 1, Protocol,
                    "8.1.1: a body shorter than its content-length");
      Expect_Reset (Frame (Headers_Kind, End_Headers, 1, Post_Block)
                    & Frame (Headers_Kind, End_Headers, 1, Block ("x" & ASCII.LF & "1" & ASCII.LF)), 1, Protocol,
                    "8.1: trailers that do not end the stream");

      --  Abuse: rapid reset, and a header block past every limit.
      declare
         Flood : Buffer;
      begin
         for Index in 1 .. 300 loop
            Append (Flood, Frame (Headers_Kind, End_Headers, 2 * Index - 1, Post_Block)
                    & Frame (Reset_Kind, 0, 2 * Index - 1, Four (8)));
         end loop;
         Expect_Goaway (Content (Flood), Calm, "CVE-2023-44487: streams opened and reset, fast");
         Clear (Flood);
         Append (Flood, Frame (Headers_Kind, 0, 1, Get));
         for Index in 1 .. 10 loop
            Append (Flood, Frame (Continuation_Kind, 0, 1, [1 .. 1000 => 'x']));
         end loop;
         Expect_Goaway (Content (Flood), Calm, "CVE-2024-27316: CONTINUATION without end");
         Free (Flood);
      end;
   end Error_Tests;

   ---------------------------------------------------------------------------------------------------------------
   --  a live server

   Port           : constant Port_Number := 18_479;
   Routes         : Sparrow.Http.Routers.Router (16);
   Server_Context : aliased Sparrow.Tls.Context;

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
         Sparrow.Http.Servers.Run
           (Settings => (Port => Port, Reactors => 2, Workers => 3, Catch_Signals => False, Access_Log => False,
                         Limits => (Max_Body_Length => 4 * 1_048_576, others => <>), others => <>),
            Routes   => Routes,
            Security => (if Use_Tls then Server_Context'Access else null));
      exception
         when Problem : others =>
            Ada.Text_IO.Put_Line ("server: " & Ada.Exceptions.Exception_Message (Problem));
            Failed := True;
      end;
      accept Finished (Problem : out Boolean) do
         Problem := Failed;
      end Finished;
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

   --  Through the curl program, whose HTTP/2 is nghttp2's: an implementation independent of this one. Skipped
   --  where curl is missing or built without HTTP/2.
   Scratch : constant String := "obj/curl-";

   function File_Text (Name : String) return String is
      use Ada.Streams.Stream_IO;
      File : File_Type;
   begin
      if not Ada.Directories.Exists (Name) then
         return "";
      end if;
      Open (File, In_File, Name);
      declare
         Text : String (1 .. Natural (Size (File)));
      begin
         String'Read (Stream (File), Text);
         Close (File);
         return Text;
      end;
   end File_Text;

   procedure Write_File (Name, Text : String) is
      use Ada.Streams.Stream_IO;
      File : File_Type;
   begin
      Create (File, Out_File, Name);
      String'Write (Stream (File), Text);
      Close (File);
   end Write_File;

   Curl_Program : constant GNAT.OS_Lib.String_Access := GNAT.OS_Lib.Locate_Exec_On_Path ("curl");

   function Curl_Has_Http_2 return Boolean is
      use type GNAT.OS_Lib.String_Access;
      Success : Boolean;
      Code    : Integer;
      Version : GNAT.OS_Lib.Argument_List := [1 => new String'("--version")];
   begin
      if Curl_Program = null then
         return False;
      end if;
      GNAT.OS_Lib.Spawn (Curl_Program.all, Version, Scratch & "version", Success, Code);
      GNAT.OS_Lib.Free (Version (1));
      return Success and then Code = 0
        and then Ada.Strings.Fixed.Index (File_Text (Scratch & "version"), " HTTP2") > 0;
   end Curl_Has_Http_2;

   type Curl_Answer is record
      Status  : Natural := 0;
      Version : Unbounded_String;   --  as curl names it: "2", "1.1"
      Head    : Unbounded_String;
      Content : Unbounded_String;
   end record;

   function Curl
     (Url : String; Secure : Boolean; Extra : GNAT.OS_Lib.Argument_List := []; Http_2 : Boolean := True)
      return Curl_Answer
   is
      use GNAT.OS_Lib;
      Common  : Argument_List :=
        [new String'("-s"), new String'("--max-time"), new String'("30"),
         new String'("--cacert"), new String'("data/cert.pem"),
         new String'(if not Http_2 then "--http1.1" elsif Secure then "--http2" else "--http2-prior-knowledge"),
         new String'("-o"), new String'(Scratch & "content"),
         new String'("-D"), new String'(Scratch & "head"),
         new String'("-w"), new String'("%{http_code} %{http_version}"),
         new String'(Url)];
      Success : Boolean;
      Code    : Integer;
      Result  : Curl_Answer;
   begin
      if Ada.Directories.Exists (Scratch & "content") then
         Ada.Directories.Delete_File (Scratch & "content");
      end if;
      if Ada.Directories.Exists (Scratch & "head") then
         Ada.Directories.Delete_File (Scratch & "head");
      end if;
      Spawn (Curl_Program.all, Common & Extra, Scratch & "written", Success, Code, Err_To_Out => False);
      for Item of Common loop
         Free (Item);
      end loop;
      if Success and then Code = 0 then
         declare
            Written : constant String := File_Text (Scratch & "written");
            Space   : constant Natural := Ada.Strings.Fixed.Index (Written, " ");
         begin
            if Space > Written'First then
               Result.Status  := Natural'Value (Written (Written'First .. Space - 1));
               Result.Version := To_Unbounded_String (Written (Space + 1 .. Written'Last));
            end if;
         end;
         Result.Head    := To_Unbounded_String (File_Text (Scratch & "head"));
         Result.Content := To_Unbounded_String (File_Text (Scratch & "content"));
      end if;
      return Result;
   end Curl;

   --  Whether Head has the header line Name (lower case, as HTTP/2 sends it), with a value.
   function Has_Header (Head : Unbounded_String; Name : String) return Boolean is
     (Ada.Strings.Fixed.Index (To_String (Head), ASCII.LF & Name & ": ") > 0);

   procedure Client_Tests (Secure : Boolean) is
      use GNAT.OS_Lib;
      Base   : constant String := (if Secure then "https" else "http") & "://localhost:18479";
      Kind   : constant String := (if Secure then " (TLS, ALPN)" else " (prior knowledge)");
      Answer : Curl_Answer;
   begin
      if not Curl_Has_Http_2 then
         Ada.Text_IO.Put_Line ("skipped: HTTP/2 through the curl program, which is missing or has no HTTP/2");
         return;
      end if;
      Answer := Curl (Base & "/hello", Secure);
      Check (Answer.Status = 200 and then Answer.Content = "hello" and then Answer.Version = "2",
             "a GET over HTTP/2" & Kind);
      Answer := Curl (Base & "/who/ada", Secure);
      Check (Answer.Content = "worker ada" and then Has_Header (Answer.Head, "content-type"),
             "a worker's answer" & Kind);
      Answer := Curl (Base & "/nowhere", Secure);
      Check (Answer.Status = 404, "404" & Kind);
      declare
         Large : String (1 .. 3_000_000);
         Data  : Argument_List := [new String'("--data-binary"), new String'("@" & Scratch & "large")];
      begin
         for Index in Large'Range loop
            Large (Index) := Character'Val (Index * 7 mod 256);
         end loop;
         Write_File (Scratch & "large", Large);
         Answer := Curl (Base & "/echo", Secure, Data);
         Check (Answer.Status = 200 and then Answer.Content = Large, "3 MB each way, past both windows" & Kind);
         Answer := Curl (Base & "/upload", Secure, Data);
         Check (Answer.Status = 200 and then Length (Answer.Content) > 8
                and then Slice (Answer.Content, 1, 8) = "3000000 ",
                "a streamed upload, read as it comes" & Kind);
         for Item of Data loop
            Free (Item);
         end loop;
      end;
      Answer := Curl (Base & "/count", Secure);
      Check (Answer.Content = "one;two;three;", "a streamed response, pushes held until its head" & Kind);
      declare
         Compressed : Argument_List := [1 => new String'("--compressed")];
      begin
         Answer := Curl (Base & "/text", Secure, Compressed);
         Check (Answer.Status = 200 and then Has_Header (Answer.Head, "content-encoding")
                and then Answer.Content = Long_Text, "a gzip response" & Kind);
         Free (Compressed (1));
      end;
      declare
         Ranged : Argument_List := [new String'("-H"), new String'("Range: bytes=2-5")];
      begin
         Answer := Curl (Base & "/files/cert.pem", Secure, Ranged);
         Check (Answer.Status = 206 and then Answer.Content = "---B" and then Has_Header (Answer.Head, "content-range"),
                "a range" & Kind);
         for Item of Ranged loop
            Free (Item);
         end loop;
      end;
      Answer := Curl (Base & "/hello", Secure, Http_2 => False);
      Check (Answer.Status = 200 and then Answer.Version = "1.1", "HTTP/1.1 still, on the same port" & Kind);
   end Client_Tests;

   --  Many streams at once on one connection, from a client of a few lines: their answers come back each on
   --  its own stream, however they interleave; a stream reset meanwhile does not disturb the others.
   function Image (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   procedure Multiplexing_Tests is
      Socket   : Descriptor;
      Failure  : Error;
      Count    : Integer;
      Request  : Buffer;
      Received : Buffer;
      Streams  : constant := 60;
      Done     : array (1 .. Streams) of Boolean := [others => False];
      Bodies   : array (1 .. Streams) of Buffer;
      Ended    : Natural := 0;
      Reset_Seen : Boolean := False;
   begin
      Connect (Loopback, Port, Socket, Failure, Timeout => 5_000);
      Append (Request, Preface & Frame (Settings_Kind, 0, 0, ""));
      for Index in 1 .. Streams loop
         Append (Request, Frame (Headers_Kind, End_Stream + End_Headers, 2 * Index - 1,
                                 Get_Block ((if Index mod 3 = 0 then "/hello" elsif Index = 7 then "/slow/x"
                                             else "/who/n" & Image (Index)))));
      end loop;
      Append (Request, Frame (Reset_Kind, 0, 13, Four (8)));   --  stream 13 (/slow) is cancelled
      Send (Socket, Content (Request), Count, Failure);
      Free (Request);

      --  Read frames until every stream but the cancelled one has ended (or the server stops answering).
      while Ended < Streams - 1 loop
         declare
            Part : String (1 .. 65_536);
         begin
            Receive (Socket, Part, Count, Failure);
            exit when Count <= 0;
            Append (Received, Part (1 .. Count));
         end;
         loop
            declare
               Text : constant String := Content (Received);
               Length : Natural;
            begin
               exit when Text'Length < 9;
               Length := Character'Pos (Text (1)) * 65_536 + Character'Pos (Text (2)) * 256 + Character'Pos (Text (3));
               exit when Text'Length < 9 + Length;
               declare
                  Kind   : constant Natural := Character'Pos (Text (4));
                  Flags  : constant Natural := Character'Pos (Text (5));
                  Stream : constant Natural := Character'Pos (Text (8)) * 256 + Character'Pos (Text (9));
                  Index  : constant Natural := (Stream + 1) / 2;
               begin
                  if Kind = Data_Kind and then Index in 1 .. Streams then
                     Append (Bodies (Index), Text (10 .. 9 + Length));
                     if Flags mod 2 = 1 then
                        Done (Index) := True;
                        Ended := Ended + 1;
                     end if;
                  elsif Kind = Reset_Kind or else Kind = Goaway_Kind then
                     Reset_Seen := True;
                  end if;
                  Consume (Received, 9 + Length);
               end;
            end;
         end loop;
      end loop;
      Close (Socket);

      Check (Ended = Streams - 1 and then not Done (7) and then not Reset_Seen,
             Natural'Image (Streams) & " streams at once, one cancelled: the rest answered");
      Check ((for all Index in 1 .. Streams =>
                Index = 7
                or else Content (Bodies (Index)) =
                        (if Index mod 3 = 0 then "hello" else "worker n" & Image (Index))),
             "each answer on its own stream");
      for Item of Bodies loop
         Free (Item);
      end loop;
      Free (Received);
   end Multiplexing_Tests;

   procedure Live_Tests is
      Server  : Server_Task;
      Problem : Boolean;
   begin
      Sparrow.Http.Routers.Add (Routes, Get, "/hello", Hello'Access, Sparrow.Http.Routers.On_Reactor);
      Sparrow.Http.Routers.Add (Routes, Get, "/who/:name", Who'Access);
      Sparrow.Http.Routers.Add (Routes, Get, "/slow/:name", Slow'Access);
      Sparrow.Http.Routers.Add (Routes, Post, "/echo", Echo'Access);
      Sparrow.Http.Routers.Add (Routes, Get, "/count", Count_Up'Access);
      Sparrow.Http.Routers.Add (Routes, Get, "/text", Long_Text_Route'Access);
      Sparrow.Http.Routers.Add (Routes, Get, "/files/*file", Sparrow.Http.Static.Folder ("data"));
      Sparrow.Http.Routers.Add (Routes, Post, "/upload", Upload_Sum'Access,
                                Body_Mode => Sparrow.Http.Routers.Streamed);

      Server.Start (Secure => False);
      Await_Server;
      Client_Tests (Secure => False);
      Multiplexing_Tests;
      Sparrow.Http.Servers.Stop;
      Server.Finished (Problem);
      Check (not Problem, "the plain server stops cleanly");

      Sparrow.Tls.Open_Server (Server_Context, "data/cert.pem", "data/key.pem");
      declare
         Secure_Server : Server_Task;
      begin
         Secure_Server.Start (Secure => True);
         Await_Server;
         Client_Tests (Secure => True);
         Sparrow.Http.Servers.Stop;
         Secure_Server.Finished (Problem);
         Check (not Problem, "the TLS server stops cleanly");
      end;
   end Live_Tests;

begin
   Hpack_Tests;
   Session_Tests;
   Error_Tests;
   Live_Tests;
   Finish ("http2");
end Http_2_Tests;
