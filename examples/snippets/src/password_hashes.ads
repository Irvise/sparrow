package Password_Hashes is
   function New_Hash (Password : String) return String;   --  store this
   function Matches (Password, Stored : String) return Boolean;
end Password_Hashes;
