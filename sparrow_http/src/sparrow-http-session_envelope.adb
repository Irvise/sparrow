package body Sparrow.Http.Session_Envelope with SPARK_Mode is

   procedure Read_Head
     (Text   : String;
      Issued : out Long_Long_Integer;
      Token  : out Span;
      Next   : out Positive;
      Valid  : out Boolean)
   is
      Line_End : Natural := 0;
   begin
      Issued := 0;
      Token  := Empty;
      Next   := Text'First;
      Valid  := False;
      for Index in Text'Range loop
         if Text (Index) = ASCII.LF then
            Line_End := Index;
            exit;
         end if;
      end loop;
      if Line_End = 0 or else Text'Last - Line_End < Token_Length then
         return;
      end if;
      Parse_Decimal (Text (Text'First .. Line_End - 1), Issued, Valid);
      if not Valid or else Issued < 0 then
         Issued := 0;
         Valid  := False;
         return;
      end if;
      Token := (First => Line_End + 1, Last => Line_End + Token_Length);
      Next  := Line_End + Token_Length + 1;
   end Read_Head;

   procedure Read_Field (Text : String; Position : in out Positive; Field : out Span; Valid : out Boolean) is
      Place  : Positive := Position;
      Length : Long_Long_Integer := 0;
   begin
      Field := Empty;
      Valid := False;
      while Place <= Text'Last and then Text (Place) in '0' .. '9' loop
         pragma Loop_Invariant (Place in Position .. Text'Last and then Length in 0 .. Long_Long_Integer (Text'Length));
         pragma Loop_Variant (Increases => Place);
         Length := Length * 10 + Long_Long_Integer (Character'Pos (Text (Place)) - Character'Pos ('0'));
         if Length > Long_Long_Integer (Text'Length) then
            return;
         end if;
         Place := Place + 1;
      end loop;
      if Place = Position or else Place > Text'Last or else Text (Place) /= ':'
        or else Length > Long_Long_Integer (Text'Last - Place)
      then
         return;
      end if;
      Field    := (First => Place + 1, Last => Place + Natural (Length));
      Position := Place + Natural (Length) + 1;
      Valid    := True;
   end Read_Field;

end Sparrow.Http.Session_Envelope;
