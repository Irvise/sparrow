--  A response as a handler builds it: a status, extra headers, and the body in a Buffer.
--
--  Content is the seam to everything that renders: Sparrow.Json.Writers, Sparrow.Templates, or any other
--  engine that can append to a Sparrow.Buffers.Buffer. The server adds Content-Length, Date and Connection.
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Times;

package Sparrow.Http.Responses with SPARK_Mode is

   --  Whole: Content is the body. Stream: the head goes out now, Content as the first piece, and the connection
   --  stays open for Sparrow.Http.Streams to send more. Upgrade: the connection becomes a WebSocket (set by
   --  Sparrow.Http.Websockets).
   type Response_Mode is (Whole, Stream, Upgrade);

   type Response is record
      Status    : Status_Code := OK;
      Headers   : Buffer;                 --  whole header lines, each ending in CRLF; use Set_Header
      Content   : aliased Buffer;         --  the body (aliased for a Json.Builders.Builder)
      Close     : Boolean := False;       --  close the connection once this response is out
      Mode      : Response_Mode := Whole;
      Heartbeat : Boolean := False;       --  Stream: send an empty event when quiet (event streams)
      Endpoint  : Natural := 0;           --  Upgrade: which WebSocket endpoint
   end record;

   function Valid (This : Response) return Boolean is (Valid (This.Headers) and then Valid (This.Content));

   --  Add a header line. Dropped when Name or Value could not be one (a line break, an empty name).
   procedure Set_Header (This : in out Response; Name, Value : String)
      with Pre => Valid (This), Post => Valid (This);

   procedure Set_Content_Type (This : in out Response; Media_Type : String)
      with Pre => Valid (This), Post => Valid (This);

   --  The value of the first header line named Name (in any case), without blanks at either end; "" if none.
   function Header (This : Response; Name : String) return String
      with Pre => Valid (This);

   --  Every header line named Name (in any case) taken out.
   procedure Remove_Header (This : in out Response; Name : String)
      with Pre => Valid (This), Post => Valid (This);

   type Same_Site_Policy is (Strict, Lax, None);

   --  Max_Age in seconds; 0 makes a session cookie, a negative one deletes the cookie.
   procedure Set_Cookie
     (This      : in out Response;
      Name      : String;
      Value     : String;
      Max_Age   : Integer := 0;
      Path      : String := "/";
      Http_Only : Boolean := True;
      Secure    : Boolean := True;
      Same_Site : Same_Site_Policy := Lax)
      with Pre => Valid (This), Post => Valid (This);

   --  Whole responses: the status, the content type and Text as the body, replacing any content so far.
   procedure Send
     (This       : in out Response;
      Status     : Status_Code;
      Text       : UTF8_String;
      Media_Type : String := Text_Plain)
      with Pre => Valid (This), Post => Valid (This);

   --  Start a body to write straight into This.Content (with a Json.Writers.Writer, a template's Render, or
   --  Append): the status and content type set, any content so far dropped.
   procedure Begin_Content (This : in out Response; Status : Status_Code; Media_Type : String)
      with Pre => Valid (This), Post => Valid (This) and then This.Content.Length = 0;

   --  Answer with a stream: the head now (chunked, no length), then whatever Sparrow.Http.Streams.Send sends
   --  to Requests.Connection (Request), until Streams.Close or the client leaves. Content may hold the first piece.
   procedure Begin_Stream (This : in out Response; Media_Type : String; Status : Status_Code := OK)
      with Pre => Valid (This), Post => Valid (This) and then This.Content.Length = 0;

   --  The same for a body that is not text; say what it is.
   procedure Send_Bytes
     (This       : in out Response;
      Status     : Status_Code;
      Content    : String;
      Media_Type : String)
      with Pre => Valid (This), Post => Valid (This);

   --  The status with its reason phrase as a plain-text body.
   procedure Fail (This : in out Response; Status : Status_Code)
      with Pre => Valid (This), Post => Valid (This);

   procedure Redirect (This : in out Response; Location : String; Status : Status_Code := See_Other)
      with Pre => Valid (This), Post => Valid (This);

   --  Back to an empty 200, keeping the buffers' storage.
   procedure Clear (This : in out Response)
      with Pre => Valid (This), Post => Valid (This);

   procedure Free (This : in out Response) with Post => Valid (This);

   --  The status line and every header line through the blank line, as the server sends them. Now is the
   --  Date header's time.
   procedure Write_Head
     (This       : Response;
      Into       : in out Buffer;
      Now        : Sparrow.Times.Unix_Seconds;
      Keep_Alive : Boolean)
      with Pre => Valid (This) and then Valid (Into), Post => Valid (Into);

end Sparrow.Http.Responses;
