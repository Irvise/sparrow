--  Sparrow: a small web stack for Linux, macOS and Windows. This crate (sparrow_core) owns the root package
--  and the pieces every other Sparrow crate shares: byte buffers, text and time formats, Base64.
--
--  Conventions used throughout Sparrow:
--    * Bytes are String: what sockets carry, what digests and wire messages are made of, and whatever a
--      client sent, until it has been checked.
--    * Text is UTF8_String, a type of its own. The compiler keeps the two apart, so bytes become text only
--      where someone wrote a conversion: use the checked ones in Sparrow.Encoding.
--    * Parsers and decoders are total: bad input yields Valid = False (or a neutral value), never an exception.
--    * Appends to a Buffer are total: past the capacity limit the buffer is marked Overflowed instead.
--    * A unit that says "SPARK" in its header is written to be proved free of run-time errors (silver).

package Sparrow with Pure, SPARK_Mode is

   Version : constant String := "1.0.0";

   --  Well-formed UTF-8. Literals, slices, "&" and comparisons work as for String; a slice is taken by bytes,
   --  so cut only at character boundaries.
   --
   --  Text to bytes is always sound: String (Text), or Sparrow.Encoding.To_Bytes. Bytes to text is sound only
   --  after a check: Sparrow.Encoding.To_UTF8. The language also allows the bare conversion UTF8_String (Bytes),
   --  which checks nothing; Sparrow uses it only on bytes it has itself validated or produced, and each use
   --  carries a comment saying why it holds.
   --
   --  A note on literals. A literal that is plain ASCII is always what it looks like. One that is not depends
   --  on how the compiler reads the source file: under -gnatW8 (which Alire sets by default) "é" in a
   --  UTF8_String is the single Latin-1 byte 16#E9#, which is not UTF-8, and "€" does not compile at all;
   --  under -gnatWb (GNAT's own default) the file's bytes are kept and a UTF-8 file gives UTF-8 literals.
   --  Sparrow.Encoding.From_Unicode ("é") is right under both.
   type UTF8_String is new String;

end Sparrow;
