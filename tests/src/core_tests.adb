with Ada.Exceptions;
with Checks; use Checks;
with Interfaces; use Interfaces;
with Sparrow.Base64;
with Sparrow.Deflate;
with Sparrow.Gzip;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Encoding; use Sparrow.Encoding;
with Sparrow.Times; use Sparrow.Times;
with Zlib_Check;

procedure Core_Tests is
   use Sparrow;
   Bytes : Buffer;
   Value : Long_Long_Integer;
   Valid : Boolean;
   Last  : Natural;
   Into  : String (1 .. 64);
   Time  : Unix_Microseconds;
begin
   --  buffers
   Append (Bytes, "abc");
   Append (Bytes, '-');
   Append_Integer (Bytes, -42);
   Append_Text (Bytes, " é");
   Equal (Content (Bytes), "abc--42 é", "buffer appends");
   Consume (Bytes, 4);
   Equal (Content (Bytes), "-42 é", "buffer consume");
   Clear (Bytes);
   Append_Big_Endian (Bytes, Interfaces.Unsigned_32'(16#01020304#));
   Check (Content (Bytes) = [Character'Val (1), Character'Val (2), Character'Val (3), Character'Val (4)], "big endian");
   for Count in 1 .. 10_000 loop
      Append (Bytes, "0123456789");
   end loop;
   Check (Bytes.Length = 100_004 and then not Bytes.Overflowed, "buffer growth");
   Free (Bytes);

   --  numbers
   Equal (Decimal_Image (0), "0", "image 0");
   Equal (Decimal_Image (Long_Long_Integer'First), "-9223372036854775808", "image min");
   Equal (Decimal_Image (Long_Long_Integer'Last), "9223372036854775807", "image max");
   Parse_Decimal ("-9223372036854775808", Value, Valid);
   Check (Valid and then Value = Long_Long_Integer'First, "parse min");
   Parse_Decimal ("9223372036854775808", Value, Valid);
   Check (not Valid, "parse overflow");
   Parse_Decimal ("12a", Value, Valid);
   Check (not Valid, "parse junk");
   Parse_Decimal ("", Value, Valid);
   Check (not Valid, "parse empty");
   Parse_Decimal ("-", Value, Valid);
   Check (not Valid, "parse lone minus");
   Parse_Decimal ("007", Value, Valid);
   Check (Valid and then Value = 7, "parse leading zeros");

   --  UTF-8
   Check (Valid_Utf8 (""), "utf8 empty");
   Check (Valid_Utf8 ("héllo €𝄞"), "utf8 valid");
   Check (not Valid_Utf8 ([Character'Val (16#C0#), Character'Val (16#80#)]), "utf8 overlong");
   Check (not Valid_Utf8 ([Character'Val (16#ED#), Character'Val (16#A0#), Character'Val (16#80#)]), "utf8 surrogate");
   Check (not Valid_Utf8 ([Character'Val (16#E2#), Character'Val (16#82#)]), "utf8 cut short");
   Check (not Valid_Utf8 ([1 => Character'Val (16#FF#)]), "utf8 bad lead");
   Check (not Valid_Utf8 ([Character'Val (16#F4#), Character'Val (16#90#), Character'Val (16#80#),
                           Character'Val (16#80#)]), "utf8 past U+10FFFF");
   Check (To_Bytes (To_UTF8 ("abc")) = "abc", "to_utf8 round trip");
   Check (String (From_Unicode ([Wide_Wide_Character'Val (16#E9#), Wide_Wide_Character'Val (16#20AC#),
                                 Wide_Wide_Character'Val (16#1D11E#)])) = "é€𝄞", "from_unicode");
   Check (String (Encode_Latin_1 ([1 => Character'Val (16#E9#)])) = "é", "latin-1 encode");
   Decode_Latin_1 ("né", Into, Last, Valid);
   Check (Valid and then Into (1 .. Last) = ['n', Character'Val (16#E9#)], "latin-1 decode");
   Decode_Latin_1 ("€", Into, Last, Valid);
   Check (not Valid, "latin-1 decode out of range");

   --  misc text
   Check (Equal_Ignoring_Case ("Content-Length", "content-length"), "case-insensitive equal");
   Check (not Equal_Ignoring_Case ("a", "ab"), "case-insensitive length");
   Percent_Decode ("a%20b+c%2F", Into, Last, Valid, Plus_Is_Space => True);
   Check (Valid and then Into (1 .. Last) = "a b c/", "percent decode");
   Percent_Decode ("a%2", Into, Last, Valid);
   Check (not Valid, "percent decode cut short");
   Percent_Decode ("%zz", Into, Last, Valid);
   Check (not Valid, "percent decode bad hex");
   declare
      Query : constant String := "a=1&bb=two&c&d=";
   begin
      Equal (Slice (Query, Query_Value (Query, "a")), "1", "query first");
      Equal (Slice (Query, Query_Value (Query, "bb")), "two", "query middle");
      Equal (Slice (Query, Query_Value (Query, "d")), "", "query empty value");
      Equal (Slice (Query, Query_Value (Query, "zz")), "", "query absent");
      Check (Query_Value (Query, "c").First = 12, "query flag present");
      Check (Query_Value (Query, "b") = Empty, "query prefix is not a match");
   end;

   --  times
   Equal (Rfc3339 (0), "1970-01-01T00:00:00.000Z", "rfc3339 epoch");
   Equal (Rfc3339 (1_743_508_800_123_456), "2025-04-01T12:00:00.123Z", "rfc3339 2025");
   Equal (Rfc3339 (-1), "1969-12-31T23:59:59.999Z", "rfc3339 before epoch");
   Equal (Rfc3339 (951_782_400_000_000), "2000-02-29T00:00:00.000Z", "rfc3339 leap day");
   Equal (Http_Date (784_111_777), "Sun, 06 Nov 1994 08:49:37 GMT", "http date");
   Equal (Http_Date (0), "Thu, 01 Jan 1970 00:00:00 GMT", "http date epoch");
   Parse_Rfc3339 ("2025-04-01T12:00:00.123Z", Time, Valid);
   Check (Valid and then Time = 1_743_508_800_123_000, "parse rfc3339");
   Parse_Rfc3339 ("2025-04-01T14:00:00+02:00", Time, Valid);
   Check (Valid and then Time = 1_743_508_800_000_000, "parse rfc3339 offset");
   Parse_Rfc3339 ("2025-02-30T00:00:00Z", Time, Valid);
   Check (not Valid, "parse rfc3339 bad day");
   Parse_Rfc3339 ("2025-04-01T12:00:00", Time, Valid);
   Check (not Valid, "parse rfc3339 no zone");
   Check (To_Seconds (-1) = -1 and then To_Seconds (1_999_999) = 1, "to_seconds floors");

   --  base64
   Equal (Base64.Encode ("foobar"), "Zm9vYmFy", "base64 encode");
   Equal (Base64.Encode ("fo"), "Zm8=", "base64 pad");
   Equal (Base64.Encode ("fo", Base64.Url_Safe), "Zm8", "base64url no pad");
   Base64.Decode ("Zm9vYg==", Into, Last, Valid);
   Check (Valid and then Into (1 .. Last) = "foob", "base64 decode");
   Base64.Decode ("Zm9v!A==", Into, Last, Valid);
   Check (not Valid, "base64 decode bad character");

   --  gzip: every output read back by zlib
   declare
      type State_Access is access Sparrow.Deflate.State;
      Work : constant State_Access := new Sparrow.Deflate.State;
      Seed : Unsigned_32 := 12345;

      function Random_Bytes (Count : Natural; Alphabet : Positive := 256) return String is
         Result : String (1 .. Count);
      begin
         for Item of Result loop
            Seed := Seed * 1_103_515_245 + 12_345;
            Item := Character'Val (Natural (Shift_Right (Seed, 16)) mod Alphabet);
         end loop;
         return Result;
      end Random_Bytes;

      function Log_Text (Lines : Positive) return String is
         Text : Buffer;
      begin
         for Line in 1 .. Lines loop
            Append (Text, "2026-11-18T06:00:00Z INFO request method=GET path=/api/notes/");
            Append_Integer (Text, Long_Long_Integer (Line * 7 mod 1000));
            Append (Text, " status=200 bytes=");
            Append_Integer (Text, Long_Long_Integer (Line * 131 mod 9973));
            Append (Text, ASCII.LF);
         end loop;
         return Result : constant String := Content (Text) do
            Free (Text);
         end return;
      end Log_Text;

      --  Compressed with room to spare, then inflated: Ratio returns the size compressed over the size given.
      procedure Round_Trip (Input : String; Name : String; Padding : Natural := 0; Ratio : access Float := null) is
         Output : String_Access := new String (1 .. Input'Length + Input'Length / 50 + 64 + Padding);
         Last   : Natural;
         Fits   : Boolean;
      begin
         Sparrow.Gzip.Compress (Work.all, Input, Output.all, Last, Fits, Padding);
         Check (Fits and then Zlib_Check.Inflated (Output (1 .. Last)) = Input, "gzip round trip: " & Name);
         if Ratio /= null then
            Ratio.all := Float (Last) / Float (Input'Length);
         end if;
         Free (Output);
      exception
         when Problem : others =>
            Check (False, "gzip round trip: " & Name & ": " & Ada.Exceptions.Exception_Message (Problem));
      end Round_Trip;

      Random : constant String := Random_Bytes (40_000);
      Ratio  : aliased Float := 1.0;
   begin
      Check (Sparrow.Gzip.Crc_32 ("123456789") = 16#CBF4_3926#, "CRC-32 check value");
      Check (Sparrow.Gzip.Crc_32 ("6789", Sparrow.Gzip.Crc_32 ("12345")) = 16#CBF4_3926#, "CRC-32 continued");
      Round_Trip ("", "empty");
      Round_Trip ("a", "one byte");
      Round_Trip ("abc", "three bytes");
      Round_Trip ([1 .. 100_000 => 'a'], "one byte repeated", Ratio => Ratio'Access);
      Check (Ratio < 0.01, "a run shrinks to almost nothing");
      Round_Trip (Log_Text (20_000), "log lines (many blocks)", Ratio => Ratio'Access);
      Check (Ratio < 0.15, "log lines shrink below 15%");
      Round_Trip (Random_Bytes (300_000), "random bytes (stored blocks)", Ratio => Ratio'Access);
      Check (Ratio < 1.01, "random bytes grow by under 1%");
      Round_Trip (Random_Bytes (200_000, Alphabet => 4), "four letters: short matches everywhere");
      Round_Trip (Random & Random, "a repeat past the window");
      Round_Trip (Random (1 .. 32_767) & Random (1 .. 300), "a match at the window's far edge");
      Round_Trip (Random (1 .. 1000) & [1 .. 70_000 => 'x'] & Random (1 .. 1000), "mixed, a long stored stretch");
      Round_Trip (Log_Text (100), "padded", Padding => 32);
      declare
         Input  : constant String := Random_Bytes (10_000);
         Output : String (1 .. 9_000);
         Last   : Natural;
         Fits   : Boolean;
      begin
         Sparrow.Gzip.Compress (Work.all, Input, Output, Last, Fits);
         Check (not Fits and then Last = 0, "gzip: what does not fit says so");
      end;
   end;

   Finish ("core");
end Core_Tests;
