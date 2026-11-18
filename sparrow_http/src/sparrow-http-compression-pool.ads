--  The compressors of Sparrow.Http.Compression: one per task compressing at the moment, kept for reuse, since
--  each holds about 200 KiB of working memory and an output buffer. Shared between tasks, so not SPARK.
with Interfaces; use Interfaces;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Deflate;

private package Sparrow.Http.Compression.Pool with SPARK_Mode => Off is

   type Compressor is record
      Work   : Deflate.State;
      Output : String_Access;     --  grown to the largest response compressed with it
      Seed   : Unsigned_64 := 0;  --  xorshift state for the padding, seeded from the system's random source
   end record;

   type Compressor_Access is access Compressor;

   --  One from the pool, or a new one when it is empty.
   procedure Take (Item : out Compressor_Access) with Post => Item /= null;

   --  Back to the pool (or freed when the pool is full); Item is null after.
   procedure Give (Item : in out Compressor_Access) with Post => Item = null;

   --  Freed, not kept: after a failure.
   procedure Discard (Item : in out Compressor_Access) with Post => Item = null;

   --  1 to 32 bytes of padding for the next response.
   procedure Draw_Padding (Item : in out Compressor; Padding : out Natural) with Post => Padding in 1 .. 32;

end Sparrow.Http.Compression.Pool;
