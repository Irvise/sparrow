with Interfaces; use Interfaces;

package body Sparrow.Http.Http_2 with SPARK_Mode is

   pragma Warnings (GNATprove, Off, "statement has no effect", Reason => "Free releases the storage");
   pragma Warnings (GNATprove, Off, "* is set by ""Free"" but not used after the call",
                    Reason => "Free releases the storage");

   use type Hpack.Outcome;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   --  Frame types (RFC 9113 6).
   Data_Frame          : constant := 0;
   Headers_Frame       : constant := 1;
   Priority_Frame      : constant := 2;
   Reset_Frame         : constant := 3;
   Settings_Frame      : constant := 4;
   Push_Promise_Frame  : constant := 5;
   Ping_Frame          : constant := 6;
   Goaway_Frame        : constant := 7;
   Window_Update_Frame : constant := 8;
   Continuation_Frame  : constant := 9;

   --  Flags.
   End_Stream_Flag  : constant := 16#01#;
   Ack_Flag         : constant := 16#01#;
   End_Headers_Flag : constant := 16#04#;
   Padded_Flag      : constant := 16#08#;
   Priority_Flag    : constant := 16#20#;

   --  Error codes (RFC 9113 7).
   type Error_Code is new Unsigned_32;
   No_Error            : constant Error_Code := 16#0#;
   Protocol_Error      : constant Error_Code := 16#1#;
   Flow_Control_Error  : constant Error_Code := 16#3#;
   Stream_Closed       : constant Error_Code := 16#5#;
   Frame_Size_Error    : constant Error_Code := 16#6#;
   Refused_Stream      : constant Error_Code := 16#7#;
   Compression_Error   : constant Error_Code := 16#9#;
   Enhance_Your_Calm   : constant Error_Code := 16#B#;

   Stream_Window  : constant := 262_144;   --  SETTINGS_INITIAL_WINDOW_SIZE as the server announces it
   Default_Window : constant := 65_535;

   Max_Resets_Per_Second : constant := 200;

   type Byte is mod 256;

   function Byte_At (Text : String; Position : Positive) return Byte is (Character'Pos (Text (Position)))
      with Pre => Position in Text'Range;

   --  The 31-bit number at Text (Position .. Position + 3), the reserved bit dropped.
   function Number_At (Text : String; Position : Positive) return Unsigned_32 is
     (Shift_Left (Unsigned_32 (Byte_At (Text, Position)) and 16#7F#, 24)
      or Shift_Left (Unsigned_32 (Byte_At (Text, Position + 1)), 16)
      or Shift_Left (Unsigned_32 (Byte_At (Text, Position + 2)), 8)
      or Unsigned_32 (Byte_At (Text, Position + 3)))
      with Pre => Position in Text'Range and then Position <= Text'Last - 3;

   ---------------------------------------------------------------------------------------------------------------
   --  writing frames

   procedure Append_Frame_Head
     (Output : in out Buffer; Length : Natural; Kind : Byte; Flags : Byte; Stream : Stream_Id)
      with Pre => Valid (Output) and then Length < 2 ** 24, Post => Valid (Output)
   is
   begin
      Append (Output, Character'Val (Length / 2 ** 16));
      Append (Output, Character'Val (Length / 2 ** 8 mod 256));
      Append (Output, Character'Val (Length mod 256));
      Append (Output, Character'Val (Kind));
      Append (Output, Character'Val (Flags));
      Append_Big_Endian (Output, Unsigned_32 (Stream));
   end Append_Frame_Head;

   procedure Append_Reset (Output : in out Buffer; Stream : Stream_Id; Code : Error_Code)
      with Pre => Valid (Output), Post => Valid (Output)
   is
   begin
      Append_Frame_Head (Output, 4, Reset_Frame, 0, Stream);
      Append_Big_Endian (Output, Unsigned_32 (Code));
   end Append_Reset;

   procedure Append_Window_Update (Output : in out Buffer; Stream : Stream_Id; Increment : Positive)
      with Pre => Valid (Output) and then Increment <= Largest_Window, Post => Valid (Output)
   is
   begin
      Append_Frame_Head (Output, 4, Window_Update_Frame, 0, Stream);
      Append_Big_Endian (Output, Unsigned_32 (Increment));
   end Append_Window_Update;

   procedure Append_Goaway (Output : in out Buffer; Last_Stream : Stream_Id; Code : Error_Code)
      with Pre => Valid (Output), Post => Valid (Output)
   is
   begin
      Append_Frame_Head (Output, 8, Goaway_Frame, 0, 0);
      Append_Big_Endian (Output, Unsigned_32 (Last_Stream));
      Append_Big_Endian (Output, Unsigned_32 (Code));
   end Append_Goaway;

   ---------------------------------------------------------------------------------------------------------------
   --  lanes and events

   procedure Push_Event (This : in out Session; Item : Event; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output);

   --  A connection error (RFC 9113 5.4.1).
   procedure Fail (This : in out Session; Code : Error_Code; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output) and then This.Failed
   is
   begin
      if not This.Failed then
         Append_Goaway (Output, This.Last_Client_Stream, Code);
      end if;
      This.Failed := True;
   end Fail;

   procedure Push_Event (This : in out Session; Item : Event; Output : in out Buffer) is
   begin
      if This.Event_Count = Max_Events then
         Fail (This, Enhance_Your_Calm, Output);   --  only a client churning through streams fills it
         return;
      end if;
      This.Events (This.First_Event + Event_Position'Mod (This.Event_Count)) := Item;
      This.Event_Count := This.Event_Count + 1;
   end Push_Event;

   function Find (This : Session; Stream : Stream_Id) return Natural
      with Post => Find'Result = 0 or else (Find'Result in Lane and then This.Streams (Find'Result).Id = Stream)
   is
   begin
      if Stream = 0 then
         return 0;
      end if;
      for Place in Lane loop
         if This.Streams (Place).Id = Stream then
            return Place;
         end if;
      end loop;
      return 0;
   end Find;

   function Place_Of (This : Session; Stream : Stream_Id) return Natural is (Find (This, Stream));

   function Holds (This : Session; Place : Lane; Stream : Stream_Id) return Boolean is
     (Stream /= 0 and then This.Streams (Place).Id = Stream);

   --  Free the lane; the server hears of it when it knew of the stream and Notify.
   procedure Close_Lane (This : in out Session; Place : Lane; Notify : Boolean; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output)
   is
      Item : Stream_Record renames This.Streams (Place);
   begin
      if Item.Id = 0 then
         return;
      end if;
      if Notify and then Item.Reported then
         Push_Event (This, (Kind => Stream_Reset, Place => Place, Stream => Item.Id, Status => OK), Output);
      end if;
      Free (Item.Head);
      Free (Item.Content);
      Free (Item.Output);
      Item := (others => <>);
      if This.Open_Count > 0 then
         This.Open_Count := This.Open_Count - 1;
      end if;
   end Close_Lane;

   --  A stream error (RFC 9113 5.4.2).
   procedure Reset_Stream (This : in out Session; Stream : Stream_Id; Code : Error_Code; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output)
   is
      Place : constant Natural := Find (This, Stream);
   begin
      Append_Reset (Output, Stream, Code);
      if Place /= 0 then
         Close_Lane (This, Place, Notify => True, Output => Output);
      end if;
   end Reset_Stream;

   --  The response has ended: the stream closes, at once if the request had ended too.
   procedure Response_Done (This : in out Session; Place : Lane; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output)
   is
   begin
      This.Streams (Place).Sending := False;
      if This.Streams (Place).Receiving then
         --  Answered before the whole request came (RFC 9113 8.1): ask the client to stop sending.
         Append_Reset (Output, This.Streams (Place).Id, No_Error);
      end if;
      Close_Lane (This, Place, Notify => False, Output => Output);
   end Response_Done;

   --  Answer the request with Status without a handler; its body, if more comes, is thrown away.
   procedure Refuse (This : in out Session; Place : Lane; Status : Status_Code; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output)
   is
      Item : Stream_Record renames This.Streams (Place);
   begin
      Item.Discarding := True;
      Item.Reported   := True;
      Free (Item.Content);
      Push_Event (This, (Kind => Refused, Place => Place, Stream => Item.Id, Status => Status), Output);
   end Refuse;

   --  Give the client back Count bytes of the stream's window.
   procedure Credit_Stream (This : in out Session; Place : Lane; Count : Natural; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output)
   is
      Item : Stream_Record renames This.Streams (Place);
   begin
      if Count > 0 and then Item.Receiving
        and then Item.Receive_Window <= Largest_Window - Long_Long_Integer (Count)
      then
         Item.Receive_Window := Item.Receive_Window + Long_Long_Integer (Count);
         Append_Window_Update (Output, Item.Id, Count);
      end if;
   end Credit_Stream;

   --  The client has sent the whole request.
   procedure End_Request (This : in out Session; Place : Lane; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output)
   is
      Item : Stream_Record renames This.Streams (Place);
   begin
      Item.Receiving := False;
      if Item.Declared_Length >= 0 and then Item.Declared_Length /= Item.Received_Total then
         Reset_Stream (This, Item.Id, Protocol_Error, Output);   --  content-length disagrees (RFC 9113 8.1.1)
         return;
      end if;
      if Item.Discarding then
         if not Item.Sending then
            Close_Lane (This, Place, Notify => False, Output => Output);
         end if;
         return;
      end if;
      case Item.Handling is
         when Buffered =>
            Push_Event (This, (Kind => Request_Ready, Place => Place, Stream => Item.Id, Status => OK), Output);
         when Streamed =>
            Push_Event (This, (Kind => Body_Ready, Place => Place, Stream => Item.Id, Status => OK), Output);
         when Undecided =>
            null;   --  Buffer_Body or Stream_Body will say
      end case;
   end End_Request;

   ---------------------------------------------------------------------------------------------------------------
   --  request heads

   function Is_Name_Character (Item : Character) return Boolean is
     (Item in 'a' .. 'z' | '0' .. '9' | '!' | '#' | '$' | '%' | '&' | ''' | '*' | '+' | '-' | '.' | '^' | '_'
            | '`' | '|' | '~');

   function Is_Connection_Specific (Name : String) return Boolean is
     (Name = "connection" or else Name = "keep-alive" or else Name = "proxy-connection"
      or else Name = "transfer-encoding" or else Name = "upgrade");

   --  RFC 9113 8.2.1: no line breaks or NUL, and no white space at either end.
   function Is_Clean_Value (Value : String) return Boolean is
     ((for all Item of Value => Item not in ASCII.NUL | ASCII.CR | ASCII.LF)
      and then (Value'Length = 0
                or else (Value (Value'First) not in ' ' | ASCII.HT and then Value (Value'Last) not in ' ' | ASCII.HT)));

   --  Build the stream's request head from its decoded fields: Valid is False for a malformed request
   --  (RFC 9113 8.1.1). Too_Large: it passes the head limit.
   procedure Build_Head
     (This      : in out Session;
      Place     : Lane;
      Text      : String;
      Fields    : Hpack.Field_Array;
      Count     : Natural;
      Valid     : out Boolean;
      Too_Large : out Boolean)
      with Pre => Count <= Fields'Last and then Count <= 4096 and then Fields'First = 1 and then Text'First = 1
                  and then Text'Last in 0 .. 2 ** 26
                  and then (for all Index in 1 .. Count => Hpack.Within (Fields (Index), Text'Last))
   is
      Item          : Stream_Record renames This.Streams (Place);
      Method_First  : Positive := 1;
      Method_Last   : Natural := 0;
      Path_First    : Positive := 1;
      Path_Last     : Natural := 0;
      Host_First    : Positive := 1;
      Host_Last     : Natural := 0;
      Has_Method    : Boolean := False;
      Has_Scheme    : Boolean := False;
      Has_Path      : Boolean := False;
      Has_Authority : Boolean := False;
      Has_Host      : Boolean := False;
      Regular_Seen  : Boolean := False;
      Lines         : Held_Buffer;   --  the regular header lines
      Cookies       : Held_Buffer;   --  cookie fields, joined (RFC 9113 8.2.3)
      Line_Count    : Natural := 0;
   begin
      Valid     := False;
      Too_Large := False;
      for Index in 1 .. Count loop
         pragma Loop_Invariant (Method_Last <= Text'Last and then Path_Last <= Text'Last
                                and then Host_Last <= Text'Last and then Line_Count < Index);
         declare
            Name  : constant String := Text (Fields (Index).Name_First .. Fields (Index).Name_Last);
            Value : constant String := Text (Fields (Index).Value_First .. Fields (Index).Value_Last);
         begin
            if Name'Length = 0 or else not Is_Clean_Value (Value) then
               Free (Lines);
               Free (Cookies);
               return;
            end if;
            if Name (Name'First) = ':' then
               --  Pseudo-header fields: before every other field, each once, only the request's.
               if Regular_Seen then
                  Free (Lines);
                  Free (Cookies);
                  return;
               end if;
               if Name = ":method" and then not Has_Method and then Value'Length > 0 then
                  Has_Method   := True;
                  Method_First := Fields (Index).Value_First;
                  Method_Last  := Fields (Index).Value_Last;
               elsif Name = ":scheme" and then not Has_Scheme then
                  Has_Scheme := True;
               elsif Name = ":path" and then not Has_Path and then Value'Length > 0 then
                  Has_Path   := True;
                  Path_First := Fields (Index).Value_First;
                  Path_Last  := Fields (Index).Value_Last;
               elsif Name = ":authority" and then not Has_Authority then
                  Has_Authority := True;
                  Host_First    := Fields (Index).Value_First;
                  Host_Last     := Fields (Index).Value_Last;
               else
                  Free (Lines);
                  Free (Cookies);
                  return;
               end if;
            else
               Regular_Seen := True;
               if not (for all Symbol of Name => Is_Name_Character (Symbol))
                 or else Is_Connection_Specific (Name)
                 or else (Name = "te" and then Value /= "trailers")
               then
                  Free (Lines);
                  Free (Cookies);
                  return;
               end if;
               if Name = "host" then
                  if Has_Host or else (Has_Authority and then Value /= Text (Host_First .. Host_Last)) then
                     Free (Lines);
                     Free (Cookies);
                     return;
                  end if;
                  Has_Host := True;
                  if not Has_Authority then
                     Host_First := Fields (Index).Value_First;
                     Host_Last  := Fields (Index).Value_Last;
                  end if;
               elsif Name = "cookie" then
                  if Cookies.Length > 0 then
                     Append (Cookies, "; ");
                  end if;
                  Append (Cookies, Value);
               elsif Name = "content-length" then
                  declare
                     Length : Long_Long_Integer := 0;
                  begin
                     if Value'Length = 0 or else Value'Length > 18
                       or else not (for all Symbol of Value => Symbol in '0' .. '9')
                       or else Item.Declared_Length >= 0
                     then
                        Free (Lines);
                        Free (Cookies);
                        return;
                     end if;
                     for Symbol of Value loop
                        pragma Loop_Invariant (Length in 0 .. 10 ** 17 - 1);
                        Length := Length * 10 + Long_Long_Integer (Character'Pos (Symbol) - Character'Pos ('0'));
                        exit when Length >= 10 ** 17;
                     end loop;
                     Item.Declared_Length := Length;
                  end;
                  Line_Count := Line_Count + 1;
                  Append (Lines, Name & ": " & Value & CRLF);
               else
                  Line_Count := Line_Count + 1;
                  Append (Lines, Name & ": " & Value & CRLF);
               end if;
            end if;
         end;
      end loop;

      if not (Has_Method and then Has_Scheme and then Has_Path) then
         Free (Lines);
         Free (Cookies);
         return;
      end if;
      Valid := True;

      Clear (Item.Head);
      Append (Item.Head, Text (Method_First .. Method_Last));
      Append (Item.Head, ' ');
      Append (Item.Head, Text (Path_First .. Path_Last));
      Append (Item.Head, " HTTP/1.1" & CRLF);
      if Host_Last >= Host_First then
         Append (Item.Head, "Host: ");
         Append (Item.Head, Text (Host_First .. Host_Last));
         Append (Item.Head, CRLF);
      end if;
      Append (Item.Head, Content (Lines));
      if Cookies.Length > 0 then
         Line_Count := Line_Count + 1;
         Append (Item.Head, "Cookie: ");
         Append (Item.Head, Content (Cookies));
         Append (Item.Head, CRLF);
      end if;
      Free (Lines);
      Free (Cookies);
      Too_Large := Item.Head.Overflowed or else Item.Head.Length > This.Limits.Max_Head_Length
                   or else Line_Count >= Parser.Max_Headers;
   end Build_Head;

   --  A whole header block has arrived for Block_Stream: decode it, then act on it.
   procedure Finish_Block (This : in out Session; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output)
   is
      Stream  : constant Stream_Id := This.Block_Stream;
      Place   : constant Natural := Find (This, Stream);
      Room    : constant Positive := 2 * Positive'Min (This.Limits.Max_Head_Length, 2 ** 24);
      Text    : String (1 .. Room);
      Fields  : Hpack.Field_Array (1 .. 256);
      Count   : Natural;
      Last    : Natural;
      Result  : Hpack.Outcome;
      Ignored : Boolean := False;
   begin
      This.Block_Stream := 0;
      if This.Block_Ignored then
         Ignored := True;
         This.Block_Ignored := False;
      end if;
      declare
         Length : constant Natural := This.Block.Length;
         Block  : constant String (1 .. Length) := Content (This.Block);
      begin
         Hpack.Decode (This.Decoder, Block, Text, Last, Fields, Count, Result);
      end;
      if Capacity (This.Block) > 65_536 then
         Free (This.Block);
      else
         Clear (This.Block);
      end if;
      if Result /= Hpack.Decoded then
         --  The compression state is lost (Too_Large: a block past the limit we announced).
         Fail (This, (if Result = Hpack.Malformed then Compression_Error else Enhance_Your_Calm), Output);
         return;
      end if;

      if Place = 0 or else Ignored then
         --  A block decoded only to keep the table in step: its stream was refused or reset.
         return;
      end if;

      if This.Block_Is_Trailer then
         --  Trailers carry no pseudo-header fields (RFC 9113 8.1); they are not passed on.
         for Index in 1 .. Count loop
            if Fields (Index).Name_Last >= Fields (Index).Name_First
              and then Text (Fields (Index).Name_First) = ':'
            then
               Reset_Stream (This, Stream, Protocol_Error, Output);
               return;
            end if;
         end loop;
         End_Request (This, Place, Output);
         return;
      end if;

      declare
         Valid, Too_Large : Boolean;
      begin
         Build_Head (This, Place, Text (1 .. Last), Fields, Count, Valid, Too_Large);
         if not Valid then
            Reset_Stream (This, Stream, Protocol_Error, Output);
            return;
         end if;
         if This.Block_Ends_Stream then
            This.Streams (Place).Handling := Buffered;
         end if;
         if Too_Large then
            Refuse (This, Place, Header_Fields_Too_Large, Output);
            if This.Block_Ends_Stream then
               This.Streams (Place).Receiving := False;
            end if;
            return;
         end if;
         This.Streams (Place).Reported := True;
         if This.Block_Ends_Stream then
            End_Request (This, Place, Output);
         else
            Push_Event (This, (Kind => Head_Ready, Place => Place, Stream => Stream, Status => OK), Output);
         end if;
      end;
   end Finish_Block;

   ---------------------------------------------------------------------------------------------------------------
   --  frames

   procedure Add_To_Block (This : in out Session; Fragment : String; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output)
   is
   begin
      if Long_Long_Integer (Fragment'Length)
        > 2 * Long_Long_Integer (This.Limits.Max_Head_Length) - Long_Long_Integer (This.Block.Length)
      then
         Fail (This, Enhance_Your_Calm, Output);   --  a header block past every limit (CVE-2024-27316)
         return;
      end if;
      Append (This.Block, Fragment);
   end Add_To_Block;

   procedure On_Headers
     (This : in out Session; Stream : Stream_Id; Flags : Byte; Payload : String; Output : in out Buffer)
      with Pre  => Valid (Output) and then Payload'First >= 1
                   and then Payload'Last in Payload'First - 1 .. Positive'Last - 1
                   and then Payload'Length <= Frame_Size,
           Post => Valid (Output)
   is
      First   : Natural := Payload'First;
      Last    : Natural := Payload'Last;
      Place   : Natural;
      Refusal : Error_Code := No_Error;   --  decode the block, then reset the stream with this
   begin
      if Stream = 0 then
         Fail (This, Protocol_Error, Output);
         return;
      end if;
      if (Flags and Padded_Flag) /= 0 then
         if Payload'Length = 0 or else Natural (Byte_At (Payload, First)) >= Payload'Length then
            Fail (This, Protocol_Error, Output);
            return;
         end if;
         Last  := Last - Natural (Byte_At (Payload, First));
         First := First + 1;
      end if;
      if (Flags and Priority_Flag) /= 0 then
         if Last - First + 1 < 5 then
            Fail (This, Protocol_Error, Output);
            return;
         end if;
         if Stream_Id (Number_At (Payload, First)) = Stream then
            Refusal := Protocol_Error;   --  a stream that depends on itself (RFC 9113 5.3.1)
         end if;
         First := First + 5;
      end if;

      Place := Find (This, Stream);
      This.Block_Is_Trailer := False;
      if Place /= 0 then
         if not This.Streams (Place).Receiving then
            Refusal := Stream_Closed;   --  the client already ended its side
         elsif (Flags and End_Stream_Flag) = 0 then
            Refusal := Protocol_Error;   --  trailers must end the stream
         else
            This.Block_Is_Trailer := True;
         end if;
      elsif Stream mod 2 = 0 then
         Fail (This, Protocol_Error, Output);   --  clients open odd streams
         return;
      elsif Stream <= This.Last_Client_Stream then
         Fail (This, Stream_Closed, Output);
         return;
      else
         This.Last_Client_Stream := Stream;
         if This.Going_Away or else This.Open_Count = Max_Streams then
            Refusal := Refused_Stream;
         elsif Refusal = No_Error then
            for Free_Place in Lane loop
               if This.Streams (Free_Place).Id = 0 then
                  --  A free lane holds a stream record's defaults (Close_Lane leaves it so).
                  This.Streams (Free_Place).Id             := Stream;
                  This.Streams (Free_Place).Receiving      := (Flags and End_Stream_Flag) = 0;
                  This.Streams (Free_Place).Sending        := True;
                  This.Streams (Free_Place).Receive_Window := Stream_Window;
                  This.Streams (Free_Place).Send_Window    := This.Peer_Initial;
                  This.Open_Count := This.Open_Count + 1;
                  exit;
               end if;
            end loop;
         end if;
      end if;

      This.Block_Stream      := Stream;
      This.Block_Ends_Stream := (Flags and End_Stream_Flag) /= 0;
      This.Block_Ignored     := Refusal /= No_Error;
      if First <= Last then
         Add_To_Block (This, Payload (First .. Last), Output);
      end if;
      if This.Failed then
         return;
      end if;
      if Refusal /= No_Error then
         --  The block is still decoded, to keep the table in step, but for no stream.
         Reset_Stream (This, Stream, Refusal, Output);
      end if;
      if (Flags and End_Headers_Flag) /= 0 then
         Finish_Block (This, Output);
      end if;
   end On_Headers;

   procedure On_Data
     (This : in out Session; Stream : Stream_Id; Flags : Byte; Payload : String; Output : in out Buffer)
      with Pre  => Valid (Output) and then Payload'First >= 1
                   and then Payload'Last in Payload'First - 1 .. Positive'Last - 1
                   and then Payload'Length <= Frame_Size,
           Post => Valid (Output)
   is
      First : Natural := Payload'First;
      Last  : Natural := Payload'Last;
      Place : Natural;
   begin
      if Stream = 0 then
         Fail (This, Protocol_Error, Output);
         return;
      end if;

      --  The whole payload counts against the connection's window, whatever becomes of the stream.
      if Payload'Length > This.Receive_Window then
         Fail (This, Flow_Control_Error, Output);
         return;
      end if;
      This.Receive_Window := This.Receive_Window - Payload'Length;
      declare
         Credit : constant Long_Long_Integer := This.Receive_Credit + Payload'Length;
      begin
         if Credit >= Connection_Window / 2 then
            Append_Window_Update (Output, 0, Positive (Credit));
            This.Receive_Window := Long_Long_Integer'Min (Largest_Window, This.Receive_Window + Credit);
            This.Receive_Credit := 0;
         else
            This.Receive_Credit := Credit;
         end if;
      end;

      if (Flags and Padded_Flag) /= 0 then
         if Payload'Length = 0 or else Natural (Byte_At (Payload, First)) >= Payload'Length then
            Fail (This, Protocol_Error, Output);
            return;
         end if;
         Last  := Last - Natural (Byte_At (Payload, First));
         First := First + 1;
      end if;

      Place := Find (This, Stream);
      if Place = 0 then
         if Stream > This.Last_Client_Stream then
            Fail (This, Protocol_Error, Output);   --  an idle stream
         else
            Append_Reset (Output, Stream, Stream_Closed);
         end if;
         return;
      end if;

      declare
         Found : constant Lane := Place;
         Item  : Stream_Record renames This.Streams (Found);
      begin
         if not Item.Receiving then
            Reset_Stream (This, Stream, Stream_Closed, Output);
            return;
         end if;
         if Payload'Length > Item.Receive_Window then
            Reset_Stream (This, Stream, Flow_Control_Error, Output);
            return;
         end if;
         Item.Receive_Window := Item.Receive_Window - Payload'Length;
         if Item.Received_Total > Body_Total'Last - Frame_Size then
            Reset_Stream (This, Stream, Protocol_Error, Output);   --  2 ** 62 bytes: never, but bounded
            return;
         end if;
         Item.Received_Total := Item.Received_Total + Long_Long_Integer (Last - First + 1);
         if Item.Declared_Length >= 0 and then Item.Received_Total > Item.Declared_Length then
            Reset_Stream (This, Stream, Protocol_Error, Output);
            return;
         end if;

         if not Item.Discarding then
            case Item.Handling is
               when Buffered =>
                  if Item.Received_Total > Long_Long_Integer (This.Limits.Max_Body_Length) then
                     Refuse (This, Place, Payload_Too_Large, Output);
                  else
                     Append (Item.Content, Payload (First .. Last));
                     if (Flags and End_Stream_Flag) = 0 then
                        Credit_Stream (This, Place, Payload'Length, Output);
                     end if;
                  end if;
               when Undecided =>
                  Append (Item.Content, Payload (First .. Last));
               when Streamed =>
                  if Item.Received_Total <= This.Limits.Max_Streamed_Length then
                     Append (Item.Content, Payload (First .. Last));
                  end if;
                  Push_Event (This, (Kind => Body_Ready, Place => Place, Stream => Stream, Status => OK), Output);
            end case;
         end if;
      end;
      if (Flags and End_Stream_Flag) /= 0 and then Find (This, Stream) = Place then
         End_Request (This, Place, Output);
      end if;
   end On_Data;

   procedure On_Settings (This : in out Session; Flags : Byte; Payload : String; Output : in out Buffer)
      with Pre  => Valid (Output) and then Payload'First >= 1
                   and then Payload'Last in Payload'First - 1 .. Positive'Last - 1
                   and then Payload'Length <= Frame_Size,
           Post => Valid (Output)
   is
   begin
      if (Flags and Ack_Flag) /= 0 then
         if Payload'Length /= 0 then
            Fail (This, Frame_Size_Error, Output);
         end if;
         return;
      end if;
      if Payload'Length mod 6 /= 0 then
         Fail (This, Frame_Size_Error, Output);
         return;
      end if;
      for Entry_Index in 0 .. Payload'Length / 6 - 1 loop
         pragma Loop_Invariant (Valid (Output));
         declare
            Position   : constant Positive := Payload'First + 6 * Entry_Index;
            Identifier : constant Natural :=
              Natural (Byte_At (Payload, Position)) * 256 + Natural (Byte_At (Payload, Position + 1));
            Value      : constant Unsigned_32 :=
              Shift_Left (Unsigned_32 (Byte_At (Payload, Position + 2)), 24)
              or Shift_Left (Unsigned_32 (Byte_At (Payload, Position + 3)), 16)
              or Shift_Left (Unsigned_32 (Byte_At (Payload, Position + 4)), 8)
              or Unsigned_32 (Byte_At (Payload, Position + 5));
         begin
            case Identifier is
               when 2 =>   --  SETTINGS_ENABLE_PUSH
                  if Value > 1 then
                     Fail (This, Protocol_Error, Output);
                     return;
                  end if;
               when 4 =>   --  SETTINGS_INITIAL_WINDOW_SIZE: every stream's window moves by the difference
                  if Value > Largest_Window then
                     Fail (This, Flow_Control_Error, Output);
                     return;
                  end if;
                  declare
                     Difference : constant Long_Long_Integer := Long_Long_Integer (Value) - This.Peer_Initial;
                  begin
                     for Place in Lane loop
                        pragma Loop_Invariant (Valid (Output));
                        if This.Streams (Place).Id /= 0 then
                           if This.Streams (Place).Send_Window + Difference not in Window_Size then
                              Fail (This, Flow_Control_Error, Output);
                              return;
                           end if;
                           This.Streams (Place).Send_Window := This.Streams (Place).Send_Window + Difference;
                        end if;
                     end loop;
                     This.Peer_Initial := Long_Long_Integer (Value);
                  end;
               when 5 =>   --  SETTINGS_MAX_FRAME_SIZE: the server keeps to the smallest anyway
                  if Value < 2 ** 14 or else Value > 2 ** 24 - 1 then
                     Fail (This, Protocol_Error, Output);
                     return;
                  end if;
               when others =>   --  header table size (the encoder uses no table), the rest, and unknown ones
                  null;
            end case;
         end;
      end loop;
      This.Settings_Seen := True;
      Append_Frame_Head (Output, 0, Settings_Frame, Ack_Flag, 0);
   end On_Settings;

   procedure On_Window_Update (This : in out Session; Stream : Stream_Id; Payload : String; Output : in out Buffer)
      with Pre  => Valid (Output) and then Payload'First >= 1 and then Payload'Last < Positive'Last
                   and then Payload'Length = 4,
           Post => Valid (Output)
   is
      Increment : constant Long_Long_Integer := Long_Long_Integer (Number_At (Payload, Payload'First));
      Place     : Natural;
   begin
      if Stream = 0 then
         if Increment = 0 then
            Fail (This, Protocol_Error, Output);
         elsif This.Send_Window + Increment > Largest_Window then
            Fail (This, Flow_Control_Error, Output);
         else
            This.Send_Window := This.Send_Window + Increment;
         end if;
         return;
      end if;
      Place := Find (This, Stream);
      if Place = 0 then
         if Stream > This.Last_Client_Stream then
            Fail (This, Protocol_Error, Output);   --  an idle stream
         end if;
         return;   --  a closed one: frames in flight are expected
      end if;
      if Increment = 0 then
         Reset_Stream (This, Stream, Protocol_Error, Output);
      elsif This.Streams (Place).Send_Window + Increment > Largest_Window then
         Reset_Stream (This, Stream, Flow_Control_Error, Output);
      else
         This.Streams (Place).Send_Window := This.Streams (Place).Send_Window + Increment;
      end if;
   end On_Window_Update;

   procedure On_Reset
     (This : in out Session; Stream : Stream_Id; Now : Times.Milliseconds; Output : in out Buffer)
      with Pre => Valid (Output), Post => Valid (Output)
   is
      use type Times.Milliseconds;
      Place : constant Natural := Find (This, Stream);
   begin
      if Stream = 0 or else (Place = 0 and then Stream > This.Last_Client_Stream) then
         Fail (This, Protocol_Error, Output);   --  stream 0, or an idle stream
         return;
      end if;
      if Place = 0 then
         return;
      end if;
      --  Opening streams and resetting them at once makes the server start work it then throws away: past a
      --  rate, end the connection.
      if Now < This.Reset_Window_Start or else Now / 2 - This.Reset_Window_Start / 2 >= 500 then
         This.Reset_Window_Start := Now;
         This.Resets_In_Window   := 0;
      end if;
      This.Resets_In_Window := Natural'Min (This.Resets_In_Window + 1, Max_Resets_Per_Second + 1);
      Close_Lane (This, Place, Notify => True, Output => Output);
      if This.Resets_In_Window > Max_Resets_Per_Second then
         Fail (This, Enhance_Your_Calm, Output);
      end if;
   end On_Reset;

   ---------------------------------------------------------------------------------------------------------------

   procedure Start (This : in out Session; Limits : Parser.Limits; Output : in out Buffer) is
   begin
      Free (This);
      This.Limits := Limits;
      This.Decoder := Hpack.New_Decoder;
      --  SETTINGS: no push, at most Max_Streams streams, the stream window, the header list limit.
      Append_Frame_Head (Output, 24, Settings_Frame, 0, 0);
      Append (Output, Character'Val (0));
      Append (Output, Character'Val (2));
      Append_Big_Endian (Output, Unsigned_32'(0));
      Append (Output, Character'Val (0));
      Append (Output, Character'Val (3));
      Append_Big_Endian (Output, Unsigned_32'(Max_Streams));
      Append (Output, Character'Val (0));
      Append (Output, Character'Val (4));
      Append_Big_Endian (Output, Unsigned_32'(Stream_Window));
      Append (Output, Character'Val (0));
      Append (Output, Character'Val (6));
      Append_Big_Endian (Output, Unsigned_32 (Limits.Max_Head_Length));
      Append_Window_Update (Output, 0, Connection_Window - Default_Window);
      This.Receive_Window := Connection_Window;
   end Start;

   procedure Receive
     (This   : in out Session;
      Input  : String;
      Now    : Times.Milliseconds;
      Used   : out Natural;
      Output : in out Buffer)
   is
      Position : Natural := Input'First;
   begin
      Used := 0;
      if This.Failed then
         return;
      end if;
      if not This.Preface_Seen then
         if Input'Length < Preface'Length then
            if Input /= Preface (Preface'First .. Preface'First + Input'Length - 1) then
               Fail (This, Protocol_Error, Output);
            end if;
            return;
         elsif Input (Input'First .. Input'First + Preface'Length - 1) /= Preface then
            Fail (This, Protocol_Error, Output);
            return;
         end if;
         This.Preface_Seen := True;
         Position := Position + Preface'Length;
      end if;

      while not This.Failed and then Input'Last - Position + 1 >= 9 loop
         pragma Loop_Invariant (Valid (Output) and then Position >= Input'First and then Position - 1 <= Input'Last);
         declare
            Length : constant Natural :=
              Natural (Byte_At (Input, Position)) * 2 ** 16 + Natural (Byte_At (Input, Position + 1)) * 2 ** 8
              + Natural (Byte_At (Input, Position + 2));
            Kind   : constant Byte := Byte_At (Input, Position + 3);
            Flags  : constant Byte := Byte_At (Input, Position + 4);
            Stream : constant Stream_Id := Stream_Id (Number_At (Input, Position + 5));
         begin
            if Length > Frame_Size then
               Fail (This, Frame_Size_Error, Output);
               exit;
            end if;
            exit when Input'Last - Position + 1 - 9 < Length;
            declare
               First   : constant Positive := Position + 9;
               Last    : constant Natural := Position + 8 + Length;
               Payload : String renames Input (First .. Last);
            begin
               if This.Block_Stream /= 0 and then (Kind /= Continuation_Frame or else Stream /= This.Block_Stream) then
                  Fail (This, Protocol_Error, Output);   --  a header block must not be interrupted
               elsif not This.Settings_Seen and then Kind /= Settings_Frame then
                  Fail (This, Protocol_Error, Output);   --  the client's preface ends with SETTINGS
               else
                  case Kind is
                     when Data_Frame =>
                        On_Data (This, Stream, Flags, Payload, Output);
                     when Headers_Frame =>
                        On_Headers (This, Stream, Flags, Payload, Output);
                     when Priority_Frame =>
                        if Stream = 0 then
                           Fail (This, Protocol_Error, Output);
                        elsif Length /= 5 then
                           Reset_Stream (This, Stream, Frame_Size_Error, Output);
                        elsif Stream_Id (Number_At (Payload, Payload'First)) = Stream then
                           Reset_Stream (This, Stream, Protocol_Error, Output);
                        end if;   --  otherwise advice the server does not take
                     when Reset_Frame =>
                        if Length /= 4 then
                           Fail (This, Frame_Size_Error, Output);
                        else
                           On_Reset (This, Stream, Now, Output);
                        end if;
                     when Settings_Frame =>
                        if Stream /= 0 then
                           Fail (This, Protocol_Error, Output);
                        else
                           On_Settings (This, Flags, Payload, Output);
                        end if;
                     when Push_Promise_Frame =>
                        Fail (This, Protocol_Error, Output);   --  clients do not push
                     when Ping_Frame =>
                        if Length /= 8 then
                           Fail (This, Frame_Size_Error, Output);
                        elsif Stream /= 0 then
                           Fail (This, Protocol_Error, Output);
                        elsif (Flags and Ack_Flag) = 0 then
                           Append_Frame_Head (Output, 8, Ping_Frame, Ack_Flag, 0);
                           Append (Output, Payload);
                        end if;
                     when Goaway_Frame =>
                        if Stream /= 0 then
                           Fail (This, Protocol_Error, Output);
                        elsif Length < 8 then
                           Fail (This, Frame_Size_Error, Output);
                        else
                           This.Going_Away := True;
                        end if;
                     when Window_Update_Frame =>
                        if Length /= 4 then
                           Fail (This, Frame_Size_Error, Output);
                        else
                           On_Window_Update (This, Stream, Payload, Output);
                        end if;
                     when Continuation_Frame =>
                        if This.Block_Stream = 0 then
                           Fail (This, Protocol_Error, Output);
                        else
                           Add_To_Block (This, Payload, Output);
                           if not This.Failed and then (Flags and End_Headers_Flag) /= 0 then
                              Finish_Block (This, Output);
                           end if;
                        end if;
                     when others =>
                        null;   --  unknown frame types are ignored (RFC 9113 4.1)
                  end case;
               end if;
            end;
            Position := Position + 9 + Length;
         end;
      end loop;
      Used := Position - Input'First;
   end Receive;

   function Failed (This : Session) return Boolean is (This.Failed);
   function Going_Away (This : Session) return Boolean is (This.Going_Away);
   function Open_Streams (This : Session) return Natural is (This.Open_Count);

   procedure Next_Event (This : in out Session; Item : out Event) is
   begin
      if This.Event_Count = 0 then
         Item := (others => <>);
         return;
      end if;
      Item := This.Events (This.First_Event);
      This.First_Event := This.First_Event + 1;
      This.Event_Count := This.Event_Count - 1;
   end Next_Event;

   function Head (This : Session; Place : Lane) return String is (Content (This.Streams (Place).Head));

   procedure Buffer_Body (This : in out Session; Place : Lane; Output : in out Buffer) is
      Item : Stream_Record renames This.Streams (Place);
   begin
      Item.Handling := Buffered;
      if Item.Declared_Length > Long_Long_Integer (This.Limits.Max_Body_Length)
        or else Item.Received_Total > Long_Long_Integer (This.Limits.Max_Body_Length)
      then
         Refuse (This, Place, Payload_Too_Large, Output);
         if not Item.Receiving and then not Item.Sending then
            Close_Lane (This, Place, Notify => False, Output => Output);
         end if;
         return;
      end if;
      if Item.Receiving then
         Credit_Stream (This, Place, Item.Content.Length, Output);
      else
         Push_Event (This, (Kind => Request_Ready, Place => Place, Stream => Item.Id, Status => OK), Output);
      end if;
   end Buffer_Body;

   procedure Stream_Body (This : in out Session; Place : Lane) is
   begin
      This.Streams (Place).Handling := Streamed;
   end Stream_Body;

   procedure Take_Request (This : in out Session; Place : Lane; Into : in out Buffer) is
      Item : Stream_Record renames This.Streams (Place);
   begin
      Clear (Into);
      Reserve (Into, Natural (Long_Long_Integer'Min (Max_Capacity, Long_Long_Integer (Item.Head.Length) + 40
                                                                 + Long_Long_Integer (Item.Content.Length))));
      Append (Into, Content (Item.Head));
      if Item.Content.Length > 0 or else Item.Declared_Length >= 0 then
         Append (Into, "Content-Length: ");
         Append_Integer (Into, Long_Long_Integer (Item.Content.Length));
         Append (Into, CRLF);
      end if;
      Append (Into, CRLF);
      Append (Into, Content (Item.Content));
      Free (Item.Content);
      Free (Item.Head);
   end Take_Request;

   function Received (This : Session; Place : Lane) return String is (Content (This.Streams (Place).Content));

   procedure Take_Body (This : in out Session; Place : Lane; Count : Natural; Output : in out Buffer) is
   begin
      Consume (This.Streams (Place).Content, Count);
      Credit_Stream (This, Place, Count, Output);
   end Take_Body;

   function Body_Ended (This : Session; Place : Lane) return Boolean is
     (not This.Streams (Place).Receiving and then This.Streams (Place).Content.Length = 0);

   function Body_Too_Long (This : Session; Place : Lane) return Boolean is
     (This.Streams (Place).Received_Total > This.Limits.Max_Streamed_Length);

   ---------------------------------------------------------------------------------------------------------------
   --  answers

   --  Header_Lines as HPACK fields into Into: lower-case names, connection-specific ones left out.
   procedure Encode_Lines (Into : in out Buffer; Header_Lines : String)
      with Pre  => Valid (Into) and then Header_Lines'First >= 1 and then Header_Lines'Last < Positive'Last - 2,
           Post => Valid (Into)
   is
      Line_First : Positive := Header_Lines'First;
   begin
      while Line_First <= Header_Lines'Last loop
         pragma Loop_Invariant (Valid (Into) and then Line_First >= Header_Lines'First);
         declare
            Line_Last : Natural := Line_First;
            Colon     : Natural := 0;
         begin
            while Line_Last <= Header_Lines'Last and then Header_Lines (Line_Last) /= ASCII.CR loop
               pragma Loop_Invariant (Line_Last in Line_First .. Header_Lines'Last
                                      and then (Colon = 0 or else Colon in Line_First .. Line_Last - 1));
               if Colon = 0 and then Header_Lines (Line_Last) = ':' then
                  Colon := Line_Last;
               end if;
               Line_Last := Line_Last + 1;
            end loop;
            pragma Assert (Line_Last <= Header_Lines'Last + 1);
            --  Header_Lines (Line_First .. Line_Last - 1) is one line.
            if Colon > Line_First then
               declare
                  Name_First  : constant Positive := Line_First;
                  Name_Last   : constant Natural := Colon - 1;
                  Name        : String (1 .. Name_Last - Name_First + 1) := Header_Lines (Name_First .. Name_Last);
                  Value_First : Natural := Colon + 1;
               begin
                  for Symbol of Name loop
                     if Symbol in 'A' .. 'Z' then
                        Symbol := Character'Val (Character'Pos (Symbol) + 32);
                     end if;
                  end loop;
                  while Value_First < Line_Last and then Header_Lines (Value_First) = ' ' loop
                     pragma Loop_Invariant (Value_First in Colon + 1 .. Line_Last - 1);
                     Value_First := Value_First + 1;
                  end loop;
                  if not Is_Connection_Specific (Name) and then Name'Length <= 2 ** 20
                    and then Line_Last - Value_First <= 2 ** 20
                  then
                     Hpack.Encode_Field (Into, Name, Header_Lines (Value_First .. Line_Last - 1));
                  end if;
               end;
            end if;
            Line_First := Line_Last + 2;   --  past CR LF
         end;
      end loop;
   end Encode_Lines;

   procedure Respond
     (This           : in out Session;
      Place          : Lane;
      Status         : Status_Code;
      Header_Lines   : String;
      Content        : in out Buffer;
      Content_Length : Long_Long_Integer;
      Finished       : Boolean;
      Output         : in out Buffer)
   is
      Item  : Stream_Record renames This.Streams (Place);
      Block : Held_Buffer;
      Ends  : constant Boolean := Finished and then Content.Length = 0;
   begin
      if Item.Id = 0 or else Item.Responded then
         Free (Content);
         return;
      end if;
      Item.Responded := True;
      Hpack.Encode_Status (Block, Status);
      Encode_Lines (Block, Header_Lines);
      if Content_Length >= 0 then
         declare
            Digits_Of : Held_Buffer;
         begin
            Append_Integer (Digits_Of, Content_Length);
            if Digits_Of.Length <= 20 then
               Hpack.Encode_Field (Block, "content-length", Sparrow.Buffers.Content (Digits_Of));
            end if;
            Free (Digits_Of);
         end;
      end if;

      --  HEADERS, then CONTINUATION frames for whatever does not fit in one.
      declare
         Sent : Natural := 0;
         Size : Natural;
      begin
         loop
            pragma Loop_Invariant (Valid (Output) and then Sent <= Block.Length);
            Size := Natural'Min (Frame_Size, Block.Length - Sent);
            Append_Frame_Head
              (Output, Size, (if Sent = 0 then Headers_Frame else Continuation_Frame),
               (if Sent + Size = Block.Length then End_Headers_Flag else 0)
               or (if Sent = 0 and then Ends then End_Stream_Flag else 0),
               Item.Id);
            if Size > 0 then
               Append (Output, Block.Data (Sent + 1 .. Sent + Size));
            end if;
            Sent := Sent + Size;
            exit when Sent >= Block.Length;
         end loop;
      end;
      Free (Block);

      if Ends then
         Free (Content);
         Response_Done (This, Place, Output);
      else
         Free (Item.Output);
         Item.Output      := Content;
         Content          := (others => <>);
         Item.Output_Sent := 0;
         Item.End_After   := Finished;
      end if;
   end Respond;

   procedure Push (This : in out Session; Place : Lane; Data : String) is
      Item : Stream_Record renames This.Streams (Place);
   begin
      if Item.Id /= 0 and then Item.Responded and then not Item.End_After then
         if Item.Output_Sent = Item.Output.Length then
            Clear (Item.Output);
            Item.Output_Sent := 0;
         end if;
         Append (Item.Output, Data);
      end if;
   end Push;

   procedure Finish (This : in out Session; Place : Lane) is
   begin
      if This.Streams (Place).Id /= 0 and then This.Streams (Place).Responded then
         This.Streams (Place).End_After := True;
      end if;
   end Finish;

   function Pending_Data (This : Session) return Natural is
      Total : Natural := 0;
   begin
      for Item of This.Streams loop
         if Item.Id /= 0 and then Item.Output.Length > Item.Output_Sent then
            Total := Natural (Long_Long_Integer'Min (Long_Long_Integer (Total)
                                                     + Long_Long_Integer (Item.Output.Length - Item.Output_Sent),
                                                     Long_Long_Integer (Natural'Last / 2)));
         end if;
      end loop;
      return Total;
   end Pending_Data;

   procedure Fill (This : in out Session; Output : in out Buffer; Limit : Natural) is
      Progress : Boolean := True;
   begin
      while Progress and then Output.Length < Limit loop
         pragma Loop_Invariant (Valid (Output));
         Progress := False;
         for Turn in 0 .. Max_Streams - 1 loop
            pragma Loop_Invariant (Valid (Output));
            exit when Output.Length >= Limit;
            declare
               Place : constant Lane := (This.Next_Lane - 1 + Turn) mod Max_Streams + 1;
               Item  : Stream_Record renames This.Streams (Place);
            begin
               if Item.Id /= 0 and then Item.Responded and then Item.Sending
                 and then Item.Output_Sent <= Item.Output.Length
               then
                  declare
                     Waiting : constant Natural := Item.Output.Length - Item.Output_Sent;
                     Size    : constant Natural :=
                       Natural (Long_Long_Integer'Min
                                  (Long_Long_Integer (Natural'Min (Frame_Size, Waiting)),
                                   Long_Long_Integer'Max
                                     (0, Long_Long_Integer'Min (Item.Send_Window, This.Send_Window))));
                     Last    : constant Boolean := Item.End_After and then Size = Waiting;
                  begin
                     if Size > 0 or else Last then
                        Append_Frame_Head (Output, Size, Data_Frame, (if Last then End_Stream_Flag else 0), Item.Id);
                        if Size > 0 then
                           Append (Output, Item.Output.Data (Item.Output_Sent + 1 .. Item.Output_Sent + Size));
                        end if;
                        Item.Output_Sent := Item.Output_Sent + Size;
                        Item.Send_Window := Item.Send_Window - Long_Long_Integer (Size);
                        This.Send_Window := This.Send_Window - Long_Long_Integer (Size);
                        Progress := True;
                        if Last then
                           Response_Done (This, Place, Output);
                        elsif Item.Output_Sent = Item.Output.Length then
                           Clear (Item.Output);
                           Item.Output_Sent := 0;
                        end if;
                        This.Next_Lane := Place mod Max_Streams + 1;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end loop;
   end Fill;

   procedure Go_Away (This : in out Session; Output : in out Buffer) is
   begin
      if not This.Going_Away and then not This.Failed then
         Append_Goaway (Output, This.Last_Client_Stream, No_Error);
      end if;
      This.Going_Away := True;
   end Go_Away;

   procedure Free (This : in out Session) is
   begin
      for Item of This.Streams loop
         Free (Item.Head);
         Free (Item.Content);
         Free (Item.Output);
         Item := (others => <>);
      end loop;
      Free (This.Block);
      This.Open_Count         := 0;
      This.Event_Count        := 0;
      This.First_Event        := 0;
      This.Preface_Seen       := False;
      This.Settings_Seen      := False;
      This.Failed             := False;
      This.Going_Away         := False;
      This.Last_Client_Stream := 0;
      This.Block_Stream       := 0;
      This.Receive_Window     := Default_Window;
      This.Receive_Credit     := 0;
      This.Send_Window        := Default_Window;
      This.Peer_Initial       := Default_Window;
      This.Next_Lane          := 1;
      This.Resets_In_Window   := 0;
      This.Reset_Window_Start := 0;
   end Free;

end Sparrow.Http.Http_2;
