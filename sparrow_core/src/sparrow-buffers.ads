--  Growable byte buffers: what requests are read into, what responses, JSON, templates and protocol messages
--  are written into. A Buffer is the one type every Sparrow crate agrees on, which is what lets the pieces be
--  swapped: anything that can append to a Buffer can produce a response body.
--
--  SPARK. Every operation keeps a buffer Valid (its length within its capacity), and appends are total: past
--  Max_Capacity a buffer stops growing and is marked Overflowed instead, so no caller has to prove how large
--  its output gets.

with Interfaces; use Interfaces;

package Sparrow.Buffers with SPARK_Mode is

   type String_Access is access String;
   procedure Free (Text : in out String_Access) with Post => Text = null;

   type String_List is array (Positive range <>) of String_Access;
   type String_List_Access is access String_List;
   procedure Free (List : in out String_List_Access) with Post => List = null;   --  the list and every string

   Max_Capacity : constant := 2 ** 30;

   type Buffer is record
      Data       : String_Access;
      Length     : Natural := 0;
      Overflowed : Boolean := False;   --  an append did not fit under Max_Capacity and was dropped
   end record;
   --  Data (1 .. Length) is the content; Data'Length is the capacity. A Buffer owns its Data: Free it, and do
   --  not copy it.

   function Valid (This : Buffer) return Boolean is
     (if This.Data = null then This.Length = 0
      else This.Data'First = 1 and then This.Data'Last <= Max_Capacity and then This.Length <= This.Data'Last);

   function Capacity (This : Buffer) return Natural is (if This.Data = null then 0 else This.Data'Last)
      with Pre => Valid (This);

   function Content (This : Buffer) return String is (if This.Data = null then "" else This.Data (1 .. This.Length))
      with Pre  => Valid (This),
           Post => Content'Result'Length = This.Length;

   procedure Allocate (Into : in out Buffer; Capacity : Positive)
      with Pre  => Valid (Into) and then Capacity <= Max_Capacity,
           Post => Valid (Into) and then Into.Length = 0
                   and then not Into.Overflowed
                   and then Buffers.Capacity (Into) >= Capacity;

   procedure Free (This : in out Buffer)
      with Post => Valid (This) and then This.Data = null and then not This.Overflowed;

   procedure Clear (This : in out Buffer)
      with Inline,
           Pre  => Valid (This),
           Post => Valid (This) and then This.Length = 0 and then not This.Overflowed;

   --  Room for Extra more bytes after the content, unless that would pass Max_Capacity.
   procedure Reserve (This : in out Buffer; Extra : Natural)
      with Inline,
           Pre  => Valid (This),
           Post => Valid (This) and then This.Length = This.Length'Old
                   and then (if Extra <= Max_Capacity - This.Length then Capacity (This) - This.Length >= Extra);

   --  Count more bytes were written into the spare capacity (by a read from a socket).
   procedure Extend (This : in out Buffer; Count : Natural)
      with Pre  => Valid (This) and then Count <= Capacity (This) - This.Length,
           Post => Valid (This) and then This.Length = This.Length'Old + Count;

   --  Shorten the content to Length bytes.
   procedure Truncate (This : in out Buffer; Length : Natural)
      with Pre  => Valid (This) and then Length <= This.Length,
           Post => Valid (This) and then This.Length = Length;

   --  Remove the first Count bytes, keeping the rest.
   procedure Consume (This : in out Buffer; Count : Natural)
      with Pre  => Valid (This) and then Count <= This.Length,
           Post => Valid (This) and then This.Length = This.Length'Old - Count;

   --  Text, unless it does not fit under Max_Capacity: then nothing, and Overflowed.
   procedure Append (To : in out Buffer; Text : String)
      with Inline,
           Pre  => Valid (To),
           Post => Valid (To) and then (if Text'Length <= Max_Capacity - To.Length'Old
                                        then To.Length = To.Length'Old + Text'Length
                                        else To.Length = To.Length'Old and then To.Overflowed);

   --  The same for text. It has a name of its own because a literal would fit either Append.
   procedure Append_Text (To : in out Buffer; Text : UTF8_String)
      with Inline,
           Pre  => Valid (To),
           Post => Valid (To) and then (if Text'Length <= Max_Capacity - To.Length'Old
                                        then To.Length = To.Length'Old + Text'Length
                                        else To.Length = To.Length'Old and then To.Overflowed);

   procedure Append (To : in out Buffer; Byte : Character)
      with Inline,
           Pre  => Valid (To),
           Post => Valid (To) and then To.Length in To.Length'Old .. To.Length'Old + 1;

   --  Decimal digits.
   procedure Append_Integer (To : in out Buffer; Value : Long_Long_Integer)
      with Pre  => Valid (To),
           Post => Valid (To) and then To.Length >= To.Length'Old;

   ---------------------------------------------------------------------------------------------------------------
   --  big-endian integers, for wire protocols. Exactly the bytes asked for, unless the buffer overflowed.

   procedure Append_Big_Endian (To : in out Buffer; Value : Unsigned_16)
      with Inline,
           Pre  => Valid (To),
           Post => Valid (To) and then (if not To.Overflowed
                                        then To.Length = To.Length'Old + 2
                                        else To.Length >= To.Length'Old);

   procedure Append_Big_Endian (To : in out Buffer; Value : Unsigned_32)
      with Inline,
           Pre  => Valid (To),
           Post => Valid (To) and then (if not To.Overflowed
                                        then To.Length = To.Length'Old + 4
                                        else To.Length >= To.Length'Old);

   procedure Append_Big_Endian (To : in out Buffer; Value : Unsigned_64)
      with Inline,
           Pre  => Valid (To),
           Post => Valid (To) and then (if not To.Overflowed
                                        then To.Length = To.Length'Old + 8
                                        else To.Length >= To.Length'Old);

   --  Replace the four bytes at Position (a length word written before the length was known).
   procedure Overwrite_Big_Endian (This : in out Buffer; Position : Positive; Value : Unsigned_32)
      with Inline,
           Pre  => Valid (This) and then Position <= This.Length - 3,
           Post => Valid (This) and then This.Length = This.Length'Old;

end Sparrow.Buffers;
