--  Reading a session's sealed text: the issued time (Unix seconds) and a line break, the CSRF token, then each
--  name and value as "length:bytes". Sparrow.Http.Sessions writes it, seals it into a cookie or keeps it in a
--  table, and reads it back here. A cookie's text is authenticated before it comes here, but a table's is only
--  as trusted as the table, so malformed text is reported, never assumed away.
--
--  SPARK: no run-time errors, and every span returned lies inside the text.
with Sparrow.Encoding; use Sparrow.Encoding;

package Sparrow.Http.Session_Envelope with SPARK_Mode is

   Token_Length : constant := 24;

   --  The largest index the reader accepts, leaving room to step past the end.
   Max_Index : constant := Positive'Last - Token_Length - 2;

   --  The issued time and the token; Next is where the fields start.
   procedure Read_Head
     (Text   : String;
      Issued : out Long_Long_Integer;
      Token  : out Span;
      Next   : out Positive;
      Valid  : out Boolean)
      with Pre  => Text'First >= 1 and then Text'Last <= Max_Index,
           Post => (if Valid then Issued >= 0 and then Within (Token, Text) and then Length (Token) = Token_Length
                                  and then Next in Text'First .. Text'Last + 1);

   --  The "length:bytes" field at Position, and Position past it.
   procedure Read_Field (Text : String; Position : in out Positive; Field : out Span; Valid : out Boolean)
      with Pre  => Text'Last <= Max_Index and then Position in Text'First .. Text'Last,
           Post => (if Valid then Within (Field, Text) and then Position > Position'Old
                                  and then Position <= Text'Last + 1);

end Sparrow.Http.Session_Envelope;
