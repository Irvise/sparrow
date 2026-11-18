package body Sparrow.Client_Wire with SPARK_Mode is

   function Lower (Symbol : Character) return Character is
     (if Symbol in 'A' .. 'Z' then Character'Val (Character'Pos (Symbol) + 32) else Symbol);

   function Same_Text (Text, Name : String) return Boolean is
     (Text'Length = Name'Length
      and then (for all Offset in 0 .. Text'Length - 1 =>
                  Lower (Text (Text'First + Offset)) = Lower (Name (Name'First + Offset))));

   --  RFC 9110 5.6.2.
   function Is_Token (Symbol : Character) return Boolean is
     (Symbol in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
              | '!' | '#' | '$' | '%' | '&' | ''' | '*' | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~');

   function Is_Digit (Symbol : Character) return Boolean is (Symbol in '0' .. '9');

   function Digit (Symbol : Character) return Natural is (Character'Pos (Symbol) - Character'Pos ('0'))
     with Pre => Is_Digit (Symbol), Post => Digit'Result <= 9;

   ---------------
   -- Split_Url --
   ---------------

   function Split_Url (Url : String) return Url_Parts is
      Rejected       : constant Url_Parts := (Valid => False);
      Secure         : Boolean;
      Rest           : Positive;   --  the first byte after "://"
      Authority_Last : Natural;
      Host_First     : Positive;
      Host_Last      : Natural;
      Bracketed      : Boolean := False;
      Position       : Positive;
      Port           : Port_Number;
      Target_Last    : Natural;
   begin
      if Url'Length >= 7 and then Same_Text (Url (Url'First .. Url'First + 6), "http://") then
         Secure := False;
         Rest   := Url'First + 7;
      elsif Url'Length >= 8 and then Same_Text (Url (Url'First .. Url'First + 7), "https://") then
         Secure := True;
         Rest   := Url'First + 8;
      else
         return Rejected;
      end if;
      if Rest > Url'Last then
         return Rejected;
      end if;

      Authority_Last := Rest - 1;
      while Authority_Last < Url'Last and then Url (Authority_Last + 1) not in '/' | '?' | '#' loop
         pragma Loop_Invariant (Authority_Last in Rest - 1 .. Url'Last - 1);
         pragma Loop_Variant (Increases => Authority_Last);
         if Url (Authority_Last + 1) = '@' then
            return Rejected;
         end if;
         Authority_Last := Authority_Last + 1;
      end loop;
      if Authority_Last < Rest then
         return Rejected;
      end if;

      if Url (Rest) = '[' then
         Position := Rest + 1;
         while Position <= Authority_Last and then Url (Position) /= ']' loop
            pragma Loop_Invariant (Position in Rest + 1 .. Authority_Last);
            pragma Loop_Variant (Increases => Position);
            if Url (Position) not in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' | ':' | '.' then
               return Rejected;
            end if;
            Position := Position + 1;
         end loop;
         if Position > Authority_Last or else Position = Rest + 1 then
            return Rejected;
         end if;
         Host_First := Rest + 1;
         Host_Last  := Position - 1;
         Bracketed  := True;
         Position   := Position + 1;
      else
         Position := Rest;
         while Position <= Authority_Last and then Url (Position) /= ':' loop
            pragma Loop_Invariant (Position in Rest .. Authority_Last);
            pragma Loop_Variant (Increases => Position);
            if Url (Position) not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' then
               return Rejected;
            end if;
            Position := Position + 1;
         end loop;
         if Position = Rest then
            return Rejected;
         end if;
         Host_First := Rest;
         Host_Last  := Position - 1;
      end if;
      if Host_Last - Host_First + 1 > Max_Host_Length then
         return Rejected;
      end if;

      Port := (if Secure then 443 else 80);
      if Position <= Authority_Last then
         if Url (Position) /= ':' then
            return Rejected;
         elsif Position < Authority_Last then
            declare
               Value : Natural := 0;
            begin
               for Index in Position + 1 .. Authority_Last loop
                  pragma Loop_Invariant (Value <= 65_535);
                  if not Is_Digit (Url (Index)) then
                     return Rejected;
                  end if;
                  Value := Value * 10 + Digit (Url (Index));
                  if Value > 65_535 then
                     return Rejected;
                  end if;
               end loop;
               if Value = 0 then
                  return Rejected;
               end if;
               Port := Port_Number (Value);
            end;
         end if;
      end if;

      Target_Last := Authority_Last;
      while Target_Last < Url'Last and then Url (Target_Last + 1) /= '#' loop
         pragma Loop_Invariant (Target_Last in Authority_Last .. Url'Last - 1);
         pragma Loop_Variant (Increases => Target_Last);
         if Url (Target_Last + 1) <= ' ' or else Url (Target_Last + 1) = Character'Val (127) then
            return Rejected;
         end if;
         Target_Last := Target_Last + 1;
      end loop;

      return (Valid     => True,
              Secure    => Secure,
              Host      => (First => Host_First, Last => Host_Last),
              Bracketed => Bracketed,
              Port      => Port,
              Target    => (if Target_Last > Authority_Last then (First => Authority_Last + 1, Last => Target_Last)
                            else Empty));
   end Split_Url;

   ----------------
   -- Parse_Head --
   ----------------

   --  The line feed that ends the head's blank line; 0 when it has not arrived.
   function Head_End (Answer : String) return Natural
      with Post => Head_End'Result = 0
                   or else (Head_End'Result in Answer'Range and then Answer (Head_End'Result) = ASCII.LF)
   is
   begin
      for Index in Answer'Range loop
         if Answer (Index) = ASCII.LF and then Index > Answer'First then
            if Answer (Index - 1) = ASCII.LF
              or else (Answer (Index - 1) = ASCII.CR and then Index - 1 > Answer'First
                       and then Answer (Index - 2) = ASCII.LF)
            then
               return Index;
            end if;
         end if;
      end loop;
      return 0;
   end Head_End;

   --  The first line feed from From on; Last is one.
   function Next_Line_Feed (Answer : String; From, Last : Positive) return Positive
      with Pre  => From in Answer'Range and then Last in From .. Answer'Last and then Answer (Last) = ASCII.LF,
           Post => Next_Line_Feed'Result in From .. Last and then Answer (Next_Line_Feed'Result) = ASCII.LF
   is
   begin
      for Index in From .. Last loop
         if Answer (Index) = ASCII.LF then
            return Index;
         end if;
      end loop;
      return Last;
   end Next_Line_Feed;

   --  A Content-Length value: digits only.
   procedure Parse_Length (Answer : String; Item : Span; Value : out Body_Size; Valid : out Boolean)
      with Pre => Within (Item, Answer)
   is
   begin
      Value := 0;
      Valid := Length (Item) > 0;
      if not Valid then
         return;
      end if;
      for Index in Item.First .. Item.Last loop
         pragma Loop_Invariant (Valid and then Value <= Body_Size'Last);
         if not Is_Digit (Answer (Index)) or else Value > (Body_Size'Last - 9) / 10 then
            Valid := False;
            Value := 0;
            return;
         end if;
         Value := Value * 10 + Body_Size (Digit (Answer (Index)));
      end loop;
   end Parse_Length;

   --  Whether the last coding of a Transfer-Encoding value is chunked.
   function Ends_Chunked (Answer : String; Item : Span) return Boolean
      with Pre => Within (Item, Answer) and then Answer'Last < Positive'Last
   is
      First : Positive;
   begin
      if Length (Item) = 0 then
         return False;
      end if;
      First := Item.First;
      for Index in Item.First .. Item.Last loop
         pragma Loop_Invariant (First in Item.First .. Item.Last);
         if Answer (Index) = ',' and then Index < Item.Last then
            First := Index + 1;
         end if;
      end loop;
      while First <= Item.Last and then Answer (First) in ' ' | ASCII.HT loop
         pragma Loop_Invariant (First in Item.First .. Item.Last);
         pragma Loop_Variant (Increases => First);
         First := First + 1;
      end loop;
      return First <= Item.Last and then Same_Text (Answer (First .. Item.Last), "chunked");
   end Ends_Chunked;

   function Parse_Head (Answer : String; Asked_Head : Boolean; Max_Head_Length : Positive) return Response_Head is
      Last_Feed    : constant Natural := Head_End (Answer);
      Headers      : Header_List := [others => (Name => Empty, Value => Empty)];
      Header_Total : Header_Count := 0;
      Status       : Status_Code := 200;
      Minor        : Natural range 0 .. 1 := 1;
      Position     : Positive;
      Feed         : Positive;
      Line_Last    : Natural;
      Status_Seen  : Boolean := False;
      Blank_Feed   : Positive;
   begin
      if Last_Feed = 0 then
         return (if Answer'Length >= Max_Head_Length then (Outcome => Invalid) else (Outcome => Incomplete));
      elsif Last_Feed - Answer'First + 1 > Max_Head_Length then
         return (Outcome => Invalid);
      end if;

      Position := Answer'First;
      loop
         pragma Loop_Invariant (Position in Answer'First .. Last_Feed);
         pragma Loop_Invariant
           (for all Index in 1 .. Header_Total =>
               Within (Headers (Index).Name, Answer) and then Within (Headers (Index).Value, Answer));
         pragma Loop_Variant (Increases => Position);

         Feed      := Next_Line_Feed (Answer, Position, Last_Feed);
         Line_Last := (if Feed > Position and then Answer (Feed - 1) = ASCII.CR then Feed - 2 else Feed - 1);

         if not Status_Seen then
            --  HTTP/1.x SSS, then a space and a reason or nothing.
            if Line_Last - Position < 11
              or else Answer (Position .. Position + 6) /= "HTTP/1."
              or else Answer (Position + 7) not in '0' | '1'
              or else Answer (Position + 8) /= ' '
              or else Answer (Position + 9) not in '1' .. '9'
              or else not Is_Digit (Answer (Position + 10))
              or else not Is_Digit (Answer (Position + 11))
              or else (Line_Last - Position > 11 and then Answer (Position + 12) /= ' ')
            then
               return (Outcome => Invalid);
            end if;
            Minor  := (if Answer (Position + 7) = '1' then 1 else 0);
            Status := Digit (Answer (Position + 9)) * 100 + Digit (Answer (Position + 10)) * 10
                      + Digit (Answer (Position + 11));
            Status_Seen := True;

         elsif Line_Last < Position then
            Blank_Feed := Feed;
            exit;

         else
            if Answer (Position) in ' ' | ASCII.HT or else Header_Total = Max_Headers then
               return (Outcome => Invalid);   --  a folded line, or too many
            end if;
            declare
               Colon : Positive := Position;
               First : Positive;
               Last  : Natural := Line_Last;
            begin
               while Colon <= Line_Last and then Answer (Colon) /= ':' loop
                  pragma Loop_Invariant (Colon in Position .. Line_Last);
                  pragma Loop_Variant (Increases => Colon);
                  if not Is_Token (Answer (Colon)) then
                     return (Outcome => Invalid);
                  end if;
                  Colon := Colon + 1;
               end loop;
               if Colon > Line_Last or else Colon = Position then
                  return (Outcome => Invalid);
               end if;
               First := Colon + 1;
               while First <= Last and then Answer (First) in ' ' | ASCII.HT loop
                  pragma Loop_Invariant (First in Colon + 1 .. Last);
                  pragma Loop_Variant (Increases => First);
                  First := First + 1;
               end loop;
               while Last >= First and then Answer (Last) in ' ' | ASCII.HT loop
                  pragma Loop_Invariant (Last in First .. Line_Last);
                  pragma Loop_Variant (Decreases => Last);
                  Last := Last - 1;
               end loop;
               for Index in First .. Last loop
                  if (Answer (Index) < ' ' and then Answer (Index) /= ASCII.HT)
                    or else Answer (Index) = Character'Val (127)
                  then
                     return (Outcome => Invalid);
                  end if;
               end loop;
               Header_Total := Header_Total + 1;
               Headers (Header_Total) :=
                 (Name  => (First => Position, Last => Colon - 1),
                  Value => (if Last >= First then (First => First, Last => Last) else Empty));
            end;
         end if;

         if Feed = Last_Feed then
            return (Outcome => Invalid);   --  no blank line before the end: cannot happen, as Head_End found one
         end if;
         Position := Feed + 1;
      end loop;

      declare
         Framing       : Body_Framing := Until_Close;
         Body_Length   : Body_Size := 0;
         Has_Length    : Boolean := False;
         Coding        : Span := Empty;
         Has_Coding    : Boolean := False;
         Value         : Body_Size;
         Valid         : Boolean;
      begin
         for Index in 1 .. Header_Total loop
            pragma Loop_Invariant (Within (Coding, Answer));
            declare
               Name : constant String := Slice (Answer, Headers (Index).Name);
            begin
               if Same_Text (Name, "transfer-encoding") then
                  Has_Coding := True;
                  Coding     := Headers (Index).Value;
               elsif Same_Text (Name, "content-length") then
                  Parse_Length (Answer, Headers (Index).Value, Value, Valid);
                  if not Valid or else (Has_Length and then Value /= Body_Length) then
                     return (Outcome => Invalid);
                  end if;
                  Has_Length  := True;
                  Body_Length := Value;
               end if;
            end;
         end loop;

         if Asked_Head or else Status < 200 or else Status in 204 | 304 then
            Framing     := No_Body;
            Body_Length := 0;
         elsif Has_Coding then
            Framing     := (if Ends_Chunked (Answer, Coding) then Chunks else Until_Close);
            Body_Length := 0;
         elsif Has_Length then
            Framing := Sized;
         end if;

         return (Outcome       => Complete,
                 Status        => Status,
                 Minor_Version => Minor,
                 Headers       => Headers,
                 Header_Total  => Header_Total,
                 Head_Length   => Blank_Feed - Answer'First + 1,
                 Framing       => Framing,
                 Body_Length   => Body_Length);
      end;
   end Parse_Head;

   ------------------
   -- Header_Value --
   ------------------

   function Header_Value (Answer : String; Head : Response_Head; Name : String) return Span is
   begin
      for Index in 1 .. Head.Header_Total loop
         if Same_Text (Slice (Answer, Head.Headers (Index).Name), Name) then
            return Head.Headers (Index).Value;
         end if;
      end loop;
      return Empty;
   end Header_Value;

end Sparrow.Client_Wire;
