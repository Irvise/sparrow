package body Sparrow.Http.Multipart_Scanning with SPARK_Mode is

   CRLF : constant String := ASCII.CR & ASCII.LF;

   function Find (Text, Pattern : String) return Natural is
   begin
      if Text'Length < Pattern'Length then
         return 0;
      end if;
      for Start in Text'First .. Text'Last - Pattern'Length + 1 loop
         if Text (Start) = Pattern (Pattern'First)
           and then Text (Start .. Start + Pattern'Length - 1) = Pattern
         then
            return Start;
         end if;
      end loop;
      return 0;
   end Find;

   function Lower (Item : Character) return Character is
     (if Item in 'A' .. 'Z' then Character'Val (Character'Pos (Item) + 32) else Item);

   --  Text equals Key (lower case) without regard to case.
   function Same_Folded (Text, Key : String) return Boolean is
     (Text'Length = Key'Length
      and then (for all Offset in 0 .. Text'Length - 1 =>
                  Lower (Text (Text'First + Offset)) = Key (Key'First + Offset)));

   --  Text (First .. Last) without spaces at either end.
   function Trimmed (Text : String; First : Positive; Last : Natural) return Span
      with Pre  => Text'Last <= Max_Index
                   and then (if First <= Last then First >= Text'First and then Last <= Text'Last),
           Post => Within (Trimmed'Result, Text)
   is
      Low  : Positive := First;
      High : Natural := Last;
   begin
      while Low <= High and then Text (Low) = ' ' loop
         pragma Loop_Invariant (Low in First .. High and then High = Last);
         pragma Loop_Variant (Increases => Low);
         Low := Low + 1;
      end loop;
      while High >= Low and then Text (High) = ' ' loop
         pragma Loop_Invariant (High in Low .. Last and then Low >= First);
         pragma Loop_Variant (Decreases => High);
         High := High - 1;
      end loop;
      return (First => Low, Last => High);
   end Trimmed;

   function Parameter (Value, Key : String) return Span is
      Position : Positive;
   begin
      if Value'Length = 0 then
         return Empty;
      end if;
      Position := Value'First;
      while Position <= Value'Last loop
         pragma Loop_Invariant (Position >= Value'First);
         pragma Loop_Variant (Increases => Position);
         declare
            Semicolon : constant Natural := Find (Value (Position .. Value'Last), ";");
            First     : Positive;
            Equals    : Natural;
         begin
            exit when Semicolon = 0;
            First := Semicolon + 1;
            while First <= Value'Last and then Value (First) = ' ' loop
               pragma Loop_Invariant (First in Semicolon + 1 .. Value'Last);
               pragma Loop_Variant (Increases => First);
               First := First + 1;
            end loop;
            Equals := Find (Value (First .. Value'Last), "=");
            exit when Equals = 0;
            declare
               Name : constant Span := Trimmed (Value, First, Equals - 1);
            begin
               if Same_Folded (Value (Name.First .. Name.Last), Key) then
                  if Equals < Value'Last and then Value (Equals + 1) = '"' then
                     declare
                        Closing : constant Natural := Find (Value (Equals + 2 .. Value'Last), """");
                     begin
                        return (if Closing = 0 then Empty else (First => Equals + 2, Last => Closing - 1));
                     end;
                  else
                     declare
                        Next : constant Natural := Find (Value (Equals + 1 .. Value'Last), ";");
                     begin
                        return Trimmed (Value, Equals + 1, (if Next = 0 then Value'Last else Next - 1));
                     end;
                  end if;
               end if;
            end;
            Position := Equals + 1;
         end;
      end loop;
      return Empty;
   end Parameter;

   --  The last path segment of the file name at Item.
   function Base_Name (Text : String; Item : Span) return Span
      with Pre  => Text'Last <= Max_Index and then Within (Item, Text),
           Post => Within (Base_Name'Result, Text)
   is
   begin
      for Index in reverse Item.First .. Item.Last loop
         if Text (Index) in '/' | '\' then
            return (First => Index + 1, Last => Item.Last);
         end if;
      end loop;
      return Item;
   end Base_Name;

   function Read_Head (Head : String) return Part_Head is
      Disposition     : Span := Empty;
      Has_Disposition : Boolean := False;
      Result          : Part_Head;
      Line_Start      : Positive;
   begin
      if Head'Length = 0 then
         return Result;
      end if;
      Line_Start := Head'First;
      while Line_Start <= Head'Last loop
         pragma Loop_Invariant (Line_Start >= Head'First and then Within (Disposition, Head)
                                and then Within (Result.Kind, Head)
                                and then Result.Name = Empty and then Result.File_Name = Empty);
         pragma Loop_Variant (Increases => Line_Start);
         declare
            Break    : constant Natural := Find (Head (Line_Start .. Head'Last), CRLF);
            Line_End : constant Positive := (if Break = 0 then Head'Last + 1 else Break);
            Colon    : constant Natural := Find (Head (Line_Start .. Line_End - 1), ":");
         begin
            if Colon > 0 then
               if Same_Folded (Head (Line_Start .. Colon - 1), "content-disposition") then
                  Disposition     := Trimmed (Head, Colon + 1, Line_End - 1);
                  Has_Disposition := True;
               elsif Same_Folded (Head (Line_Start .. Colon - 1), "content-type") then
                  Result.Kind := Trimmed (Head, Colon + 1, Line_End - 1);
               end if;
            end if;
            Line_Start := Line_End + 2;
         end;
      end loop;
      if Has_Disposition and then Disposition.First <= Disposition.Last then
         Result.Name      := Parameter (Head (Disposition.First .. Disposition.Last), "name");
         Result.File_Name :=
           Base_Name (Head, Parameter (Head (Disposition.First .. Disposition.Last), "filename"));
      end if;
      return Result;
   end Read_Head;

   function Next_Part (Data, Marker : String; Position : Positive) return Step is
      Place        : Positive := Position + Marker'Length;
      Content_From : Positive;
      Head         : Span;
   begin
      if Place < Data'Last and then Data (Place .. Place + 1) = "--" then
         return (Kind => Closed, others => <>);
      end if;
      --  Transport padding, then CRLF.
      while Place <= Data'Last and then Data (Place) in ' ' | ASCII.HT loop
         pragma Loop_Invariant (Place in Position + Marker'Length .. Data'Last);
         pragma Loop_Variant (Increases => Place);
         Place := Place + 1;
      end loop;
      if Place >= Data'Last or else Data (Place .. Place + 1) /= CRLF then
         return (Kind => Malformed, others => <>);
      end if;
      Place := Place + 2;
      if Place < Data'Last and then Data (Place .. Place + 1) = CRLF then
         Content_From := Place + 2;   --  no header lines
         Head         := (First => Place, Last => Place - 1);
      else
         declare
            Head_End : constant Natural := Find (Data (Place .. Data'Last), CRLF & CRLF);
         begin
            if Head_End = 0 then
               return (Kind => Malformed, others => <>);
            end if;
            Content_From := Head_End + 4;
            Head         := (First => Place, Last => Head_End - 1);
         end;
      end if;
      declare
         Content_End : constant Natural := Find (Data (Content_From .. Data'Last), CRLF & Marker);
      begin
         if Content_End = 0 then
            return (Kind => Malformed, others => <>);
         end if;
         return (Kind    => Part_Found,
                 Head    => Head,
                 Content => (First => Content_From, Last => Content_End - 1),
                 Next    => Content_End + 2);
      end;
   end Next_Part;

end Sparrow.Http.Multipart_Scanning;
