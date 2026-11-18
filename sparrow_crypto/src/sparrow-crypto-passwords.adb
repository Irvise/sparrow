with Sparrow.Base64;
with Sparrow.Encoding;

package body Sparrow.Crypto.Passwords with SPARK_Mode => Off is

   Hash_Bytes : constant := 32;

   --  Each format is a prefix, three decimal parameters with their separators, then "$salt$hash".
   type Separator_List is array (1 .. 3) of access constant String;

   Argon2_Prefix    : aliased constant String := "$argon2id$v=19$m=";
   Argon2_Separator : aliased constant String := ",t=";
   Scrypt_Prefix    : aliased constant String := "$scrypt$ln=";
   Scrypt_Separator : aliased constant String := ",r=";
   Lanes_Separator  : aliased constant String := ",p=";
   Salt_Separator   : aliased constant String := "$";

   function Prefix_Of (Kind : Algorithm) return String is
     (case Kind is when Argon2id => Argon2_Prefix, when Scrypt => Scrypt_Prefix);

   function Separators_Of (Kind : Algorithm) return Separator_List is
     (case Kind is
         when Argon2id => [Argon2_Separator'Access, Lanes_Separator'Access, Salt_Separator'Access],
         when Scrypt   => [Scrypt_Separator'Access, Lanes_Separator'Access, Salt_Separator'Access]);

   --  Standard Base64 without padding, as the PHC format writes it.
   function Unpadded (Data : String) return String is
      Text : constant String := Base64.Encode (Data, Base64.Standard);
      Last : Natural := Text'Last;
   begin
      while Last >= Text'First and then Text (Last) = '=' loop
         Last := Last - 1;
      end loop;
      return Text (Text'First .. Last);
   end Unpadded;

   function Image (Value : Positive) return String is (Encoding.Decimal_Image (Long_Long_Integer (Value)));

   function Derive (Kind : Algorithm; Password, Salt : String; Length : Positive; Using : Cost;
                    Fallback : Fallback_Cost) return String is
   begin
      case Kind is
         when Argon2id =>
            if not Argon2_Available then
               raise Crypto_Error with "this password hash is Argon2id, which needs OpenSSL 3.2 or later; the "
                                       & "OpenSSL this program loaded only has scrypt";
            end if;
            return Key_Derivation.Argon2id (Password, Salt, Length, Using.Memory, Using.Iterations, Using.Lanes);
         when Scrypt =>
            return Key_Derivation.Scrypt (Password, Salt, Length, Fallback.Log_N, Fallback.Block_Size,
                                          Fallback.Parallelism);
      end case;
   end Derive;

   function Hash
     (Password : String;
      Salt     : Salt_Bytes;
      Using    : Cost          := Default_Cost;
      Fallback : Fallback_Cost := Default_Fallback;
      Kind     : Algorithm     := Preferred) return String
   is
      Parameters : constant String :=
        (case Kind is
            when Argon2id =>
              Image (Using.Memory) & ",t=" & Image (Using.Iterations) & ",p=" & Image (Using.Lanes),
            when Scrypt   =>
              Image (Fallback.Log_N) & ",r=" & Image (Fallback.Block_Size) & ",p=" & Image (Fallback.Parallelism));
      Result : constant String :=
        Prefix_Of (Kind) & Parameters & "$" & Unpadded (Salt)
        & "$" & Unpadded (Derive (Kind, Password, Salt, Hash_Bytes, Using, Fallback));
   begin
      return Result;
   end Hash;

   --  A stored hash taken apart.
   type Parsed (Valid : Boolean := False) is record
      case Valid is
         when True =>
            Kind       : Algorithm;
            Using      : Cost;            --  for Argon2id
            Fallback   : Fallback_Cost;   --  for scrypt
            Salt_First : Positive;        --  of the Base64 salt in the stored text
            Salt_Last  : Natural;
            Hash_First : Positive;
         when False =>
            null;
      end case;
   end record;

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length > Prefix'Length and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Parse (Stored : String) return Parsed is
      Kind   : Algorithm;
      Next   : Integer;
      Values : array (1 .. 3) of Long_Long_Integer := [others => 0];
   begin
      if Stored'Length > 512 then
         return (Valid => False);
      elsif Starts_With (Stored, Argon2_Prefix) then
         Kind := Argon2id;
      elsif Starts_With (Stored, Scrypt_Prefix) then
         Kind := Scrypt;
      else
         return (Valid => False);
      end if;
      Next := Stored'First + Prefix_Of (Kind)'Length;

      --  Three numbers, each followed by its separator.
      for Index in Values'Range loop
         declare
            First : constant Integer := Next;
            After : constant String := Separators_Of (Kind) (Index).all;
            Valid : Boolean;
         begin
            while Next <= Stored'Last and then Stored (Next) in '0' .. '9' loop
               Next := Next + 1;
            end loop;
            if Next = First or else Next - First > 9 then
               return (Valid => False);
            end if;
            Encoding.Parse_Decimal (Stored (First .. Next - 1), Values (Index), Valid);
            if not Valid
              or else Next + After'Length - 1 > Stored'Last
              or else Stored (Next .. Next + After'Length - 1) /= After
            then
               return (Valid => False);
            end if;
            Next := Next + After'Length;
         end;
      end loop;

      case Kind is
         when Argon2id =>
            if Values (1) not in 8 .. Long_Long_Integer (Max_Memory)
              or else Values (2) not in 1 .. Long_Long_Integer (Argon2_Iterations'Last)
              or else Values (3) not in 1 .. Long_Long_Integer (Argon2_Lanes'Last)
              or else Values (1) < 8 * Values (3)
            then
               return (Valid => False);
            end if;
         when Scrypt =>
            if Values (1) not in Long_Long_Integer (Scrypt_Cost'First) .. Long_Long_Integer (Scrypt_Cost'Last)
              or else Values (2) not in 1 .. Long_Long_Integer (Scrypt_Block_Size'Last)
              or else Values (3) not in 1 .. Long_Long_Integer (Scrypt_Parallelism'Last)
              or else Values (2) * 2 ** Natural (Values (1)) / 8 > Long_Long_Integer (Max_Memory)
            then
               return (Valid => False);
            end if;
      end case;

      for Dollar in Next .. Stored'Last loop
         if Stored (Dollar) = '$' then
            return (Valid      => True,
                    Kind       => Kind,
                    Using      => (if Kind = Argon2id
                                   then (Memory     => Argon2_Memory (Values (1)),
                                         Iterations => Argon2_Iterations (Values (2)),
                                         Lanes      => Argon2_Lanes (Values (3)))
                                   else Default_Cost),
                    Fallback   => (if Kind = Scrypt
                                   then (Log_N       => Scrypt_Cost (Values (1)),
                                         Block_Size  => Scrypt_Block_Size (Values (2)),
                                         Parallelism => Scrypt_Parallelism (Values (3)))
                                   else Default_Fallback),
                    Salt_First => Next,
                    Salt_Last  => Dollar - 1,
                    Hash_First => Dollar + 1);
         end if;
      end loop;
      return (Valid => False);
   end Parse;

   function Verify (Password : String; Stored : String) return Boolean is
      Parts : constant Parsed := Parse (Stored);
   begin
      if not Parts.Valid or else Password'Length > Max_Password_Length then
         return False;
      end if;
      declare
         Salt_Text  : String renames Stored (Parts.Salt_First .. Parts.Salt_Last);
         Hash_Text  : String renames Stored (Parts.Hash_First .. Stored'Last);
         Salt       : String (1 .. Base64.Decoded_Length (Salt_Text'Length));
         Expected   : String (1 .. Base64.Decoded_Length (Hash_Text'Length));
         Salt_Last  : Natural;
         Hash_Last  : Natural;
         Salt_Valid : Boolean;
         Hash_Valid : Boolean;
      begin
         Base64.Decode (Salt_Text, Salt, Salt_Last, Salt_Valid);
         Base64.Decode (Hash_Text, Expected, Hash_Last, Hash_Valid);
         if not Salt_Valid or else not Hash_Valid or else Salt_Last < 8 or else Hash_Last not in 4 .. 1024 then
            return False;
         end if;
         return Constant_Time_Equal
           (Derive (Parts.Kind, Password, Salt (1 .. Salt_Last), Hash_Last, Parts.Using, Parts.Fallback),
            Expected (1 .. Hash_Last));
      end;
   end Verify;

   function Needs_Rehash
     (Stored   : String;
      Using    : Cost          := Default_Cost;
      Fallback : Fallback_Cost := Default_Fallback) return Boolean
   is
      Parts : constant Parsed := Parse (Stored);
   begin
      if not Parts.Valid or else Parts.Kind /= Preferred then
         return True;
      end if;
      return (case Parts.Kind is
                 when Argon2id => Parts.Using /= Using,
                 when Scrypt   => Parts.Fallback /= Fallback);
   end Needs_Rehash;

end Sparrow.Crypto.Passwords;
