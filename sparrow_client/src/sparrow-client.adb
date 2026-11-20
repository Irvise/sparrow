with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Sparrow.Chunked;
with Sparrow.Encoding; use Sparrow.Encoding;
with Sparrow.IO; use Sparrow.IO;
with Sparrow.IO.Process;
with Sparrow.IO.Sockets;
with Sparrow.Times; use Sparrow.Times;
with Sparrow.Tls;

package body Sparrow.Client is

   use Sparrow.Buffers;
   use type Client_Wire.Parse_Outcome;
   use type Client_Wire.Body_Framing;
   use type Client_Wire.Port_Number;
   use type Chunked.Decoder_State;
   use type Tls.Outcome;

   Max_Head_Length : constant := 65_536;
   Read_Size       : constant := 16_384;
   Max_Addresses   : constant := 8;

   --  The system's trust store, opened at the first https request without a Trust_File and shared after.
   System_Trust : Tls.Context;

   protected Trust_Opening is
      procedure Open (Opened : out Boolean);
   end Trust_Opening;

   protected body Trust_Opening is
      procedure Open (Opened : out Boolean) is begin
         if not Tls.Is_Open (System_Trust) then
            Tls.Open_Client (System_Trust);
         end if;
         Opened := Tls.Is_Open (System_Trust);
      end Open;
   end Trust_Opening;

   ---------------------------------------------------------------------------------------------------------------
   --  the request

   function Is_Token (Symbol : Character) return Boolean is
     (Symbol in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
              | '!' | '#' | '$' | '%' | '&' | ''' | '*' | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~');

   function Is_Field_Text (Text : String) return Boolean is
     (for all Symbol of Text => (Symbol >= ' ' or else Symbol = ASCII.HT) and then Symbol /= Character'Val (127));

   --  The caller's header lines, each checked and ended by CRLF.
   function Checked_Headers (Headers : String) return String is
      Result : Unbounded_String;
      Start  : Positive := Headers'First;
   begin
      for Index in Headers'First .. Headers'Last + 1 loop
         if Index > Headers'Last or else Headers (Index) = ASCII.LF then
            declare
               Last : Natural := Index - 1;
            begin
               if Last >= Start and then Headers (Last) = ASCII.CR then
                  Last := Last - 1;
               end if;
               if Last >= Start then
                  declare
                     Line  : String renames Headers (Start .. Last);
                     Colon : Natural := 0;
                  begin
                     for Position in Line'Range loop
                        if Line (Position) = ':' then
                           Colon := Position;
                           exit;
                        end if;
                     end loop;
                     if Colon <= Line'First
                       or else (for some Symbol of Line (Line'First .. Colon - 1) => not Is_Token (Symbol))
                       or else not Is_Field_Text (Line (Colon + 1 .. Line'Last))
                     then
                        raise Request_Error with "a malformed header line: " & Line;
                     end if;
                     declare
                        Name : constant String := Line (Line'First .. Colon - 1);
                     begin
                        if Equal_Ignoring_Case (Name, "host") or else Equal_Ignoring_Case (Name, "content-length")
                          or else Equal_Ignoring_Case (Name, "transfer-encoding")
                          or else Equal_Ignoring_Case (Name, "connection")
                        then
                           raise Request_Error with "the client writes the " & Name & " header itself";
                        end if;
                     end;
                     Append (Result, Line & ASCII.CR & ASCII.LF);
                  end;
               end if;
               Start := Index + 1;
            end;
         end if;
      end loop;
      return To_String (Result);
   end Checked_Headers;

   function Has_Header (Lines : String; Name : String) return Boolean is
      Start : Positive := Lines'First;
   begin
      for Index in Lines'Range loop
         if Lines (Index) = ASCII.LF then
            if Index - Start > Name'Length and then Lines (Start + Name'Length) = ':'
              and then Equal_Ignoring_Case (Lines (Start .. Start + Name'Length - 1), Name)
            then
               return True;
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return False;
   end Has_Header;

   function Image (Port : Client_Wire.Port_Number) return String is
      Text : constant String := Port'Image;
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   --  Where a request goes.
   type Destination is record
      Secure : Boolean;
      Host   : Unbounded_String;   --  without brackets
      Port   : Client_Wire.Port_Number;
      Target : Unbounded_String;   --  from its '/'
      Origin : Unbounded_String;   --  "https://host:port", to compare redirects with
      Header : Unbounded_String;   --  the value of Host
   end record;

   function Destination_Of (Url : String) return Destination is
      Text  : constant String (1 .. Url'Length) := Url;
      Parts : constant Client_Wire.Url_Parts :=
        (if Text'Last < Positive'Last then Client_Wire.Split_Url (Text) else (Valid => False));
   begin
      if not Parts.Valid then
         raise Request_Error with "not an http or https URL: " & Url;
      end if;
      declare
         Host        : constant String := Slice (Text, Parts.Host);
         Target      : constant String := Slice (Text, Parts.Target);
         Default     : constant Client_Wire.Port_Number := (if Parts.Secure then 443 else 80);
         Shown_Host  : constant String := (if Parts.Bracketed then "[" & Host & "]" else Host);
         Host_Header : constant String :=
           Shown_Host & (if Parts.Port = Default then "" else ":" & Image (Parts.Port));
      begin
         return (Secure => Parts.Secure,
                 Host   => To_Unbounded_String (Host),
                 Port   => Parts.Port,
                 Target => To_Unbounded_String
                             (if Target'Length = 0 then "/" elsif Target (Target'First) = '/' then Target
                              else "/" & Target),
                 Origin => To_Unbounded_String
                             ((if Parts.Secure then "https://" else "http://") & Shown_Host & ":"
                              & Image (Parts.Port)),
                 Header => To_Unbounded_String (Host_Header));
      end;
   end Destination_Of;

   --  A redirect's Location, against the URL it answered. Dot segments are left to the server.
   function Resolve (Location : String; Base : Destination) return String is
      Scheme    : constant String := (if Base.Secure then "https:" else "http:");
      Origin    : constant String := Scheme & "//" & To_String (Base.Header);
      Target    : constant String := To_String (Base.Target);
      Path_Last : Natural := Target'Last;   --  before the query
      Slash     : Natural := Target'First;  --  the path's last '/'
      Colon     : Natural := 0;             --  the end of Location's scheme, if it has one
   begin
      for Index in Target'Range loop
         if Target (Index) = '?' then
            Path_Last := Index - 1;
            exit;
         end if;
      end loop;
      for Index in Target'First .. Path_Last loop
         if Target (Index) = '/' then
            Slash := Index;
         end if;
      end loop;
      for Index in Location'Range loop
         exit when Location (Index) in '/' | '?' | '#';
         if Location (Index) = ':' then
            Colon := Index;
            exit;
         end if;
      end loop;

      if Colon > Location'First then
         return Location;
      elsif Location'Length >= 2 and then Location (Location'First .. Location'First + 1) = "//" then
         return Scheme & Location;
      elsif Location'Length > 0 and then Location (Location'First) = '/' then
         return Origin & Location;
      elsif Location'Length > 0 and then Location (Location'First) = '?' then
         return Origin & Target (Target'First .. Path_Last) & Location;
      else
         return Origin & Target (Target'First .. Slash) & Location;
      end if;
   end Resolve;

   ---------------------------------------------------------------------------------------------------------------
   --  the connection

   type Connection is limited record
      Socket  : Descriptor := No_Descriptor;
      Secure  : Boolean := False;
      Session : Tls.Session;
   end record;

   procedure Close (This : in out Connection) is begin
      if Tls.Is_Active (This.Session) then
         Tls.Free (This.Session);
      end if;
      if This.Socket /= No_Descriptor then
         IO.Close (This.Socket);
         This.Socket := No_Descriptor;
      end if;
   end Close;

   --  The time left before Deadline, at least 1 ms; Request_Error when it has passed.
   function Time_Left (Deadline : Milliseconds; What : String) return Milliseconds is
      Now : Milliseconds;
   begin
      IO.Process.Read_Monotonic (Now);
      if Now >= Deadline then
         raise Request_Error with What & ": the time ran out";
      end if;
      return Milliseconds'Min (Deadline - Now, 3_600_000);
   end Time_Left;

   procedure Open
     (This     : in out Connection;
      Where    : Destination;
      Trust    : Tls.Context;
      Using    : Settings;
      Deadline : Milliseconds)
   is
      Host      : constant String := To_String (Where.Host);
      Addresses : IO.Sockets.Address_List (1 .. Max_Addresses);
      Found     : Natural;
      Failure   : Error := No_Error;
      Ready     : Boolean;
      Limit     : constant Milliseconds :=
        Milliseconds'Min (Milliseconds (Using.Connect_Timeout), Time_Left (Deadline, Host));
      Result    : Tls.Outcome;
   begin
      IO.Process.Prepare_Networking (Ready);
      if not Ready then
         raise Request_Error with "the system's networking did not start";
      end if;
      IO.Sockets.Resolve_All (Host, Addresses, Found);
      if Found = 0 then
         raise Request_Error with Host & ": the host name does not resolve";
      end if;
      for Address of Addresses (1 .. Found) loop
         IO.Sockets.Connect (Address, IO.Sockets.Port_Number (Where.Port), This.Socket, Failure, Timeout => Limit);
         exit when This.Socket /= No_Descriptor;
      end loop;
      if This.Socket = No_Descriptor then
         raise Request_Error with To_String (Where.Origin) & ": " & Message (Failure);
      end if;

      This.Secure := Where.Secure;
      if Where.Secure then
         Tls.Start_Client (This.Session, Trust, Tls.Socket_Handle (This.Socket), Host);
         if not Tls.Is_Active (This.Session) then
            raise Request_Error with To_String (Where.Origin) & ": TLS did not start";
         end if;
         Tls.Handshake (This.Session, Result);
         if Result /= Tls.Done then
            raise Request_Error with To_String (Where.Origin) & ": "
              & (if Result in Tls.Want_Read | Tls.Want_Write then "the TLS handshake timed out"
                 else "TLS: " & Tls.Last_Failure (This.Session));
         end if;
      end if;
      IO.Sockets.Set_Timeout (This.Socket, Time_Left (Deadline, Host));
   end Open;

   procedure Write (This : in out Connection; Data : String; Deadline : Milliseconds) is
      Sent : Natural := 0;
   begin
      while Sent < Data'Length loop
         declare
            Rest : String renames Data (Data'First + Sent .. Data'Last);
         begin
            if This.Secure then
               declare
                  Count  : Natural;
                  Result : Tls.Outcome;
               begin
                  Tls.Send (This.Session, Rest, Count, Result);
                  if Result /= Tls.Done then
                     raise Request_Error with
                       (if Result in Tls.Want_Read | Tls.Want_Write then "sending timed out"
                        else "sending failed: " & Tls.Last_Failure (This.Session));
                  end if;
                  Sent := Sent + Count;
               end;
            else
               declare
                  Count   : Integer;
                  Failure : Error;
               begin
                  IO.Sockets.Send (This.Socket, Rest, Count, Failure);
                  if Count < 0 and then Failure.Kind /= Interrupted then
                     raise Request_Error with
                       (if Failure.Kind in Would_Block | Timed_Out then "sending timed out"
                        else "sending failed: " & Message (Failure));
                  end if;
                  Sent := Sent + Integer'Max (Count, 0);
               end;
            end if;
         end;
         if Sent < Data'Length then
            IO.Sockets.Set_Timeout (This.Socket, Time_Left (Deadline, "sending"));
         end if;
      end loop;
   end Write;

   --  At least one more byte into Input; False at the end of the stream.
   function Read_More (This : in out Connection; Input : in out Buffer; Deadline : Milliseconds) return Boolean is
   begin
      IO.Sockets.Set_Timeout (This.Socket, Time_Left (Deadline, "waiting for the answer"));
      Reserve (Input, Read_Size);
      if Capacity (Input) - Input.Length < 1 then
         raise Request_Error with "the answer is larger than this client can hold";
      end if;
      loop
         declare
            Room : String renames Input.Data (Input.Length + 1 .. Capacity (Input));
         begin
            if This.Secure then
               declare
                  Count  : Natural;
                  Result : Tls.Outcome;
               begin
                  Tls.Receive (This.Session, Room, Count, Result);
                  case Result is
                     when Tls.Done =>
                        Extend (Input, Count);
                        return True;
                     when Tls.Closed =>
                        return False;
                     when Tls.Want_Read | Tls.Want_Write =>
                        raise Request_Error with "the time ran out waiting for the answer";
                     when Tls.Failed =>
                        raise Request_Error with "receiving failed: " & Tls.Last_Failure (This.Session);
                  end case;
               end;
            else
               declare
                  Count   : Integer;
                  Failure : Error;
               begin
                  IO.Sockets.Receive (This.Socket, Room, Count, Failure);
                  if Count > 0 then
                     Extend (Input, Count);
                     return True;
                  elsif Count = 0 then
                     return False;
                  elsif Failure.Kind /= Interrupted then
                     raise Request_Error with
                       (if Failure.Kind in Would_Block | Timed_Out then "the time ran out waiting for the answer"
                        else "receiving failed: " & Message (Failure));
                  end if;
               end;
            end if;
         end;
      end loop;
   end Read_More;

   ---------------------------------------------------------------------------------------------------------------
   --  one exchange

   procedure Exchange
     (Method   : String;
      Where    : Destination;
      Request  : String;
      Answer   : in out Response;
      Trust    : Tls.Context;
      Using    : Settings;
      Deadline : Milliseconds)
   is
      Link  : Connection;
      Input : Buffer;
      Head  : Client_Wire.Response_Head;

      procedure Too_Large is begin
         raise Request_Error with "the answer is larger than" & Using.Max_Response'Image & " bytes";
      end Too_Large;
   begin
      Open (Link, Where, Trust, Using, Deadline);
      Write (Link, Request, Deadline);

      --  The head, after any interim (1xx) ones.
      loop
         Head := Client_Wire.Parse_Head (Content (Input), Method = "HEAD", Max_Head_Length);
         case Head.Outcome is
            when Client_Wire.Invalid =>
               raise Request_Error with "the answer is not HTTP/1.1";
            when Client_Wire.Incomplete =>
               if not Read_More (Link, Input, Deadline) then
                  raise Request_Error with
                    (if Input.Length = 0 then "the server closed the connection without answering"
                     else "the answer's head is cut short");
               end if;
            when Client_Wire.Complete =>
               if Head.Status = 101 then
                  raise Request_Error with "the server switched protocols";
               end if;
               exit when Head.Status >= 200;
               Consume (Input, Head.Head_Length);
         end case;
      end loop;

      Clear (Answer.Head);
      Append (Answer.Head, Input.Data (1 .. Head.Head_Length));
      Answer.Parsed  := Head;
      Answer.Status  := Head.Status;
      Answer.Version := 10 + Head.Minor_Version;
      Consume (Input, Head.Head_Length);

      case Head.Framing is
         when Client_Wire.No_Body =>
            null;

         when Client_Wire.Sized =>
            if Head.Body_Length > Client_Wire.Body_Size (Using.Max_Response) then
               Too_Large;
            end if;
            while Input.Length < Natural (Head.Body_Length) loop
               if not Read_More (Link, Input, Deadline) then
                  raise Request_Error with "the answer's content is cut short";
               end if;
            end loop;
            Append (Answer.Content, Input.Data (1 .. Natural (Head.Body_Length)));

         when Client_Wire.Until_Close =>
            loop
               if Input.Length > Using.Max_Response then
                  Too_Large;
               end if;
               exit when not Read_More (Link, Input, Deadline);
            end loop;
            if Input.Length > Using.Max_Response then
               Too_Large;
            end if;
            Append (Answer.Content, Content (Input));

         when Client_Wire.Chunks =>
            declare
               --  Framing bounds the work, not the memory: even chunks of one byte stay under it.
               Framing  : constant Natural :=
                 Natural (Long_Long_Integer'Min (8 * Long_Long_Integer (Using.Max_Response) + 65_536,
                                                 Long_Long_Integer (Natural'Last)));
               Chunks   : Chunked.Decoder := Chunked.New_Decoder (Chunked.Body_Size (Using.Max_Response), Framing);
               Consumed : Natural;
               Part     : Span;
            begin
               loop
                  while Input.Length > 0 and then Chunks.State not in Chunked.Done | Chunked.Failed loop
                     Chunked.Decode (Chunks, Input.Data (1 .. Input.Length), Consumed, Part);
                     Append (Answer.Content, Slice (Input.Data (1 .. Input.Length), Part));
                     Consume (Input, Consumed);
                  end loop;
                  if Chunks.State = Chunked.Failed then
                     if Chunks.Too_Large then
                        Too_Large;
                     end if;
                     raise Request_Error with "the answer's chunked content is malformed";
                  end if;
                  exit when Chunks.State = Chunked.Done;
                  if not Read_More (Link, Input, Deadline) then
                     raise Request_Error with "the answer's content is cut short";
                  end if;
               end loop;
            end;
      end case;

      if Answer.Content.Overflowed then
         Too_Large;
      end if;
      Free (Input);
      Close (Link);
   exception
      when others =>
         Free (Input);
         Close (Link);
         raise;
   end Exchange;

   ---------------------------------------------------------------------------------------------------------------

   function Status (This : Response) return Natural is (This.Status);
   function Version (This : Response) return Natural is (This.Version);
   function Content (This : Response) return String is (Buffers.Content (This.Content));

   function Header (This : Response; Name : String) return String is
   begin
      if This.Parsed.Outcome /= Client_Wire.Complete then
         return "";
      end if;
      declare
         Head  : constant String := Buffers.Content (This.Head);
         Value : constant Span := Client_Wire.Header_Value (Head, This.Parsed, Name);
         Found : constant String (1 .. Length (Value)) := Slice (Head, Value);
      begin
         return Found;
      end;
   end Header;

   overriding procedure Finalize (This : in out Response) is begin
      Free (This.Head);
      Free (This.Content);
   end Finalize;

   procedure Send
     (Method     : String;
      Url        : String;
      Answer     : out Response;
      Content    : String := "";
      Media_Type : String := "application/json";
      Headers    : String := "";
      Using      : Settings := Default_Settings)
   is
      Started     : Milliseconds;
      Deadline    : Milliseconds;
      Own_Trust   : Tls.Context;
      Lines       : constant String := Checked_Headers (Headers);
      Verb        : Unbounded_String := To_Unbounded_String (Method);
      Payload     : Unbounded_String := To_Unbounded_String (Content);
      Where       : Destination := Destination_Of (Url);
      First_Where : constant Destination := Where;

      function Request return String is
         Verb_Text    : constant String := To_String (Verb);
         Content_Text : constant String := To_String (Payload);
         Same_Origin  : constant Boolean := Where.Origin = First_Where.Origin;
         Own_Lines    : constant String := (if Same_Origin then Lines else "");
      begin
         return Verb_Text & " " & To_String (Where.Target) & " HTTP/1.1" & ASCII.CR & ASCII.LF
           & "Host: " & To_String (Where.Header) & ASCII.CR & ASCII.LF
           & (if Has_Header (Own_Lines, "user-agent") then "" else "User-Agent: Sparrow" & ASCII.CR & ASCII.LF)
           & (if Has_Header (Own_Lines, "accept") then "" else "Accept: */*" & ASCII.CR & ASCII.LF)
           & (if Content_Text'Length > 0 then "Content-Type: " & Media_Type & ASCII.CR & ASCII.LF else "")
           & (if Content_Text'Length > 0 or else Verb_Text in "POST" | "PUT" | "PATCH"
              then "Content-Length:" & Content_Text'Length'Image & ASCII.CR & ASCII.LF else "")
           & "Connection: close" & ASCII.CR & ASCII.LF
           & Own_Lines
           & ASCII.CR & ASCII.LF
           & Content_Text;
      end Request;

      procedure Clean_Up is begin
         if Tls.Is_Open (Own_Trust) then
            Tls.Close (Own_Trust);
         end if;
      end Clean_Up;
   begin
      Clear (Answer.Head);
      Clear (Answer.Content);
      Answer.Status  := 0;
      Answer.Version := 0;
      Answer.Parsed  := (Outcome => Client_Wire.Incomplete);
      if Method'Length = 0 or else (for some Symbol of Method => not Is_Token (Symbol)) then
         raise Request_Error with "not a method: " & Method;
      elsif not Is_Field_Text (Media_Type) then
         raise Request_Error with "a malformed media type";
      end if;
      IO.Process.Read_Monotonic (Started);
      Deadline := Started + Milliseconds (Using.Timeout);
      if Using.Trust_File /= null then
         Tls.Open_Client (Own_Trust, Trust_File => Using.Trust_File.all);
         if not Tls.Is_Open (Own_Trust) then
            raise Request_Error with "TLS: " & Tls.Last_Failure (Own_Trust);
         end if;
      end if;

      for Hop in 0 .. Max_Redirects loop
         if Where.Secure and then Using.Trust_File = null then
            declare
               Opened : Boolean;
            begin
               Trust_Opening.Open (Opened);
               if not Opened then
                  raise Request_Error with "TLS: " & Tls.Last_Failure (System_Trust);
               end if;
            end;
         end if;
         Clear (Answer.Content);
         if Using.Trust_File = null then
            Exchange (To_String (Verb), Where, Request, Answer, System_Trust, Using, Deadline);
         else
            Exchange (To_String (Verb), Where, Request, Answer, Own_Trust, Using, Deadline);
         end if;
         exit when not Using.Follow_Redirects or else Answer.Status not in 301 | 302 | 303 | 307 | 308;
         declare
            Location : constant String := Header (Answer, "Location");
         begin
            exit when Location = "" or else Hop = Max_Redirects;
            Where := Destination_Of (Resolve (Location, Where));
            if Answer.Status in 301 | 302 | 303 and then To_String (Verb) /= "HEAD" then
               Verb    := To_Unbounded_String ("GET");
               Payload := Null_Unbounded_String;
            end if;
         end;
      end loop;
      Clean_Up;
   exception
      when others =>
         Clean_Up;
         raise;
   end Send;

   procedure Get
     (Url      : String;
      Answer   : out Response;
      Headers  : String := "";
      Using    : Settings := Default_Settings)
   is begin
      Send ("GET", Url, Answer, Headers => Headers, Using => Using);
   end Get;

   procedure Post
     (Url        : String;
      Content    : String;
      Answer     : out Response;
      Media_Type : String := "application/json";
      Headers    : String := "";
      Using      : Settings := Default_Settings)
   is begin
      Send ("POST", Url, Answer, Content, Media_Type, Headers, Using);
   end Post;

   function Url_Encode (Text : String) return String is
      Hex    : constant String := "0123456789ABCDEF";
      Result : String (1 .. Text'Length * 3);
      Last   : Natural := 0;
   begin
      for Symbol of Text loop
         if Symbol in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' then
            Last := Last + 1;
            Result (Last) := Symbol;
         else
            Result (Last + 1 .. Last + 3) :=
              ['%', Hex (Character'Pos (Symbol) / 16 + 1), Hex (Character'Pos (Symbol) mod 16 + 1)];
            Last := Last + 3;
         end if;
      end loop;
      return Result (1 .. Last);
   end Url_Encode;

end Sparrow.Client;
