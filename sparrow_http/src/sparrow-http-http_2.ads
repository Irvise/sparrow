--  HTTP/2 (RFC 9113) for the server side of one connection, as a state machine without input or output: the
--  server hands it the bytes it reads, sends the bytes it writes, and takes requests from it as they complete.
--
--  Requests come out in HTTP/1.1 form (a request line, header lines and the body with its Content-Length), so
--  that the proved HTTP/1.1 parser (Sparrow.Http.Requests) reads them exactly as it reads any other: what a
--  handler sees does not depend on the protocol. Header fields are checked as RFC 9113 8.2 requires on the way
--  (lower-case names, no connection-specific fields, no line breaks), and the parser checks them again.
--
--  Each stream takes a lane, one of Max_Streams: the most streams a client may have open at once, as the server
--  announces in its SETTINGS. A lane is free again once its stream has closed and the server has heard of it.
--
--  What the client may send is bounded: header blocks by Max_Head_Length, bodies by Max_Body_Length (or by the
--  window when streamed), resets by a rate, and control frames that need an answer by Max_Pending_Output on the
--  server's side. Protocol errors end the stream or the connection as RFC 9113 5.4 says.
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Http.Hpack;
with Sparrow.Http.Parser;
with Sparrow.Times;

package Sparrow.Http.Http_2 with SPARK_Mode is

   --  What a client sends first (RFC 9113 3.4), before its SETTINGS.
   Preface : constant String :=
     "PRI * HTTP/2.0" & ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF & "SM" & ASCII.CR & ASCII.LF & ASCII.CR & ASCII.LF;

   Max_Streams : constant := 100;      --  SETTINGS_MAX_CONCURRENT_STREAMS
   Frame_Size  : constant := 16_384;   --  the largest frame payload either side sends (the protocol's default)

   type Stream_Id is range 0 .. 2 ** 31 - 1;
   subtype Lane is Positive range 1 .. Max_Streams;

   type Session is limited private;

   --  Ready a session for a new connection, and queue the server's SETTINGS (the server's preface) on Output.
   procedure Start (This : in out Session; Limits : Parser.Limits; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output);

   --  Handle the whole frames at the start of Input: Used is how many bytes that was (the rest is an incomplete
   --  frame: keep it, and call again when more has come). Answers to the client (SETTINGS and PING
   --  acknowledgements, window updates, resets, GOAWAY) are appended to Output. Now is the time in milliseconds,
   --  for the reset rate.
   procedure Receive
     (This   : in out Session;
      Input  : String;
      Now    : Times.Milliseconds;
      Used   : out Natural;
      Output : in out Buffer)
      with Pre  => Valid (Output) and then Input'First >= 1 and then Input'Last in Input'First - 1 .. Positive'Last - 1,
           Post => Valid (Output) and then Used <= Input'Length;

   --  A connection error happened: GOAWAY is on Output. Send it, then close the connection.
   function Failed (This : Session) return Boolean;

   --  The client said GOAWAY, or the server is shutting down: no new streams.
   function Going_Away (This : Session) return Boolean;

   --  Streams open (with a lane): when 0 and Going_Away, the connection is done.
   function Open_Streams (This : Session) return Natural;

   ---------------------------------------------------------------------------------------------------------------
   --  What came in, in order.

   type Event_Kind is
     (No_Event,
      Head_Ready,      --  a request's headers, and its body is still coming: say how to take it
      Request_Ready,   --  a whole request: Take_Request
      Refused,         --  a request to answer with Status without a handler (413, 431, 400)
      Body_Ready,      --  a streamed body has bytes to Take_Body, or has ended
      Stream_Reset);   --  the stream is gone (the client reset it, or broke the protocol): drop what it was owed

   type Event is record
      Kind   : Event_Kind := No_Event;
      Place  : Lane := 1;
      Stream : Stream_Id := 0;
      Status : Status_Code := OK;   --  Refused
   end record;

   procedure Next_Event (This : in out Session; Item : out Event);

   --  The lane Stream holds; 0 when it holds none (it has closed).
   function Place_Of (This : Session; Stream : Stream_Id) return Natural
      with Post => Place_Of'Result <= Max_Streams;

   --  Whether Stream still holds Place: an event or response for a stream that has closed meanwhile is dropped.
   function Holds (This : Session; Place : Lane; Stream : Stream_Id) return Boolean;

   --  Head_Ready: the request line and header lines (each ending in CRLF, with the client's Content-Length if it
   --  gave one), without the blank line after them.
   function Head (This : Session; Place : Lane) return String;

   --  Head_Ready: keep the body in memory, and say Request_Ready when it is whole (or Refused past
   --  Max_Body_Length).
   procedure Buffer_Body (This : in out Session; Place : Lane; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output);

   --  Head_Ready: hand the body over as it comes (Body_Ready events), at most Max_Streamed_Length bytes.
   procedure Stream_Body (This : in out Session; Place : Lane);

   --  Request_Ready: the request in HTTP/1.1 form, moved into Into (which is emptied first).
   procedure Take_Request (This : in out Session; Place : Lane; Into : in out Buffer)
      with Pre => Valid (Into), Post => Valid (Into);

   --  A streamed body: the bytes received and not yet taken.
   function Received (This : Session; Place : Lane) return String;

   --  A streamed body: Count of the Received bytes were taken; the client may send that many more.
   procedure Take_Body (This : in out Session; Place : Lane; Count : Natural; Output : in out Buffer)
      with Pre => Valid (Output) and then Count <= Received (This, Place)'Length, Post => Valid (Output);

   --  A streamed body: the client sent all of it and all of it was taken.
   function Body_Ended (This : Session; Place : Lane) return Boolean;

   --  A streamed body: it was longer than Max_Streamed_Length.
   function Body_Too_Long (This : Session; Place : Lane) return Boolean;

   ---------------------------------------------------------------------------------------------------------------
   --  Answers. Header_Lines are header lines as Responses keeps them ("Name: value" CRLF each); names are put in
   --  lower case and connection-specific ones (Connection, Keep-Alive, Transfer-Encoding, Upgrade) dropped.

   --  Send the response's head, then Content (moved out; it is empty after). Content_Length < 0 sends none.
   --  Finished: the stream ends with Content; otherwise it stays open for Push and Finish (an event stream).
   procedure Respond
     (This           : in out Session;
      Place          : Lane;
      Status         : Status_Code;
      Header_Lines   : String;
      Content        : in out Buffer;
      Content_Length : Long_Long_Integer;
      Finished       : Boolean;
      Output         : in out Buffer)
      with Pre  => Valid (Content) and then Valid (Output) and then Header_Lines'First >= 1
                   and then Header_Lines'Last < Positive'Last - 2,
           Post => Valid (Content) and then Valid (Output);

   --  More of an open response's body.
   procedure Push (This : in out Session; Place : Lane; Data : String);

   --  End an open response.
   procedure Finish (This : in out Session; Place : Lane);

   --  Bytes of open responses waiting to be sent, across streams.
   function Pending_Data (This : Session) return Natural;

   --  Move response bodies into Output as DATA frames, as far as the client's windows allow, until Output holds
   --  at least Limit bytes.
   procedure Fill (This : in out Session; Output : in out Buffer; Limit : Natural)
      with Pre => Valid (Output), Post => Valid (Output);

   --  Shut down gracefully: GOAWAY (no error) naming the last stream that will be answered.
   procedure Go_Away (This : in out Session; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output);

   --  Release every buffer.
   procedure Free (This : in out Session);

