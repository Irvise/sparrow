--  The JSON reader, and the writer through it.
--
--  Properties: a document that parses is written back (Sparrow.Json.Writers) as JSON that parses again, and
--  writing that second document gives the same text: reading and writing agree on every value.
with Fuzz_Driver; use Fuzz_Driver;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Json; use Sparrow.Json;
with Sparrow.Json.Writers; use Sparrow.Json.Writers;

procedure Fuzz_Json is

   procedure Write (From : Document; Item : Node_Count; Output : in out Writer; Into : in out Buffer) is
      Child : Node_Count;
   begin
      case Kind_Of (From, Item) is
         when Null_Kind   => Null_Value (Output, Into);
         when True_Kind   => Value (Output, Into, Flag => True);
         when False_Kind  => Value (Output, Into, Flag => False);
         when Number_Kind => Raw_Value (Output, Into, Sparrow.Json.Value (From, Item));
         when String_Kind => Value (Output, Into, Text => Sparrow.Json.Value (From, Item));
         when Array_Kind | Object_Kind =>
            if Kind_Of (From, Item) = Array_Kind then
               Begin_Array (Output, Into);
            else
               Begin_Object (Output, Into);
            end if;
            Child := First_Child (From, Item);
            while Child /= No_Node loop
               if Kind_Of (From, Item) = Object_Kind then
                  Key (Output, Into, Name (From, Child));
               end if;
               Write (From, Child, Output, Into);
               Child := Next_Sibling (From, Child);
            end loop;
            if Kind_Of (From, Item) = Array_Kind then
               End_Array (Output, Into);
            else
               End_Object (Output, Into);
            end if;
      end case;
   end Write;

   function Written (From : Document) return String is
      Output : Writer;
      Into   : Buffer;
   begin
      Write (From, Root, Output, Into);
      Check (Well_Formed (Output) and then Complete (Output), "the writer accepts what the reader read");
      return Text : constant String := Content (Into) do
         Free (Into);
      end return;
   end Written;

   --  The documents are Test's own, so Test needs nothing of this procedure's and libFuzzer's callback no
   --  trampoline.
   procedure Test (Input : String) is
      First_Document  : Document (Node_Capacity => 4096, Text_Capacity => 65_536);
      Second_Document : Document (Node_Capacity => 4096, Text_Capacity => 65_536);
      Valid           : Boolean;
   begin
      Parse (First_Document, Input, Valid);
      if not Valid then
         return;
      end if;
      declare
         First_Text : constant String := Written (First_Document);
      begin
         Parse (Second_Document, First_Text, Valid);
         Check (Valid, "written JSON parses");
         Check (Written (Second_Document) = First_Text, "writing what was written gives the same text");
      end;
   end Test;

   procedure Fuzz is new Run (Test);

begin
   Fuzz;
end Fuzz_Json;
