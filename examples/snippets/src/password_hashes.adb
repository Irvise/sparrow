with Sparrow.Crypto.Passwords; use Sparrow.Crypto;
with Sparrow.Crypto.Random;

package body Password_Hashes is

   function New_Hash (Password : String) return String is
      Salt : Passwords.Salt_Bytes;
   begin
      Random.Fill (Salt);
      --  "$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>"
      return Passwords.Hash (Password, Salt);
   end New_Hash;

   --  Compared in constant time.
   function Matches (Password, Stored : String) return Boolean is
     (Passwords.Verify (Password, Stored));

end Password_Hashes;
