with Sparrow.Encoding;

package body Sparrow.Http.Responses with SPARK_Mode is

   --  Whether Text can go in a header line as it is: no line break and no other control character, which is
   --  what keeps a value taken from a request from adding headers of its own.
   function Fits_Line (Text : String) return Boolean is
     (for all Symbol of Text => Symbol = ASCII.HT or else (Symbol >= ' ' and then Symbol /= ASCII.DEL));

   function Is_Name (Text : String) return Boolean is
     (Text'Length > 0
      and then (for all Symbol of Text =>
                  Symbol in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '!' | '#' | '$' | '%' | '&'
                          | ''' | '*' | '+' | '^' | '`' | '|' | '~'));

   ----------------
   -- Set_Header --
   ----------------

   procedure Set_Header (This : in out Response; Name, Value : String) is begin
      if Is_Name (Name) and then Fits_Line (Value) then
         Append (This.Headers, Name);
         Append (This.Headers, ": ");
         Append (This.Headers, Value);
         Append (This.Headers, CRLF);
      end if;
   end Set_Header;

   procedure Set_Content_Type (This : in out Response; Media_Type : String) is begin
      Set_Header (This, "Content-Type", Media_Type);
   end Set_Content_Type;

   ------------
   -- Header --
   ------------

   --  Where the line starting at Start ends (its CR), or Text'Last + 1 when it has no CRLF.
   function Line_End (Text : String; Start : Positive) return Positive
      with Pre  => Text'Last < Positive'Last and then Start >= Text'First and then Start <= Text'Last,
           Post => Line_End'Result in Start .. Text'Last + 1
   is
   begin
      for Index in Start .. Text'Last - 1 loop
         if Text (Index) = ASCII.CR and then Text (Index + 1) = ASCII.LF then
            return Index;
         end if;
      end loop;
      return Text'Last + 1;
   end Line_End;

   --  Whether the line Text (Start .. Stop - 1) is a header named Name; Colon is where its colon is, or 0.
   function Colon_Of (Text : String; Start, Stop : Positive) return Natural
      with Pre  => Text'Last < Positive'Last and then Start >= Text'First and then Stop <= Text'Last + 1,
           Post => Colon_Of'Result = 0 or else Colon_Of'Result in Start .. Stop - 1
   is
   begin
      for Index in Start .. Stop - 1 loop
         if Text (Index) = ':' then
            return Index;
         end if;
      end loop;
      return 0;
   end Colon_Of;

   function Header (This : Response; Name : String) return String is
      Text  : constant String := Content (This.Headers);
      Start : Positive := 1;
   begin
      while Start <= Text'Last loop
         pragma Loop_Variant (Increases => Start);
         declare
            Stop  : constant Positive := Line_End (Text, Start);
            Colon : constant Natural := Colon_Of (Text, Start, Stop);
         begin
            if Colon > 0 and then Encoding.Equal_Ignoring_Case (Text (Start .. Colon - 1), Name) then
               declare
                  First : Positive := Colon + 1;
                  Last  : Natural := Stop - 1;
               begin
                  while First <= Last and then Text (First) in ' ' | ASCII.HT loop
                     pragma Loop_Invariant (First in Colon + 1 .. Last);
                     pragma Loop_Variant (Increases => First);
                     First := First + 1;
                  end loop;
                  while Last >= First and then Text (Last) in ' ' | ASCII.HT loop
                     pragma Loop_Invariant (Last in First .. Stop - 1);
                     pragma Loop_Variant (Decreases => Last);
                     Last := Last - 1;
                  end loop;
                  return Text (First .. Last);
               end;
            end if;
            exit when Stop > Text'Last - 2;
            Start := Stop + 2;
         end;
      end loop;
      return "";
   end Header;

   procedure Remove_Header (This : in out Response; Name : String) is
      Text  : constant String := Content (This.Headers);
      Start : Positive := 1;
   begin
      Clear (This.Headers);
      while Start <= Text'Last loop
         pragma Loop_Invariant (Valid (This));
         pragma Loop_Variant (Increases => Start);
         declare
            Stop  : constant Positive := Line_End (Text, Start);
            Colon : constant Natural := Colon_Of (Text, Start, Stop);
         begin
            if Colon = 0 or else not Encoding.Equal_Ignoring_Case (Text (Start .. Colon - 1), Name) then
               Append (This.Headers, Text (Start .. Stop - 1));
               Append (This.Headers, CRLF);
            end if;
            exit when Stop > Text'Last - 2;
            Start := Stop + 2;
         end;
      end loop;
   end Remove_Header;

   ----------------
   -- Set_Cookie --
   ----------------

   procedure Set_Cookie
     (This      : in out Response;
      Name      : String;
      Value     : String;
      Max_Age   : Integer := 0;
      Path      : String := "/";
      Http_Only : Boolean := True;
      Secure    : Boolean := True;
      Same_Site : Same_Site_Policy := Lax)
   is
      --  RFC 6265 cookie-octet: no blanks, quotes, commas, semicolons or backslashes.
      function Cookie_Safe (Text : String) return Boolean is
        (for all Symbol of Text => Symbol in '!' | '#' .. '+' | '-' .. ':' | '<' .. '[' | ']' .. '~');
   begin
      if not Is_Name (Name) or else not Cookie_Safe (Value) or else not Cookie_Safe (Path)
        or else Name'Length > 4096 or else Value'Length > 4096 or else Path'Length > 4096   --  browsers keep 4 KiB
      then
         return;
      end if;

      declare
         Cookie_Name : constant String (1 .. Name'Length) := Name;   --  the header is indexed from 1
      begin
         Set_Header
           (This, "Set-Cookie",
            Cookie_Name & "=" & Value & "; Path=" & Path
            & (if Max_Age > 0 then "; Max-Age=" & Encoding.Decimal_Image (Long_Long_Integer (Max_Age))
               elsif Max_Age < 0 then "; Max-Age=0"
               else "")
            & (if Http_Only then "; HttpOnly" else "")
            & (if Secure or else Same_Site = None then "; Secure" else "")   --  browsers refuse None without Secure
            & "; SameSite=" & (case Same_Site is when Strict => "Strict", when Lax => "Lax", when None => "None"));
      end;
   end Set_Cookie;

   ----------
   -- Send --
   ----------

   procedure Send
     (This       : in out Response;
      Status     : Status_Code;
      Text       : UTF8_String;
      Media_Type : String := Text_Plain)
   is begin
      This.Status := Status;
      Set_Content_Type (This, Media_Type);
      Buffers.Clear (This.Content);
      Append_Text (This.Content, Text);
   end Send;

   procedure Begin_Content (This : in out Response; Status : Status_Code; Media_Type : String) is begin
      This.Status := Status;
      Set_Content_Type (This, Media_Type);
      Buffers.Clear (This.Content);
   end Begin_Content;

   procedure Send_Bytes
     (This       : in out Response;
      Status     : Status_Code;
      Content    : String;
      Media_Type : String)
   is begin
      This.Status := Status;
      Set_Content_Type (This, Media_Type);
      Buffers.Clear (This.Content);
      Append (This.Content, Content);
   end Send_Bytes;

   procedure Fail (This : in out Response; Status : Status_Code) is begin
      --  Reason phrases are ASCII.
      Send (This, Status, UTF8_String (Reason_Phrase (Status)) & UTF8_String'(1 => ASCII.LF));
   end Fail;

   procedure Redirect (This : in out Response; Location : String; Status : Status_Code := See_Other) is begin
      if Fits_Line (Location) then
         This.Status := Status;
         Set_Header (This, "Location", Location);
         Buffers.Clear (This.Content);
      else
         Fail (This, Internal_Server_Error);
      end if;
   end Redirect;

   procedure Begin_Stream (This : in out Response; Media_Type : String; Status : Status_Code := OK) is begin
      Begin_Content (This, Status, Media_Type);
      This.Mode := Stream;
   end Begin_Stream;

   procedure Clear (This : in out Response) is begin
      This.Status    := OK;
      This.Close     := False;
      This.Mode      := Whole;
      This.Heartbeat := False;
      This.Endpoint  := 0;
      Buffers.Clear (This.Headers);
      Buffers.Clear (This.Content);
   end Clear;

   procedure Free (This : in out Response) is begin
      This.Status    := OK;
      This.Close     := False;
      This.Mode      := Whole;
      This.Heartbeat := False;
      This.Endpoint  := 0;
      Buffers.Free (This.Headers);
      Buffers.Free (This.Content);
   end Free;

   ----------------
   -- Write_Head --
   ----------------

   procedure Write_Head
     (This       : Response;
      Into       : in out Buffer;
      Now        : Sparrow.Times.Unix_Seconds;
      Keep_Alive : Boolean)
   is
      Code : constant String := Encoding.Decimal_Image (Long_Long_Integer (This.Status));
   begin
      Append (Into, "HTTP/1.1 ");
      Append (Into, Code);
      Append (Into, ' ');
      Append (Into, Reason_Phrase (This.Status));
      Append (Into, CRLF);
      Append (Into, "Date: ");
      Append (Into, Sparrow.Times.Http_Date (Now));
      Append (Into, CRLF);
      --  1xx, 204 and 304 never carry a body, so no length either (RFC 9110 8.6).
      if This.Mode = Stream then
         Append (Into, "Transfer-Encoding: chunked" & CRLF);
      elsif This.Status >= 200 and then This.Status not in No_Content | Not_Modified then
         Append (Into, "Content-Length: ");
         Append_Integer (Into, Long_Long_Integer (This.Content.Length));
         Append (Into, CRLF);
      end if;
      if not Keep_Alive then
         Append (Into, "Connection: close" & CRLF);
      end if;
      Append (Into, Content (This.Headers));
      Append (Into, CRLF);
   end Write_Head;

end Sparrow.Http.Responses;