private

   type Body_Handling is (Undecided, Buffered, Streamed);

   --  A buffer the session holds: always Valid, which every Buffers operation keeps.
   subtype Held_Buffer is Buffer with Dynamic_Predicate => Valid (Held_Buffer);

   Largest_Window    : constant := 2 ** 31 - 1;
   Connection_Window : constant := 16_777_216;   --  the connection's receive window, raised to this at the start

   --  A flow-control window: a stream's send window may go below zero when the client lowers its initial size.
   subtype Window_Size is Long_Long_Integer range -Largest_Window .. Largest_Window;
   subtype Body_Total is Long_Long_Integer range 0 .. 2 ** 62;

   type Stream_Record is record
      Id              : Stream_Id := 0;          --  0: the lane is free
      Receiving       : Boolean := False;        --  the client may send more (no END_STREAM yet)
      Sending         : Boolean := False;        --  the response is not finished
      Responded       : Boolean := False;        --  its head went out
      Reported        : Boolean := False;        --  the server heard of it: it must hear of a reset too
      Discarding      : Boolean := False;        --  refused: its body is thrown away
      Handling        : Body_Handling := Undecided;
      Head            : Held_Buffer;                  --  the request line and header lines
      Content         : Held_Buffer;                  --  body bytes received, not yet taken
      Declared_Length : Long_Long_Integer range -1 .. 10 ** 18 := -1;   --  its content-length, if any
      Received_Total  : Body_Total := 0;
      Receive_Window  : Window_Size := 0;        --  what the client may still send on it
      Send_Window     : Window_Size := 0;        --  what the server may still send on it
      Output          : Held_Buffer;             --  response body not yet sent
      Output_Sent     : Natural := 0;
      End_After       : Boolean := False;        --  END_STREAM once Output is all sent
   end record;

   type Stream_Array is array (Lane) of Stream_Record;

   Max_Events : constant := 4 * Max_Streams;
   type Event_Position is mod Max_Events;
   type Event_Ring is array (Event_Position) of Event;

   type Session is limited record
      Limits             : Parser.Limits;
      Decoder            : Hpack.Decoder;
      Streams            : Stream_Array;
      Open_Count         : Natural range 0 .. Max_Streams := 0;
      Events             : Event_Ring;
      First_Event        : Event_Position := 0;
      Event_Count        : Natural range 0 .. Max_Events := 0;
      Preface_Seen       : Boolean := False;
      Settings_Seen      : Boolean := False;   --  the client's first frame must be SETTINGS
      Failed             : Boolean := False;
      Going_Away         : Boolean := False;
      Last_Client_Stream : Stream_Id := 0;     --  the highest stream the client opened
      --  a header block arriving in CONTINUATION frames
      Block              : Held_Buffer;
      Block_Stream       : Stream_Id := 0;     --  0: none in progress
      Block_Ends_Stream  : Boolean := False;
      Block_Is_Trailer   : Boolean := False;
      Block_Ignored      : Boolean := False;   --  its stream was refused: decode it for the table only
      --  flow control
      Receive_Window     : Window_Size := 65_535;   --  the connection's, as the client sees it
      Receive_Credit     : Long_Long_Integer range 0 .. Connection_Window / 2 := 0;   --  received, not given back
      Send_Window        : Window_Size := 65_535;
      Peer_Initial       : Long_Long_Integer range 0 .. Largest_Window := 65_535;   --  its INITIAL_WINDOW_SIZE
      Next_Lane          : Lane := 1;                     --  Fill starts here, so that streams take turns
      --  resets the client caused, for the rapid-reset attack (CVE-2023-44487)
      Reset_Window_Start : Times.Milliseconds := 0;
      Resets_In_Window   : Natural range 0 .. 1_000 := 0;
   end record;

end Sparrow.Http.Http_2;
