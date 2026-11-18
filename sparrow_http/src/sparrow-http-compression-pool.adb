with Ada.Unchecked_Deallocation;
with Sparrow.Crypto.Random;

package body Sparrow.Http.Compression.Pool is

   procedure Free is new Ada.Unchecked_Deallocation (Compressor, Compressor_Access);

   Capacity : constant := 256;   --  more tasks than this compressing at once allocate and free
   type Compressor_List is array (1 .. Capacity) of Compressor_Access;

   protected Kept is
      procedure Take (Item : out Compressor_Access);
      procedure Give (Item : in out Compressor_Access);
   private
      Items : Compressor_List;
      Count : Natural range 0 .. Capacity := 0;
   end Kept;

   protected body Kept is
      procedure Take (Item : out Compressor_Access) is begin
         if Count = 0 then
            Item := null;
         else
            Item := Items (Count);
            Items (Count) := null;
            Count := Count - 1;
         end if;
      end Take;

      procedure Give (Item : in out Compressor_Access) is begin
         if Count < Capacity then
            Count := Count + 1;
            Items (Count) := Item;
            Item := null;
         end if;
      end Give;
   end Kept;

   procedure Take (Item : out Compressor_Access) is
   begin
      Kept.Take (Item);
      if Item = null then
         Item := new Compressor;
         declare
            Bytes : String (1 .. 8);
         begin
            Crypto.Random.Fill (Bytes);
            for Byte of Bytes loop
               Item.Seed := Shift_Left (Item.Seed, 8) or Character'Pos (Byte);
            end loop;
         end;
         Item.Seed := Item.Seed or 1;   --  xorshift needs a seed other than zero
      end if;
   end Take;

   procedure Discard (Item : in out Compressor_Access) is
   begin
      if Item /= null then
         Free (Item.Output);
         Free (Item);
      end if;
   end Discard;

   procedure Give (Item : in out Compressor_Access) is
   begin
      if Item /= null then
         Kept.Give (Item);
         Discard (Item);   --  the pool was full
      end if;
   end Give;

   procedure Draw_Padding (Item : in out Compressor; Padding : out Natural) is
   begin
      Item.Seed := Item.Seed xor Shift_Left (Item.Seed, 13);
      Item.Seed := Item.Seed xor Shift_Right (Item.Seed, 7);
      Item.Seed := Item.Seed xor Shift_Left (Item.Seed, 17);
      Padding := 1 + Natural (Item.Seed mod 32);
   end Draw_Padding;

end Sparrow.Http.Compression.Pool;
