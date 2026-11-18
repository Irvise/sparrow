--  RESP2, the protocol of Valkey (and Redis): a command is an array of bulk strings, and a reply is scanned for
--  completeness before it is read, element by element.
--
--  SPARK: no reply, however malformed or cut short, makes Scan or Element_At raise or read outside it.
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Encoding; use Sparrow.Encoding;

package Sparrow.Valkey_Protocol with SPARK_Mode is

   Max_Elements    : constant := 1_000_000;          --  in one reply, nested arrays' included
   Max_Bulk_Length : constant := 512 * 1_048_576;    --  Valkey's own limit for one string

   type Element_Kind is
     (Simple_Text,     --  +OK
      Error_Text,      --  -ERR ...
      Whole_Number,    --  :42
      Bulk_Text,       --  $5 hello
      Nil,             --  $-1 (or *-1): no value
      List,            --  *3, then its elements
      Incomplete,      --  more bytes are needed
      Malformed);

   type Element is record
      Kind   : Element_Kind := Incomplete;
      Text   : Span;                        --  Simple_Text, Error_Text, Bulk_Text
      Number : Long_Long_Integer := 0;      --  Whole_Number; the element count of a List
      Next   : Positive := 1;               --  where the next element starts (a List's first element)
   end record;

   --  The element at Position: its kind and where it ends. Complete elements end inside Data.
   function Element_At (Data : String; Position : Positive) return Element
      with Pre  => Data'Last < Positive'Last - 2 and then Position in Data'Range,
           Post => (if Element_At'Result.Kind not in Incomplete | Malformed
                    then Element_At'Result.Next in Position + 1 .. Data'Last + 1
                         and then Within (Element_At'Result.Text, Data)
                         and then (if Element_At'Result.Kind = List
                                   then Element_At'Result.Number in 0 .. Max_Elements));

   type Scan_Outcome is (Complete, Waiting, Refused);

   type Scan_Result (Outcome : Scan_Outcome := Waiting) is record
      case Outcome is
         when Complete => Length : Positive;   --  the reply's bytes, from Data'First
         when others   => null;
      end case;
   end record;

   --  Whether Data starts with a whole reply (nested arrays and all), and how long it is.
   function Scan (Data : String) return Scan_Result
      with Pre  => Data'First >= 1 and then Data'Last < Positive'Last - 2,
           Post => (if Scan'Result.Outcome = Complete then Scan'Result.Length <= Data'Length);

   --  A command: Header (the argument count), then each argument.
   function Header (Count : Positive) return String;
   procedure Append_Argument (To : in out Buffer; Argument : String)
      with Pre => Sparrow.Buffers.Valid (To), Post => Sparrow.Buffers.Valid (To);

end Sparrow.Valkey_Protocol;
