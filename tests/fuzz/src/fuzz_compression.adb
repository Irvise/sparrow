--  gzip compression, and the two headers that decide compression and ranges.
--
--  Properties: whatever the bytes, Sparrow.Gzip's output is a gzip member zlib decodes back to them (with room
--  to spare, and also in a tight buffer when the result fits there); Accept-Encoding and Range values never
--  raise, and a Range part lies inside the representation.
with Fuzz_Driver; use Fuzz_Driver;
with Sparrow.Deflate;
with Sparrow.Gzip;
with Sparrow.Http.Compression;
with Sparrow.Http.Ranges; use Sparrow.Http.Ranges;
with Zlib_Check;

procedure Fuzz_Compression is

   type State_Access is access Sparrow.Deflate.State;
   Work : constant State_Access := new Sparrow.Deflate.State;

   procedure Test (Input : String) is
      Room   : String (1 .. Input'Length + Input'Length / 50 + 64 + 32);
      Tight  : String (1 .. Input'Length / 2 + 20);
      Last   : Natural;
      Fits   : Boolean;
      Header : constant Boolean := Input'Length > 0 and then Character'Pos (Input (Input'First)) mod 4 = 0;
   begin
      if Header then
         declare
            Text  : constant String := Input (Input'First + 1 .. Input'Last);
            Taken : constant Boolean := Sparrow.Http.Compression.Accepts_Gzip (Text)
                                        or else Sparrow.Http.Compression.Compressible (Text);
            Part  : constant Byte_Range := Parse (Text, Byte_Count (Input'Length * 37));
         begin
            pragma Unreferenced (Taken);
            Check (Part.Kind /= Sparrow.Http.Ranges.Part
                   or else (Part.First <= Part.Last and then Part.Last < Byte_Count (Input'Length * 37)),
                   "a range lies inside the representation");
         end;
      end if;
      Sparrow.Gzip.Compress (Work.all, Input, Room, Last, Fits,
                             Padding => (if Input'Length > 0 then Character'Pos (Input (Input'Last)) mod 33 else 0));
      Check (Fits, "everything fits with room to spare");
      Check (Zlib_Check.Inflated (Room (1 .. Last), Limit => Input'Length + 1) = Input,
             "zlib decodes what was compressed");
      Sparrow.Gzip.Compress (Work.all, Input, Tight, Last, Fits);
      if Fits then
         Check (Zlib_Check.Inflated (Tight (1 .. Last), Limit => Input'Length + 1) = Input,
                "zlib decodes a tight result too");
      end if;
   end Test;

   procedure Fuzz is new Run (Test);

begin
   Fuzz;
end Fuzz_Compression;
