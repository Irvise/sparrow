--  Small text routines shared by the protocol code: the checked conversions between bytes and UTF8_String,
--  spans, decimal numbers, case-insensitive comparison and percent-decoding.

package Sparrow.Encoding with SPARK_Mode is

   --  A range of some text's bytes; First > Last when empty. Parsers return spans instead of copies.
   type Span is record
      First : Positive := 1;
      Last  : Natural := 0;
   end record;

   Empty : constant Span := (First => 1, Last => 0);

   function Length (Item : Span) return Natural is (if Item.Last < Item.First then 0 else Item.Last - Item.First + 1);

   --  Empty, or inside Source.
   function Within (Item : Span; Source : String) return Boolean is
     (Length (Item) = 0 or else (Item.First >= Source'First and then Item.Last <= Source'Last));

   --  The bytes of Source that Item covers; "" when Item is empty.
   function Slice (Source : String; Item : Span) return String
      with Pre  => Within (Item, Source),
           Post => Slice'Result'Length = Length (Item);

   ---------------------------------------------------------------------------------------------------------------
   --  bytes and text

   --  Well-formed UTF-8: no overlong forms, no surrogates, nothing past U+10FFFF, no sequence cut short.
   function Valid_Utf8 (Source : String) return Boolean;

   --  The one sound way from bytes to text: check Valid_Utf8 first.
   function To_UTF8 (Source : String) return UTF8_String
      with Pre  => Valid_Utf8 (Source),
           Post => String (To_UTF8'Result) = Source;

   function To_Bytes (Source : UTF8_String) return String
      with Post => To_Bytes'Result = String (Source);

   --  Text given as Unicode code points. This is the way to write a literal that is not plain ASCII and
   --  have it mean the same under every source encoding: To_UTF8 ("café") is at the mercy of the
   --  compiler's -gnatW switch (see the note on literals in Sparrow), From_Unicode ("café") is not. Code
   --  points that are not characters (surrogates, past U+10FFFF) become U+FFFD.
   function From_Unicode (Source : Wide_Wide_String) return UTF8_String
      with Pre  => Source'Length <= Natural'Last / 4,
           Post => From_Unicode'Result'Length <= 4 * Source'Length;

   --  Text in Ada's own encoding (Latin-1: what 'Image and Ada.Text_IO deal in) as UTF-8, and back. Characters
   --  past U+00FF have no Latin-1 form: Valid is False then, and when Into is too short.
   function Encode_Latin_1 (Source : String) return UTF8_String
      with Pre  => Source'Length <= Natural'Last / 2,
           Post => Encode_Latin_1'Result'Length in Source'Length .. 2 * Source'Length;

   procedure Decode_Latin_1 (Source : UTF8_String; Into : out String; Last : out Natural; Valid : out Boolean)
      with Pre  => Into'First >= 1,
           Post => Last = Into'First - 1 or else Last in Into'Range;

   ---------------------------------------------------------------------------------------------------------------
   --  numbers

   --  Decimal digits, with a leading '-' when negative.
   function Decimal_Image (Value : Long_Long_Integer) return String
      with Post => Decimal_Image'Result'First = 1 and then Decimal_Image'Result'Length in 1 .. 20;

   --  An optional '-' then digits, nothing else. Valid is False (and Value 0) for anything else or on overflow.
   procedure Parse_Decimal (Source : String; Value : out Long_Long_Integer; Valid : out Boolean)
      with Post => (if not Valid then Value = 0);

   ---------------------------------------------------------------------------------------------------------------
   --  comparison

   --  Equality with ASCII letters compared without case (header names, schemes).
   function Equal_Ignoring_Case (Left, Right : String) return Boolean;

   ---------------------------------------------------------------------------------------------------------------
   --  percent-encoding (RFC 3986), for request targets, query strings and form bodies

   --  Into (Into'First .. Last) receives Source with every %XX resolved; '+' becomes a space when Plus_Is_Space
   --  (query strings and forms). Valid is False on a broken escape or when Into is too short; the decoded text
   --  is never longer than Source.
   procedure Percent_Decode
     (Source        : String;
      Into          : out String;
      Last          : out Natural;
      Valid         : out Boolean;
      Plus_Is_Space : Boolean := False)
      with Pre  => Into'First >= 1,
           Post => Last = Into'First - 1 or else Last in Into'Range;

   --  The value of Name in a query string or form body (a=1&b=2), still encoded; Empty when absent. Names are
   --  compared as written (not decoded).
   function Query_Value (Query : String; Name : String) return Span
      with Post => Within (Query_Value'Result, Query);

end Sparrow.Encoding;
