with Sparrow.Encoding;
with Sparrow.Times;

package body Sparrow.Valkey is

   use Sparrow.Buffers;
   use Sparrow.IO;
   use type Sparrow.Tls.Outcome;
   use type IO.Sockets.Port_Number;
   use type Valkey_Protocol.Element_Kind;
   use type Valkey_Protocol.Scan_Outcome;

   Read_Chunk : constant := 16_384;

   ---------------
   -- Server_At --
   ---------------

   function Server_At (Url : String; Trust_File : String := ""; Timeout : Positive := 5_000) return Server is
      Result : Server := (Trust_File => To_Unbounded_String (Trust_File), Timeout => Timeout, others => <>);

      function Starts (Prefix : String) return Boolean is
        (Url'Length >= Prefix'Length and then Url (Url'First .. Url'First + Prefix'Length - 1) = Prefix);

      function Decoded (Text : String) return String is
         Into  : String (1 .. Text'Length);
         Last  : Natural;
         Valid : Boolean;
      begin
         Encoding.Percent_Decode (Text, Into, Last, Valid);
         if not Valid then
            raise Constraint_Error with "a broken %-escape in the server URL";
         end if;
         return Into (1 .. Last);
      end Decoded;

      function Whole (Text : String; Limit : Natural) return Natural is
         Value : Natural := 0;
      begin
         if Text'Length not in 1 .. 5 then
            raise Constraint_Error with "a bad number in the server URL";
         end if;
         for Digit of Text loop
            if Digit not in '0' .. '9' then
               raise Constraint_Error with "a bad number in the server URL";
            end if;
            Value := Value * 10 + Character'Pos (Digit) - Character'Pos ('0');
         end loop;
         if Value > Limit then
            raise Constraint_Error with "a number out of range in the server URL";
         end if;
         return Value;
      end Whole;

      First : Positive;
      Last  : Natural := Url'Last;
   begin
      if Starts ("valkey://") or else Starts ("redis://") then
         First := Url'First + (if Starts ("valkey://") then 9 else 8);
      elsif Starts ("valkeys://") or else Starts ("rediss://") then
         First := Url'First + (if Starts ("valkeys://") then 10 else 9);
         Result.Use_Tls := True;
      else
         raise Constraint_Error with "a server URL starts with valkey:// or valkeys://";
      end if;

      for Index in First .. Url'Last loop   --  the database, after the authority
         if Url (Index) = '/' then
            if Index < Url'Last then
               Result.Database := Whole (Url (Index + 1 .. Url'Last), Limit => 65_535);
            end if;
            Last := Index - 1;
            exit;
         end if;
      end loop;

      for Index in reverse First .. Last loop   --  the credentials, before the last '@'
         if Url (Index) = '@' then
            declare
               Credentials : String renames Url (First .. Index - 1);
               Colon       : Natural := 0;
            begin
               for Position in Credentials'Range loop
                  if Credentials (Position) = ':' then
                     Colon := Position;
                     exit;
                  end if;
               end loop;
               if Colon = 0 then
                  Result.User := To_Unbounded_String (Decoded (Credentials));
               else
                  Result.User     := To_Unbounded_String (Decoded (Credentials (Credentials'First .. Colon - 1)));
                  Result.Password := To_Unbounded_String (Decoded (Credentials (Colon + 1 .. Credentials'Last)));
               end if;
            end;
            First := Index + 1;
            exit;
         end if;
      end loop;

      declare
         Host_Port : String renames Url (First .. Last);
         Port_From : Natural := 0;   --  the ':' before the port
      begin
         if Host_Port'Length > 0 and then Host_Port (Host_Port'First) = '[' then   --  [IPv6]
            for Index in Host_Port'Range loop
               if Host_Port (Index) = ']' then
                  Result.Host := To_Unbounded_String (Host_Port (Host_Port'First + 1 .. Index - 1));
                  if Index < Host_Port'Last then
                     if Host_Port (Index + 1) /= ':' then
                        raise Constraint_Error with "a bad host in the server URL";
                     end if;
                     Port_From := Index + 1;
                  end if;
                  exit;
               end if;
            end loop;
            if Length (Result.Host) = 0 then
               raise Constraint_Error with "a bad host in the server URL";
            end if;
         else
            for Index in reverse Host_Port'Range loop
               if Host_Port (Index) = ':' then
                  Port_From := Index;
                  exit;
               end if;
            end loop;
            Result.Host := To_Unbounded_String
              (Host_Port (Host_Port'First .. (if Port_From = 0 then Host_Port'Last else Port_From - 1)));
         end if;
         if Port_From /= 0 then
            Result.Port := IO.Sockets.Port_Number (Whole (Host_Port (Port_From + 1 .. Host_Port'Last), 65_535));
         end if;
      end;

      if Length (Result.Host) not in 1 .. 255 or else Result.Port = 0 then
         raise Constraint_Error with "a bad host or port in the server URL";
      end if;
      return Result;
   end Server_At;

   --  Close This and raise Connection_Error with Message.
   procedure Fail (This : in out Connection; Message : String) with No_Return is
      Name : constant String := To_String (This.Name);
   begin
      Close (This);
      raise Connection_Error with "valkey " & Name & ": " & Message;
   end Fail;

   --  Send all of Output.
   procedure Send_Output (This : in out Connection) is
      Sent_Bytes : Natural := 0;
   begin
      while Sent_Bytes < This.Output.Length loop
         declare
            Pending : String renames This.Output.Data (Sent_Bytes + 1 .. This.Output.Length);
         begin
            if This.Use_Tls then
               declare
                  Count  : Natural;
                  Result : Tls.Outcome;
               begin
                  Tls.Send (This.Session, Pending, Count, Result);
                  if Result /= Tls.Done then
                     Fail (This, (if Result in Tls.Want_Read | Tls.Want_Write then "timed out sending"
                                  else "sending failed: " & Tls.Last_Failure (This.Session)));
                  end if;
                  Sent_Bytes := Sent_Bytes + Count;
               end;
            else
               declare
                  Count   : Integer;
                  Failure : IO.Error;
               begin
                  IO.Sockets.Send (This.Socket, Pending, Count, Failure);
                  if Count < 0 then
                     if Failure.Kind = Interrupted then
                        Count := 0;
                     else
                        Fail (This, (if Failure.Kind in Would_Block | Timed_Out then "timed out sending"
                                     else "sending failed: " & Message (Failure)));
                     end if;
                  end if;
                  Sent_Bytes := Sent_Bytes + Count;
               end;
            end if;
         end;
      end loop;
      Clear (This.Output);
   end Send_Output;

   --  Receive at least one more byte into Input.
   procedure Receive_More (This : in out Connection) is
   begin
      Reserve (This.Input, Natural'Max (Read_Chunk, This.Input.Length - This.Taken));
      if Capacity (This.Input) = This.Input.Length then
         Fail (This, "a reply too large to hold");
      end if;
      loop
         declare
            Room : String renames This.Input.Data (This.Input.Length + 1 .. Capacity (This.Input));
         begin
            if This.Use_Tls then
               declare
                  Count  : Natural;
                  Result : Tls.Outcome;
               begin
                  Tls.Receive (This.Session, Room, Count, Result);
                  case Result is
                     when Tls.Done =>
                        Extend (This.Input, Count);
                        return;
                     when Tls.Want_Read | Tls.Want_Write =>
                        Fail (This, "timed out waiting for a reply");
                     when Tls.Closed =>
                        Fail (This, "the server closed the connection");
                     when Tls.Failed =>
                        Fail (This, "receiving failed: " & Tls.Last_Failure (This.Session));
                  end case;
               end;
            else
               declare
                  Count   : Integer;
                  Failure : IO.Error;
               begin
                  IO.Sockets.Receive (This.Socket, Room, Count, Failure);
                  if Count > 0 then
                     Extend (This.Input, Count);
                     return;
                  elsif Count = 0 then
                     Fail (This, "the server closed the connection");
                  elsif Failure.Kind /= Interrupted then
                     Fail (This, (if Failure.Kind in Would_Block | Timed_Out then "timed out waiting for a reply"
                                  else "receiving failed: " & Message (Failure)));
                  end if;
               end;
            end if;
         end;
      end loop;
   end Receive_More;

   -------------
   -- Connect --
   -------------

   procedure Connect (This : in out Connection; Where : Server) is
      Host      : constant String := To_String (Where.Host);
      Addresses : IO.Sockets.Address_List (1 .. 8);
      Found     : Natural;
      Failure   : IO.Error;
   begin
      if Is_Connected (This) then
         Close (This);
      end if;
      This.Name := To_Unbounded_String
        ((if (for some Symbol of Host => Symbol = ':') then "[" & Host & "]" else Host)
         & ":" & Encoding.Decimal_Image (Long_Long_Integer (Where.Port)));

      IO.Sockets.Resolve_All (Host, Addresses, Found);
      if Found = 0 then
         raise Connection_Error with "valkey " & To_String (This.Name) & ": the host name does not resolve";
      end if;
      for Address of Addresses (1 .. Found) loop   --  "localhost" may be ::1 and 127.0.0.1: the server on either
         IO.Sockets.Connect
           (Address, Where.Port, This.Socket, Failure,
            Timeout => Times.Milliseconds (Positive'Min (Where.Timeout, 3_600_000)));
         exit when This.Socket /= No_Descriptor;
      end loop;
      if This.Socket = No_Descriptor then
         raise Connection_Error with "valkey " & To_String (This.Name) & ": " & Message (Failure);
      end if;

      This.Use_Tls := Where.Use_Tls;
      if Where.Use_Tls then
         Tls.Open_Client (This.Context, Trust_File => To_String (Where.Trust_File));
         if not Tls.Is_Open (This.Context) then
            Fail (This, "TLS: " & Tls.Last_Failure (This.Context));
         end if;
         Tls.Start_Client (This.Session, This.Context, Tls.Socket_Handle (This.Socket), Host);
         loop
            declare
               Result : Tls.Outcome;
            begin
               Tls.Handshake (This.Session, Result);
               exit when Result = Tls.Done;
               Fail (This, (if Result in Tls.Want_Read | Tls.Want_Write then "timed out in the TLS handshake"
                            else "TLS: " & Tls.Last_Failure (This.Session)));
            end;
         end loop;
      end if;

      if Length (Where.Password) > 0 then
         Start (This, "AUTH");
         if Length (Where.User) > 0 then
            Add (This, To_String (Where.User));
         end if;
         Add (This, To_String (Where.Password));
      end if;
      if Where.Database /= 0 then
         Start (This, "SELECT");
         Add (This, Long_Long_Integer (Where.Database));
      end if;
      if Replies_Due (This) = 0 then   --  something to answer, so that a server that will not shows now
         Start (This, "PING");
      end if;
      while Replies_Due (This) > 0 loop
         declare
            Answer : Reply;
         begin
            Read_Reply (This, Answer);
            if Answer.Kind = Error then
               Fail (This, Text (This, Answer));   --  the server's words: never the password
            end if;
         end;
      end loop;
   end Connect;

   -----------
   -- Close --
   -----------

   procedure Close (This : in out Connection) is
   begin
      if Tls.Is_Active (This.Session) then
         declare
            Ignored : Tls.Outcome;
         begin
            Tls.Shut_Down (This.Session, Ignored);
         end;
         Tls.Free (This.Session);
      end if;
      if Tls.Is_Open (This.Context) then
         Tls.Close (This.Context);
      end if;
      if This.Socket /= No_Descriptor then
         IO.Close (This.Socket);
         This.Socket := No_Descriptor;
      end if;
      Clear (This.Output);
      Clear (This.Arguments);
      Clear (This.Input);
      This.Argument_Sum := 0;
      This.Building     := False;
      This.Sent         := 0;
      This.Taken        := 0;
   end Close;

   overriding procedure Finalize (This : in out Connection) is
   begin
      Close (This);
      Free (This.Output);
      Free (This.Arguments);
      Free (This.Input);
   end Finalize;

   ---------------------------------------------------------------------------------------------------------------
   --  Commands

   --  Move the command being built into Output.
   procedure End_Command (This : in out Connection) is
   begin
      if This.Building then
         Append (This.Output, Valkey_Protocol.Header (This.Argument_Sum));
         Append (This.Output, Content (This.Arguments));
         Clear (This.Arguments);
         This.Building     := False;
         This.Argument_Sum := 0;
         This.Sent         := This.Sent + 1;
      end if;
   end End_Command;

   procedure Start (This : in out Connection; Name : String) is
   begin
      End_Command (This);
      This.Building := True;
      Add (This, Name);
   end Start;

   procedure Add (This : in out Connection; Argument : String) is
   begin
      if not This.Building then
         raise Program_Error with "Add before Start";
      end if;
      Valkey_Protocol.Append_Argument (This.Arguments, Argument);
      This.Argument_Sum := This.Argument_Sum + 1;
   end Add;

   procedure Add (This : in out Connection; Argument : Long_Long_Integer) is
   begin
      Add (This, Encoding.Decimal_Image (Argument));
   end Add;

   procedure Flush (This : in out Connection) is
   begin
      End_Command (This);
      if This.Output.Overflowed or else This.Arguments.Overflowed then
         Fail (This, "commands too large to send");
      end if;
      if This.Output.Length > 0 then
         Send_Output (This);
      end if;
   end Flush;

   --  The reply of the element at Position of the input.
   function Reply_At (This : Connection; Position : Positive) return Reply is
      Item : constant Valkey_Protocol.Element :=
        Valkey_Protocol.Element_At (This.Input.Data (1 .. This.Input.Length), Position);
   begin
      return
        (Kind => (case Item.Kind is
                    when Valkey_Protocol.Simple_Text => Status,
                    when Valkey_Protocol.Error_Text  => Error,
                    when Valkey_Protocol.Whole_Number => Number,
                    when Valkey_Protocol.Bulk_Text   => Text,
                    when Valkey_Protocol.List        => List,
                    when others                      => Nil),
         Item => Item);
   end Reply_At;

   procedure Read_Reply (This : in out Connection; Answer : out Reply) is
   begin
      Flush (This);
      --  The replies before are no longer needed: drop their bytes when that is cheap or they take much room.
      if This.Taken = This.Input.Length then
         Clear (This.Input);
         This.Taken := 0;
      elsif This.Taken >= 65_536 then
         Consume (This.Input, This.Taken);
         This.Taken := 0;
      end if;
      Reserve (This.Input, Read_Chunk);   --  the first time, there is no storage yet
      loop
         declare
            Found : constant Valkey_Protocol.Scan_Result :=
              Valkey_Protocol.Scan (This.Input.Data (This.Taken + 1 .. This.Input.Length));
         begin
            case Found.Outcome is
               when Valkey_Protocol.Complete =>
                  Answer     := Reply_At (This, This.Taken + 1);
                  This.Taken := This.Taken + Found.Length;
                  This.Sent  := This.Sent - 1;
                  return;
               when Valkey_Protocol.Refused =>
                  Fail (This, "a malformed reply");
               when Valkey_Protocol.Waiting =>
                  Receive_More (This);
            end case;
         end;
      end loop;
   end Read_Reply;

   function Text (This : Connection; Answer : Reply) return String is
     (Encoding.Slice (This.Input.Data (1 .. This.Input.Length), Answer.Item.Text));

   function Item (This : Connection; Answer : Reply; Index : Positive) return Reply is
      Data     : String renames This.Input.Data (1 .. This.Input.Length);
      Position : Positive := Answer.Item.Next;
   begin
      for Skipped in 1 .. Index - 1 loop
         declare
            Found : constant Valkey_Protocol.Scan_Result := Valkey_Protocol.Scan (Data (Position .. Data'Last));
         begin
            Position := Position + Found.Length;   --  whole: the reply around it was scanned
         end;
      end loop;
      return Reply_At (This, Position);
   end Item;

   ---------------------------------------------------------------------------------------------------------------
   --  The everyday commands

   --  Read the reply to the one command just built, raising Command_Error for an Error reply.
   procedure Run (This : in out Connection; Answer : out Reply) is
   begin
      Read_Reply (This, Answer);
      if Answer.Kind = Error then
         raise Command_Error with Text (This, Answer);
      end if;
   end Run;

   function Unexpected (This : Connection; Answer : Reply) return String is
     ("valkey " & To_String (This.Name) & ": an unexpected " & Reply_Kind'Image (Answer.Kind) & " reply");

   function Get (This : in out Connection; Key : String; Default : String := "") return String is
      Answer : Reply;
   begin
      Start (This, "GET");
      Add (This, Key);
      Run (This, Answer);
      case Answer.Kind is
         when Text   => return Text (This, Answer);
         when Nil    => return Default;
         when others => raise Command_Error with Unexpected (This, Answer);
      end case;
   end Get;

   procedure Set (This : in out Connection; Key : String; Value : String; Lifetime : Natural := 0) is
      Answer : Reply;
   begin
      Start (This, "SET");
      Add (This, Key);
      Add (This, Value);
      if Lifetime > 0 then
         Add (This, "EX");
         Add (This, Long_Long_Integer (Lifetime));
      end if;
      Run (This, Answer);
   end Set;

   procedure Delete (This : in out Connection; Key : String) is
      Answer : Reply;
   begin
      Start (This, "DEL");
      Add (This, Key);
      Run (This, Answer);
   end Delete;

   --  The Number reply to the command just built.
   function Number_Of (This : in out Connection) return Long_Long_Integer is
      Answer : Reply;
   begin
      Run (This, Answer);
      if Answer.Kind /= Number then
         raise Command_Error with Unexpected (This, Answer);
      end if;
      return Answer.Item.Number;
   end Number_Of;

   function Exists (This : in out Connection; Key : String) return Boolean is
   begin
      Start (This, "EXISTS");
      Add (This, Key);
      return Number_Of (This) > 0;
   end Exists;

   function Increment (This : in out Connection; Key : String; By : Long_Long_Integer := 1) return Long_Long_Integer is
   begin
      Start (This, "INCRBY");
      Add (This, Key);
      Add (This, By);
      return Number_Of (This);
   end Increment;

   function Increment
     (This : in out Connection; Key : String; By : Long_Long_Integer := 1; Lifetime : Positive)
      return Long_Long_Integer
   is
      Answer : Reply;
   begin
      Start (This, "MULTI");
      Start (This, "INCRBY"); Add (This, Key); Add (This, By);
      Start (This, "EXPIRE"); Add (This, Key); Add (This, Long_Long_Integer (Lifetime)); Add (This, "NX");
      Start (This, "EXEC");
      for Queued in 1 .. 3 loop   --  OK, then QUEUED twice
         Read_Reply (This, Answer);
      end loop;
      Run (This, Answer);
      if Answer.Kind /= List or else Count (Answer) /= 2 then
         raise Command_Error with Unexpected (This, Answer);
      end if;
      declare
         Sum : constant Reply := Item (This, Answer, 1);
      begin
         case Sum.Kind is
            when Number => return Sum.Item.Number;
            when Error  => raise Command_Error with Text (This, Sum);
            when others => raise Command_Error with Unexpected (This, Sum);
         end case;
      end;
   end Increment;

   function Set_If_Absent
     (This : in out Connection; Key : String; Value : String; Lifetime : Natural := 0) return Boolean
   is
      Answer : Reply;
   begin
      Start (This, "SET"); Add (This, Key); Add (This, Value); Add (This, "NX");
      if Lifetime > 0 then
         Add (This, "EX");
         Add (This, Long_Long_Integer (Lifetime));
      end if;
      Run (This, Answer);
      return Answer.Kind = Status;
   end Set_If_Absent;

   function Expire (This : in out Connection; Key : String; Lifetime : Positive) return Boolean is
   begin
      Start (This, "EXPIRE");
      Add (This, Key);
      Add (This, Long_Long_Integer (Lifetime));
      return Number_Of (This) = 1;
   end Expire;

end Sparrow.Valkey;
