with Ada.Containers.Generic_Array_Sort;
with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Sparrow.Crypto.Hashes;
with Sparrow.Crypto.Macs;
with Sparrow.Crypto;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Sparrow.S3.Signatures is

   use Sparrow.Crypto;

   function Uri_Encode (Text : String; Keep_Slash : Boolean := False) return String is
      Digits_Of : constant String := "0123456789ABCDEF";
      Result    : Unbounded_String;
   begin
      for Item of Text loop
         if Item in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~'
           or else (Keep_Slash and then Item = '/')
         then
            Append (Result, Item);
         else
            Append (Result, '%');
            Append (Result, Digits_Of (Character'Pos (Item) / 16 + 1));
            Append (Result, Digits_Of (Character'Pos (Item) mod 16 + 1));
         end if;
      end loop;
      return To_String (Result);
   end Uri_Encode;

   function Amz_Date (Time : Times.Unix_Seconds) return String is
      Text : constant Times.Rfc3339_Text := Times.Rfc3339 (Times.To_Microseconds (Time));   --  2013-05-24T00:00:00.000Z
   begin
      return Text (1 .. 4) & Text (6 .. 7) & Text (9 .. 10) & "T" & Text (12 .. 13) & Text (15 .. 16)
             & Text (18 .. 19) & "Z";
   end Amz_Date;

   function Payload_Hash (Content : String) return String is
     (To_Hex (Hashes.Hash (Sha256, Content)));

   type Text_Array is array (Positive range <>) of Unbounded_String;
   procedure Sort is new Ada.Containers.Generic_Array_Sort (Positive, Unbounded_String, Text_Array);

   --  The pieces of Text between Separator.
   function Split (Text : String; Separator : Character) return Text_Array is
      Count : constant Natural := Ada.Strings.Fixed.Count (Text, [1 => Separator]) + 1;
      Parts : Text_Array (1 .. Count);
      First : Positive := Text'First;
      Index : Positive := 1;
   begin
      for Position in Text'Range loop
         if Text (Position) = Separator then
            Parts (Index) := To_Unbounded_String (Text (First .. Position - 1));
            Index := Index + 1;
            First := Position + 1;
         end if;
      end loop;
      Parts (Index) := To_Unbounded_String (Text (First .. Text'Last));
      return Parts;
   end Split;

   --  "name:value" lines, each name lower case and each value trimmed, sorted; empty lines dropped.
   function Canonical_Headers (Headers : String) return Text_Array is
      Lines  : constant Text_Array := Split (Headers, ASCII.LF);
      Result : Text_Array (1 .. Lines'Length);
      Last   : Natural := 0;
   begin
      for Line of Lines loop
         declare
            Text  : constant String := To_String (Line);
            Colon : constant Natural := Ada.Strings.Fixed.Index (Text, ":");
         begin
            if Colon > 0 then
               Last := Last + 1;
               Result (Last) := To_Unbounded_String
                 (Ada.Characters.Handling.To_Lower (Ada.Strings.Fixed.Trim (Text (Text'First .. Colon - 1),
                                                                            Ada.Strings.Both))
                  & ":" & Ada.Strings.Fixed.Trim (Text (Colon + 1 .. Text'Last), Ada.Strings.Both));
            end if;
         end;
      end loop;
      Sort (Result (1 .. Last));
      return Result (1 .. Last);
   end Canonical_Headers;

   function Signed_Headers (Headers : String) return String is
      Result : Unbounded_String;
   begin
      for Line of Canonical_Headers (Headers) loop
         if Length (Result) > 0 then
            Append (Result, ';');
         end if;
         Append (Result, Head (Line, Index (Line, ":") - 1));
      end loop;
      return To_String (Result);
   end Signed_Headers;

   function Canonical_Request
     (Method       : String;
      Path         : String;
      Query        : String;
      Headers      : String;
      Payload_Hash : String) return String
   is
      Result : Unbounded_String := To_Unbounded_String (Method & ASCII.LF & Path & ASCII.LF);
   begin
      if Query /= "" then
         declare
            Pairs : Text_Array := Split (Query, '&');
         begin
            for Index in Pairs'Range loop   --  "name" alone is "name="
               if Ada.Strings.Unbounded.Index (Pairs (Index), "=") = 0 then
                  Append (Pairs (Index), '=');
               end if;
            end loop;
            Sort (Pairs);
            for Index in Pairs'Range loop
               if Index > Pairs'First then
                  Append (Result, '&');
               end if;
               Append (Result, Pairs (Index));
            end loop;
         end;
      end if;
      Append (Result, ASCII.LF);
      for Line of Canonical_Headers (Headers) loop
         Append (Result, Line);
         Append (Result, ASCII.LF);
      end loop;
      Append (Result, ASCII.LF & Signed_Headers (Headers) & ASCII.LF & Payload_Hash);
      return To_String (Result);
   end Canonical_Request;

   function Scope (Stamp : String; Region : String; Service : String) return String is
     (Stamp (Stamp'First .. Stamp'First + 7) & "/" & Region & "/" & Service & "/aws4_request");

   function Signature
     (Secret_Key : String;
      Region     : String;
      Service    : String;
      Stamp      : String;
      Canonical  : String) return String
   is
      Day          : constant String := Stamp (Stamp'First .. Stamp'First + 7);
      Day_Key      : constant String := Macs.Hmac (Sha256, "AWS4" & Secret_Key, Day);
      Region_Key   : constant String := Macs.Hmac (Sha256, Day_Key, Region);
      Service_Key  : constant String := Macs.Hmac (Sha256, Region_Key, Service);
      Signing_Key  : constant String := Macs.Hmac (Sha256, Service_Key, "aws4_request");
      To_Sign      : constant String :=
        "AWS4-HMAC-SHA256" & ASCII.LF & Stamp & ASCII.LF & Scope (Stamp, Region, Service) & ASCII.LF
        & Payload_Hash (Canonical);
   begin
      return To_Hex (Macs.Hmac (Sha256, Signing_Key, To_Sign));
   end Signature;

end Sparrow.S3.Signatures;
