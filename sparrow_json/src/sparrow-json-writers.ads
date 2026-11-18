--  Writing JSON straight into a Buffer, with no tree in between. The Writer only remembers where commas and
--  colons go; the output is the Buffer the caller passes, usually a response's content.
--
--     Begin_Object (W, Page);
--        Member (W, Page, "id", 42);
--        Key (W, Page, "tags"); Begin_Array (W, Page);
--           Value (W, Page, "ada");
--        End_Array (W, Page);
--     End_Object (W, Page);        -->  {"id":42,"tags":["ada"]}
--
--  SPARK. Total: a call that does not fit the structure (a Key outside an object, nesting past Max_Depth, an
--  End without its Begin) writes nothing and clears Well_Formed. Strings are escaped.
with Sparrow.Buffers; use Sparrow.Buffers;

package Sparrow.Json.Writers with SPARK_Mode is

   type Writer is private;

   --  Whether every call so far fitted the structure. Check it (and the buffer's Overflowed) once, at the end.
   function Well_Formed (This : Writer) return Boolean;

   --  Whether every value begun has been ended.
   function Complete (This : Writer) return Boolean;

   procedure Begin_Object (This : in out Writer; Into : in out Buffer) with Pre => Valid (Into), Post => Valid (Into);
   procedure End_Object (This : in out Writer; Into : in out Buffer)   with Pre => Valid (Into), Post => Valid (Into);
   procedure Begin_Array (This : in out Writer; Into : in out Buffer)  with Pre => Valid (Into), Post => Valid (Into);
   procedure End_Array (This : in out Writer; Into : in out Buffer)    with Pre => Valid (Into), Post => Valid (Into);

   --  A member name; the member's value comes next.
   procedure Key (This : in out Writer; Into : in out Buffer; Name : UTF8_String)
      with Pre => Valid (Into), Post => Valid (Into);

   procedure Value (This : in out Writer; Into : in out Buffer; Text : UTF8_String)
      with Pre => Valid (Into), Post => Valid (Into);
   procedure Value (This : in out Writer; Into : in out Buffer; Number : Long_Long_Integer)
      with Pre => Valid (Into), Post => Valid (Into);
   procedure Value (This : in out Writer; Into : in out Buffer; Number : Long_Float)   --  null when not finite
      with Pre => Valid (Into), Post => Valid (Into);
   procedure Value (This : in out Writer; Into : in out Buffer; Flag : Boolean)
      with Pre => Valid (Into), Post => Valid (Into);
   procedure Null_Value (This : in out Writer; Into : in out Buffer)
      with Pre => Valid (Into), Post => Valid (Into);

   --  Fragment is written as it is: a value rendered elsewhere (a cached fragment, a Postgres json column).
   procedure Raw_Value (This : in out Writer; Into : in out Buffer; Fragment : UTF8_String)
      with Pre => Valid (Into), Post => Valid (Into);

   --  Key then Value.
   procedure Member (This : in out Writer; Into : in out Buffer; Name : UTF8_String; Text : UTF8_String)
      with Pre => Valid (Into), Post => Valid (Into);
   procedure Member (This : in out Writer; Into : in out Buffer; Name : UTF8_String; Number : Long_Long_Integer)
      with Pre => Valid (Into), Post => Valid (Into);
   procedure Member (This : in out Writer; Into : in out Buffer; Name : UTF8_String; Flag : Boolean)
      with Pre => Valid (Into), Post => Valid (Into);

   --  A string literal on its own, quotes included, for code that builds JSON by hand.
   procedure Append_String (To : in out Buffer; Text : UTF8_String)
      with Pre  => Valid (To) and then Text'Length <= 2 ** 26 and then Text'Last < Integer'Last,
           Post => Valid (To) and then To.Length >= To.Length'Old
                   and then To.Length <= To.Length'Old + 6 * Text'Length + 2;   --  every byte escaped

private

   type Depth is range 0 .. Max_Depth;

   type Level is record
      In_Object : Boolean := False;
      Has_Items : Boolean := False;   --  the next item needs a comma first
      After_Key : Boolean := False;   --  a Key was written and its value is due
   end record;

   type Level_Stack is array (Depth range 1 .. Depth'Last) of Level;

   type Writer is record
      Levels  : Level_Stack;
      Current : Depth := 0;
      Done    : Boolean := False;     --  the top-level value is finished
      Sound   : Boolean := True;
   end record;

   function Well_Formed (This : Writer) return Boolean is (This.Sound);
   function Complete (This : Writer) return Boolean is (This.Done and then This.Current = 0);

end Sparrow.Json.Writers;
