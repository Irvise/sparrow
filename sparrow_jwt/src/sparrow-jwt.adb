with Sparrow.Base64; use Sparrow.Base64;
with Sparrow.Buffers;
with Sparrow.Json.Writers;
with Sparrow.Encoding;

package body Sparrow.Jwt with SPARK_Mode is

   use Sparrow.Json;

   Encoded_Header : constant String := Encode ("{""alg"":""HS256"",""typ"":""JWT""}", Url_Safe);

   ------------
   -- To_Key --
   ------------

   function To_Key (Secret : String) return Key is (Mac => Crypto.Macs.To_Hmac_Key (Crypto.Sha256, Secret));

   ----------
   -- Sign --
   ----------

   function Sign (Using : Key; Claims : UTF8_String) return String is
      Signed : constant String := Encoded_Header & "." & Encode (String (Claims), Url_Safe);
      Result : constant String := Signed & "." & Encode (Crypto.Macs.Hmac (Using.Mac, Signed), Url_Safe);
      subtype From_One is String (1 .. Result'Length);
   begin
      return From_One (Result);
   end Sign;

   ------------------
   -- Sign_Subject --
   ------------------

   function Sign_Subject
     (Using : Key; Subject : UTF8_String; Now : Unix_Seconds; Lifetime : Unix_Seconds) return String
   is
      use Sparrow.Buffers;
      Quoted       : Buffer;
      Subject_Text : constant UTF8_String (1 .. Subject'Length) := Subject;
   begin
      Sparrow.Json.Writers.Append_String (Quoted, Subject_Text);
      declare
         --  Sound: a JSON string literal made from text, and ASCII around it.
         Claims : constant UTF8_String := UTF8_String
           ("{""sub"":" & Content (Quoted)
            & ",""iat"":" & Encoding.Decimal_Image (Long_Long_Integer (Now))
            & ",""exp"":" & Encoding.Decimal_Image (Long_Long_Integer (Now) + Long_Long_Integer (Lifetime)) & "}");
      begin
         pragma Warnings (GNATprove, Off, "statement has no effect", Reason => "Free releases the storage");
         pragma Warnings (GNATprove, Off, """Quoted"" is set by*", Reason => "Free releases the storage");
         Free (Quoted);
         pragma Warnings (GNATprove, On, """Quoted"" is set by*");
         pragma Warnings (GNATprove, On, "statement has no effect");
         return Sign (Using, Claims);
      end;
   end Sign_Subject;

   --  A JSON number as whole seconds, rounded down; magnitudes above Limit saturate.
   type Seconds_Claim (Valid : Boolean := False) is record
      case Valid is
         when True  => Seconds : Unix_Seconds;
         when False => null;
      end case;
   end record;

   Limit : constant := 10 ** 15;

   ----------------
   -- Seconds_Of --
   ----------------

   function Seconds_Of (Text : String) return Seconds_Claim is
      Precision   : constant := 10 ** 17; --  significant digits kept: below this, one more fits
      Max_Scale   : constant := 100_000;  --  far beyond what can change a saturated or zero result
      Position    : Natural := 0;         --  offset of the next character
      Negative    : Boolean := False;
      Significand : Long_Long_Integer := 0;
      Scale       : Integer range -2 * Max_Scale .. 2 * Max_Scale := 0; --  value = significand * 10 ** scale
      Exponent    : Natural := 0;
      Inexact     : Boolean := False;     --  a non-zero digit was dropped
      Seen        : Boolean := False;
      Magnitude   : Long_Long_Integer;

      -------------
      -- Next_Is --
      -------------

      function Next_Is (Symbols : String) return Boolean is
        (Position < Text'Length and then (for some Symbol of Symbols => Text (Text'First + Position) = Symbol));

      -----------
      -- Digit --
      -----------

      function Digit return Natural is (Character'Pos (Text (Text'First + Position)) - Character'Pos ('0'))
         with Pre => Position < Text'Length and then Text (Text'First + Position) in '0' .. '9';

      --------------
      -- Is_Digit --
      --------------

      function Is_Digit return Boolean is (Position < Text'Length and then Text (Text'First + Position) in '0' .. '9');
   begin
      if Next_Is ("-") then
         Negative := True;
         Position := Position + 1;
      end if;

      while Is_Digit loop   --  whole part
         pragma Loop_Invariant (Significand in 0 .. Precision * 10 - 1 and then Scale in 0 .. Max_Scale);
         pragma Loop_Variant (Increases => Position);
         Seen := True;
         if Significand < Precision then
            Significand := Significand * 10 + Long_Long_Integer (Digit);
         else
            Scale   := Integer'Min (Scale + 1, Max_Scale);
            Inexact := Inexact or else Digit /= 0;
         end if;
         Position := Position + 1;
      end loop;

      if not Seen then
         return (Valid => False);
      end if;

      if Next_Is (".") then   --  fraction
         Position := Position + 1;
         if not Is_Digit then
            return (Valid => False);
         end if;
         while Is_Digit loop
            pragma Loop_Invariant (Significand in 0 .. Precision * 10 - 1 and then Scale in -Max_Scale .. Max_Scale);
            pragma Loop_Variant (Increases => Position);
            if Significand < Precision and then Scale > -Max_Scale then
               Significand := Significand * 10 + Long_Long_Integer (Digit);
               Scale       := Scale - 1;
            else
               Inexact := Inexact or else Digit /= 0;
            end if;
            Position := Position + 1;
         end loop;
      end if;

      if Next_Is ("eE") then   --  exponent
         Position := Position + 1;
         declare
            Below : constant Boolean := Next_Is ("-");
         begin
            if Below or else Next_Is ("+") then
               Position := Position + 1;
            end if;
            if not Is_Digit then
               return (Valid => False);
            end if;
            while Is_Digit loop
               pragma Loop_Invariant (Exponent <= Max_Scale and then Scale in -Max_Scale .. Max_Scale);
               pragma Loop_Variant (Increases => Position);
               Exponent := Integer'Min (Exponent * 10 + Digit, Max_Scale);
               Position := Position + 1;
            end loop;
            Scale := (if Below then Scale - Exponent else Scale + Exponent);
         end;
      end if;

      if Position /= Text'Length then
         return (Valid => False);
      end if;

      Magnitude := Significand;
      if Scale > 0 then
         for Step in 1 .. Scale loop
            pragma Loop_Invariant (Magnitude in 0 .. Precision * 10 - 1);
            exit when Magnitude = 0 or else Magnitude > Limit;
            Magnitude := Magnitude * 10;
         end loop;
      else
         for Step in 1 .. -Scale loop
            pragma Loop_Invariant (Magnitude in 0 .. Precision * 10 - 1);
            exit when Magnitude = 0;
            Inexact   := Inexact or else Magnitude mod 10 /= 0;
            Magnitude := Magnitude / 10;
         end loop;
      end if;

      if Magnitude >= Limit then
         return (Valid => True, Seconds => (if Negative then -Limit else Limit));
      elsif Negative then
         return (Valid => True, Seconds => Unix_Seconds (-Magnitude - (if Inexact then 1 else 0)));
      else
         return (Valid => True, Seconds => Unix_Seconds (Magnitude));
      end if;
   end Seconds_Of;

   ------------------
   -- Check_Signed --
   ------------------

   procedure Check_Signed
     (Token          : String;
      First_Dot      : Positive;
      Second_Dot     : Positive;
      Algorithm      : String;
      Now            : Unix_Seconds;
      Claims         : in out Json.Document;
      Valid          : out Boolean;
      Require_Expiry : Boolean)
   is
   begin
      Valid := False;
      declare
         Segment : String (1 .. Decoded_Length (Token'Length));

         --  Decode and parse one base64url segment into Claims.
         procedure Parse_Segment (Encoded : String; Parsed : out Boolean) is
            Last : Natural;
         begin
            Decode (Encoded, Segment, Last, Parsed, Url_Safe);
            if Parsed then
               Parse (Claims, Segment (1 .. Last), Parsed);
            end if;
         end Parse_Segment;

         function Seconds (Name : UTF8_String) return Seconds_Claim is
           (if Kind_Of (Claims, Member (Claims, Root, Name)) = Number_Kind
            then Seconds_Of (String (Value (Claims, Member (Claims, Root, Name))))
            else (Valid => False));

         Parsed : Boolean;
      begin
         Parse_Segment (Token (Token'First .. First_Dot - 1), Parsed);
         if not Parsed then
            return;
         end if;

         declare
            Algorithm_Node : constant Node_Count := Member (Claims, Root, "alg");
         begin
            if Kind_Of (Claims, Algorithm_Node) /= String_Kind
              or else String (Value (Claims, Algorithm_Node)) /= Algorithm
            then
               return;
            end if;
         end;

         Parse_Segment (Token (First_Dot + 1 .. Second_Dot - 1), Parsed);
         if not Parsed or else Kind_Of (Claims, Root) /= Object_Kind then
            return;
         end if;

         if Member (Claims, Root, "exp") /= No_Node then
            declare
               Expires : constant Seconds_Claim := Seconds ("exp");
            begin
               if not Expires.Valid or else Expires.Seconds <= Now then
                  return;
               end if;
            end;
         elsif Require_Expiry then
            return;
         end if;

         if Member (Claims, Root, "nbf") /= No_Node then
            declare
               Not_Before : constant Seconds_Claim := Seconds ("nbf");
            begin
               if not Not_Before.Valid or else Not_Before.Seconds > Now then
                  return;
               end if;
            end;
         end if;

         Valid := True;
      end;
   end Check_Signed;

   ------------
   -- Verify --
   ------------

   procedure Verify
     (Using          : Key;
      Token          : String;
      Now            : Unix_Seconds;
      Claims         : in out Json.Document;
      Valid          : out Boolean;
      Require_Expiry : Boolean := True)
   is
      First_Dot, Second_Dot : Natural := 0;
   begin
      Valid := False;
      if Token'Length > Max_Token_Length then
         return;
      end if;

      for Position in Token'Range loop
         pragma Loop_Invariant
           (First_Dot in 0 | Token'First .. Position - 1
            and then Second_Dot in 0 | First_Dot + 1 .. Position - 1
            and then (if Second_Dot /= 0 then First_Dot /= 0));
         if Token (Position) = '.' then
            if First_Dot = 0 then
               First_Dot := Position;
            elsif Second_Dot = 0 then
               Second_Dot := Position;
            else
               return;
            end if;
         end if;
      end loop;

      if Second_Dot = 0 then
         return;
      end if;

      --  The signature first: nothing else in the token is trusted until it matches.
      declare
         Signature : String (1 .. 48);
         Last      : Natural;
         Decoded   : Boolean;
      begin
         Decode (Token (Second_Dot + 1 .. Token'Last), Signature, Last, Decoded, Url_Safe);
         if not Decoded or else Last /= 32
           or else not Crypto.Constant_Time_Equal
                         (Left  => Signature (Signature'First .. Signature'First + 31),
                          Right => Crypto.Macs.Hmac (Using.Mac, Token (Token'First .. Second_Dot - 1)))
         then
            return;
         end if;
      end;

      Check_Signed (Token, First_Dot, Second_Dot, "HS256", Now, Claims, Valid, Require_Expiry);
   end Verify;

   ------------------
   -- Bearer_Token --
   ------------------

   function Bearer_Token (Authorization : String) return String is
      Space : Natural := 0;
   begin
      for Index in Authorization'Range loop
         if Authorization (Index) = ' ' then
            Space := Index;
            exit;
         end if;
      end loop;

      if Space = 0
        or else Space = Authorization'Last
        or else not (Encoding.Equal_Ignoring_Case (Authorization (Authorization'First .. Space - 1), "Bearer")
                     or else Encoding.Equal_Ignoring_Case (Authorization (Authorization'First .. Space - 1), "Token"))
      then
         return "";
      end if;

      return Authorization (Space + 1 .. Authorization'Last);
   end Bearer_Token;

end Sparrow.Jwt;
