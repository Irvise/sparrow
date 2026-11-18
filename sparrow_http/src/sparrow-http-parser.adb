package body Sparrow.Http.Parser with SPARK_Mode is

   function Lower (Symbol : Character) return Character is
     (if Symbol in 'A' .. 'Z' then Character'Val (Character'Pos (Symbol) + 32) else Symbol);

   --  Case-insensitive comparison with a lower-case Name.
   function Same_Name (Text : String; Name : String) return Boolean is
     (Text'Length = Name'Length
      and then (for all Offset in 0 .. Text'Length - 1 =>
                  Lower (Text (Text'First + Offset)) = Name (Name'First + Offset)));

   --  Whether Token is one of the comma-separated elements of Text, compared without case.
   function Contains_Token (Text : String; Token : String) return Boolean
      with Pre => Text'Last < Positive'Last
   is
      First : Integer := Text'First;
      Last  : Natural;
   begin
      while First <= Text'Last loop
         pragma Loop_Invariant (First >= Text'First);
         pragma Loop_Variant (Increases => First);
         Last := First;
         while Last <= Text'Last and then Text (Last) /= ',' loop
            pragma Loop_Invariant (Last in First .. Text'Last);
            pragma Loop_Variant (Increases => Last);
            Last := Last + 1;
         end loop;

         declare
            Element_First : Positive := First;
            Element_Last  : Natural := Last - 1;
         begin
            while Element_First <= Element_Last and then Text (Element_First) in ' ' | ASCII.HT loop
               pragma Loop_Invariant (Element_First in First .. Element_Last);
               pragma Loop_Variant (Increases => Element_First);
               Element_First := Element_First + 1;
            end loop;
            while Element_Last >= Element_First and then Text (Element_Last) in ' ' | ASCII.HT loop
               pragma Loop_Invariant (Element_Last in Element_First .. Last - 1);
               pragma Loop_Variant (Decreases => Element_Last);
               Element_Last := Element_Last - 1;
            end loop;
            if Same_Name (Text (Element_First .. Element_Last), Token) then
               return True;
            end if;
         end;
         exit when Last >= Text'Last;
         First := Last + 1;
      end loop;
      return False;
   end Contains_Token;

   --  The position of the first Symbol in Text (From .. Before - 1), or Before.
   function Find (Text : String; Symbol : Character; From, Before : Positive) return Positive
      with Pre  => From >= Text'First and then From <= Before and then Before - 1 <= Text'Last,
           Post => Find'Result in From .. Before and then (Find'Result = Before or else Text (Find'Result) = Symbol)
   is
      Position : Positive := From;
   begin
      while Position < Before and then Text (Position) /= Symbol loop
         pragma Loop_Invariant (Position in From .. Before - 1);
         pragma Loop_Variant (Increases => Position);
         Position := Position + 1;
      end loop;
      return Position;
   end Find;

   --  RFC 9110 tchar: what a method or a header name is made of.
   function Is_Token_Character (Symbol : Character) return Boolean is
     (Symbol in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
              | '!' | '#' | '$' | '%' | '&' | ''' | '*' | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~');

   function Is_Token (Text : String) return Boolean is
     (Text'Length > 0 and then (for all Symbol of Text => Is_Token_Character (Symbol)));

   --  What a request target may hold: visible ASCII (RFC 9112 3.2), so no blanks, controls or bytes >= 128.
   function Is_Target (Text : String) return Boolean is
     (Text'Length > 0 and then (for all Symbol of Text => Symbol in '!' .. '~'));

   --  A header value: visible characters, blanks and bytes >= 128 (obs-text); never a control character.
   function Is_Field_Value (Text : String) return Boolean is
     (for all Symbol of Text => Symbol = ASCII.HT or else (Symbol >= ' ' and then Symbol /= ASCII.DEL));

   --  Content-Length: digits only (else 400), at most Limit (else 413).
   type Length_Field (Valid : Boolean := False) is record
      case Valid is
         when True  => Value : Body_Size;
         when False => Status : Status_Code;
      end case;
   end record;

   function Body_Length_Of (Text : String; Limit : Body_Size) return Length_Field is
      Value : Body_Size := 0;
   begin
      if Text'Length = 0 or else (for some Symbol of Text => Symbol not in '0' .. '9') then
         return (Valid => False, Status => Bad_Request);
      end if;

      for Symbol of Text loop
         pragma Loop_Invariant (Value <= Limit);
         if Value > (Body_Size'Last - 9) / 10 then
            return (Valid => False, Status => Payload_Too_Large);
         end if;
         Value := Value * 10 + (Character'Pos (Symbol) - Character'Pos ('0'));
         if Value > Limit then
            return (Valid => False, Status => Payload_Too_Large);
         end if;
      end loop;
      return (Valid => True, Value => Value);
   end Body_Length_Of;

   function Verb_Of (Text : String) return Method is
     (if Text = "GET" then Get elsif Text = "HEAD" then Head elsif Text = "POST" then Post
      elsif Text = "PUT" then Put elsif Text = "PATCH" then Patch elsif Text = "DELETE" then Delete
      elsif Text = "OPTIONS" then Options else Other);

   function Invalid (Status : Status_Code) return Request_Head is (Outcome => Invalid, Status => Status);

   ----------------
   -- Parse_Head --
   ----------------

   function Parse_Head (Request : String; Within_Limits : Limits := Default_Limits) return Request_Head is
      Head_End     : Natural := 0;   --  the last byte of the blank line
      Line_End     : Positive;
      First_Space  : Positive;
      Second_Space : Positive;
      Question     : Positive;
      Query        : Span := (1, 0);
      Line_First   : Positive;
      Http_1_0     : Boolean;
      Has_Host     : Boolean := False;
      Has_Length   : Boolean := False;
      Wants_Alive  : Boolean := False;   --  HTTP/1.0 with Connection: keep-alive
      Result       : Request_Head (Complete);
      Search_Last  : constant Integer :=
        (if Request'Length > Within_Limits.Max_Head_Length then Request'First + Within_Limits.Max_Head_Length - 1
         else Request'Last);
   begin
      if Request'Length >= 4 and then Search_Last >= Request'First + 3 then
         for Position in Request'First .. Search_Last - 3 loop
            pragma Loop_Invariant (Head_End = 0);
            if Request (Position .. Position + 3) = CRLF & CRLF then
               Head_End := Position + 3;
               exit;
            end if;
         end loop;
      end if;

      if Head_End = 0 then
         return (if Request'Length >= Within_Limits.Max_Head_Length then Invalid (Header_Fields_Too_Large)
                 else (Outcome => Incomplete));
      end if;
      pragma Assert (Head_End in Request'First + 3 .. Request'Last);

      --  A bare LF anywhere in the head: a line break some other parser on the path may read differently.
      for Position in Request'First .. Head_End loop
         if Request (Position) = ASCII.LF
           and then (Position = Request'First or else Request (Position - 1) /= ASCII.CR)
         then
            return Invalid (Bad_Request);
         end if;
      end loop;

      --  request line: METHOD SP target SP version
      Line_End    := Find (Request, ASCII.CR, Request'First, Head_End);
      First_Space := Find (Request, ' ', Request'First, Line_End);
      if First_Space >= Line_End or else First_Space = Request'First then
         return Invalid (Bad_Request);
      end if;

      Second_Space := Find (Request, ' ', First_Space + 1, Line_End);
      if Second_Space >= Line_End or else Second_Space = First_Space + 1 then
         return Invalid (Bad_Request);
      end if;

      --  (slices rather than renamings: SPARK allows no renaming of a slice with variable bounds)
      if Request (Second_Space + 1 .. Line_End - 1) = "HTTP/1.1" then
         Http_1_0 := False;
      elsif Request (Second_Space + 1 .. Line_End - 1) = "HTTP/1.0" then
         Http_1_0 := True;
      else
         return Invalid (Bad_Request);
      end if;

      if not Is_Token (Request (Request'First .. First_Space - 1))
        or else not Is_Target (Request (First_Space + 1 .. Second_Space - 1))
        or else (Request (First_Space + 1) /= '/'
                 and then not (Request (First_Space + 1 .. Second_Space - 1) = "*"
                               and then Request (Request'First .. First_Space - 1) = "OPTIONS"))
      then
         return Invalid (Bad_Request);   --  absolute-form targets are for proxies
      end if;

      Question := Find (Request, '?', First_Space + 1, Second_Space);
      if Question < Second_Space then
         Query := (Question + 1, Second_Space - 1);
      end if;

      Result := (Outcome      => Complete,
                 Verb         => Verb_Of (Request (Request'First .. First_Space - 1)),
                 Verb_Text    => (Request'First, First_Space - 1),
                 Path         => (First_Space + 1, Question - 1),
                 Query        => Query,
                 Headers      => [others => (Name => (1, 0), Value => (1, 0))],
                 Header_Total => 0,
                 Head_Length  => Head_End - Request'First + 1,
                 Body_Length  => 0,
                 Chunked      => False,
                 Keep_Alive   => not Http_1_0);

      --  header lines, up to the blank one
      Line_First := Line_End + 2;
      while Line_First < Head_End - 1 loop
         pragma Loop_Invariant (Line_First > Request'First and then Consistent (Result, Request));
         pragma Loop_Variant (Increases => Line_First);

         declare
            Next_Line_End : constant Positive := Find (Request, ASCII.CR, Line_First, Head_End);
            Colon         : constant Positive := Find (Request, ':', Line_First, Next_Line_End);
            Value_First   : Positive;
            Value_Last    : Natural;
         begin
            --  No colon, or a name with a blank in it (also obs-fold continuation lines, which start with one).
            if Colon >= Next_Line_End or else not Is_Token (Request (Line_First .. Colon - 1)) then
               return Invalid (Bad_Request);
            end if;
            if Result.Header_Total = Max_Headers then
               return Invalid (Header_Fields_Too_Large);
            end if;

            Value_First := Colon + 1;
            Value_Last  := Next_Line_End - 1;
            while Value_First <= Value_Last and then Request (Value_First) in ' ' | ASCII.HT loop
               pragma Loop_Invariant (Value_First in Colon + 1 .. Value_Last);
               pragma Loop_Variant (Increases => Value_First);
               Value_First := Value_First + 1;
            end loop;
            while Value_Last >= Value_First and then Request (Value_Last) in ' ' | ASCII.HT loop
               pragma Loop_Invariant (Value_Last in Value_First .. Next_Line_End - 1);
               pragma Loop_Variant (Decreases => Value_Last);
               Value_Last := Value_Last - 1;
            end loop;

            --  The name is Request (Line_First .. Colon - 1), the value Request (Value_First .. Value_Last).
            begin
               if not Is_Field_Value (Request (Value_First .. Value_Last)) then
                  return Invalid (Bad_Request);
               end if;

               if Same_Name (Request (Line_First .. Colon - 1), "content-length") then
                  declare
                     Field : constant Length_Field :=
                       Body_Length_Of (Request (Value_First .. Value_Last),
                                       Body_Size'Max (Body_Size (Within_Limits.Max_Body_Length),
                                                      Within_Limits.Max_Streamed_Length));
                  begin
                     if not Field.Valid then
                        return Invalid (Field.Status);
                     elsif Result.Chunked then
                        return Invalid (Bad_Request);   --  a length and chunked: a smuggling attempt
                     elsif Has_Length and then Field.Value /= Result.Body_Length then
                        return Invalid (Bad_Request);   --  two lengths: a smuggling attempt
                     end if;
                     Has_Length         := True;
                     Result.Body_Length := Field.Value;
                  end;
               elsif Same_Name (Request (Line_First .. Colon - 1), "transfer-encoding") then
                  if not Same_Name (Request (Value_First .. Value_Last), "chunked") then
                     return Invalid (Not_Implemented);   --  gzip, deflate, or a list of codings
                  elsif Has_Length or else Result.Chunked then
                     return Invalid (Bad_Request);       --  with a length, or twice
                  end if;
                  Result.Chunked := True;
               elsif Same_Name (Request (Line_First .. Colon - 1), "host") then
                  if Has_Host then
                     return Invalid (Bad_Request);
                  end if;
                  Has_Host := True;
               elsif Same_Name (Request (Line_First .. Colon - 1), "connection") then
                  if Contains_Token (Request (Value_First .. Value_Last), "close") then
                     Result.Keep_Alive := False;
                     Wants_Alive       := False;
                  elsif Http_1_0 and then Contains_Token (Request (Value_First .. Value_Last), "keep-alive") then
                     Wants_Alive := True;
                  end if;
               end if;

               Result.Header_Total                  := Result.Header_Total + 1;
               Result.Headers (Result.Header_Total) := (Name  => (Line_First, Colon - 1),
                                                        Value => (Value_First, Value_Last));
            end;
            Line_First := Next_Line_End + 2;
         end;
      end loop;

      if not Has_Host and then not Http_1_0 then
         return Invalid (Bad_Request);   --  RFC 9112 3.2: an HTTP/1.1 request without Host
      end if;
      if Http_1_0 and then Wants_Alive then
         Result.Keep_Alive := True;
      end if;
      return Result;
   end Parse_Head;

   ------------------
   -- Header_Value --
   ------------------

   function Header_Value (Request : String; Head : Request_Head; Name : String) return Span is begin
      for Index in 1 .. Head.Header_Total loop
         declare
            Item : constant Header := Head.Headers (Index);
         begin
            if Length (Item.Name) = Name'Length
              and then Equal_Ignoring_Case (Slice (Request, Item.Name), Name)
            then
               return Item.Value;
            end if;
         end;
      end loop;
      return (1, 0);
   end Header_Value;

end Sparrow.Http.Parser;
