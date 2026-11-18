--  HPACK (RFC 7541), the header compression of HTTP/2: a decoder for the header blocks clients send, and an
--  encoder for the server's responses.
--
--  The decoder keeps the dynamic table the client's encoder fills, so one Decoder serves one connection and sees
--  every header block of it, in order. Its table lives in a fixed array (Table_Capacity bytes, the size HTTP/2
--  starts with and the most a client may choose): nothing is allocated.
--
--  The encoder keeps no state: every field is sent as a literal that is not indexed, naming a static-table entry
--  where one fits. Responses compress less than they could, but nothing a client says can change what the
--  encoder holds.
with Sparrow.Buffers; use Sparrow.Buffers;

package Sparrow.Http.Hpack with SPARK_Mode is

   Table_Capacity : constant := 4096;   --  SETTINGS_HEADER_TABLE_SIZE as the server announces it

   type Decoder is private;

   --  A decoder with an empty table.
   function New_Decoder return Decoder;

   --  Where one decoded field is in the text Decode writes: Name_First .. Name_Last, Value_First .. Value_Last
   --  (empty when Last < First).
   type Field is record
      Name_First  : Positive := 1;
      Name_Last   : Natural := 0;
      Value_First : Positive := 1;
      Value_Last  : Natural := 0;
   end record;

   type Field_Array is array (Positive range <>) of Field;

   type Outcome is
     (Decoded,
      Malformed,     --  not HPACK: a connection error (COMPRESSION_ERROR)
      Too_Large);    --  more text than Text holds, or more fields than Fields

   --  Whether Item's name and value lie within Text (1 .. Last).
   function Within (Item : Field; Last : Natural) return Boolean is
     (Item.Name_First - 1 <= Item.Name_Last and then Item.Name_Last <= Last
      and then Item.Value_First - 1 <= Item.Value_Last and then Item.Value_Last <= Last);

   --  Decode one whole header block: the fields' names and values go into Text (1 .. Text_Last), one after
   --  another, and Fields (1 .. Count) say where. After Malformed or Too_Large the table no longer matches the
   --  client's: end the connection.
   procedure Decode
     (This      : in out Decoder;
      Block     : String;
      Text      : out String;
      Text_Last : out Natural;
      Fields    : out Field_Array;
      Count     : out Natural;
      Result    : out Outcome)
      with Pre  => Text'First = 1 and then Text'Last in 0 .. Positive'Last - 1 and then Fields'First = 1
                   and then Fields'Last in 0 .. Positive'Last - 1
                   and then Block'First >= 1 and then Block'Last < Positive'Last,
           Post => Text_Last <= Text'Last and then Count <= Fields'Last
                   and then (for all Index in 1 .. Count => Within (Fields (Index), Text_Last));

   --  The encoder. Name must already be lower case, as HTTP/2 requires.
   procedure Encode_Status (Into : in out Buffer; Status : Status_Code)
      with Pre => Valid (Into), Post => Valid (Into);

   procedure Encode_Field (Into : in out Buffer; Name, Value : String)
      with Pre => Valid (Into) and then Name'Length <= 2 ** 20 and then Value'Length <= 2 ** 24,
           Post => Valid (Into);

   --  Primitives, also for tests: an integer with an N-bit prefix (RFC 7541 5.1) whose first byte carries Flags
   --  above the prefix, and Huffman decoding (5.2).
   procedure Encode_Integer (Into : in out Buffer; Value : Natural; Prefix_Bits : Positive; Flags : Natural)
      with Pre  => Valid (Into) and then Prefix_Bits <= 8 and then Flags < 256,
           Post => Valid (Into);

   procedure Decode_Huffman (Source : String; Text : in out String; Last : in out Natural; Result : out Outcome)
      with Pre  => Text'First = 1 and then Last <= Text'Last,
           Post => Last in Last'Old .. Text'Last;

private

   type Ring_Position is mod Table_Capacity;
   Max_Entries : constant := Table_Capacity / 32;   --  every entry counts 32 bytes beyond its text
   type Entry_Position is mod Max_Entries;

   subtype Table_Size is Natural range 0 .. Table_Capacity;

   type Table_Entry is record
      Start        : Ring_Position := 0;   --  the name, then the value, from here round the ring
      Name_Length  : Table_Size := 0;
      Value_Length : Table_Size := 0;
   end record;

   type Byte_Ring is array (Ring_Position) of Character;
   type Entry_Ring is array (Entry_Position) of Table_Entry;

   --  The entries are a queue: Count of them, the newest at Newest, older ones before it round the ring. Their
   --  text is a queue in Bytes too, Next_Byte where the next entry's goes.
   type Decoder is record
      Bytes     : Byte_Ring := [others => ' '];
      Next_Byte : Ring_Position := 0;
      Entries   : Entry_Ring;
      Newest    : Entry_Position := Entry_Position'Last;
      Count     : Natural range 0 .. Max_Entries := 0;
      Size      : Table_Size := 0;               --  RFC 7541 4.1: each entry's name and value, plus 32
      Max_Size  : Table_Size := Table_Capacity;  --  as the client's last size update set it
   end record;

   function New_Decoder return Decoder is ((others => <>));

end Sparrow.Http.Hpack;
