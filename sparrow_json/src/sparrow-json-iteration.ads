--  Loops over the elements of an array or the members of an object. The loop variable is the child's node,
--  so the path accessors read inside it with From:
--
--     for Item in Json.Iteration.Elements (Doc, "items") loop
--        Show (Json.Text (Doc, "title", From => Item), Json.Integer_Value (Doc, "count", From => Item));
--     end loop;
--
--     for Field in Json.Iteration.Members (Doc, "labels") loop
--        Show (Json.Name (Doc, Field), Json.Value (Doc, Field));
--     end loop;
--
--  Not SPARK (Ada iterators are not); the proved walk underneath is First_Child and Next_Sibling.
with Ada.Iterator_Interfaces;

package Sparrow.Json.Iteration with SPARK_Mode => Off is

   function Has_Element (Position : Node_Count) return Boolean is (Position /= No_Node);

   package Node_Iterators is new Ada.Iterator_Interfaces (Node_Count, Has_Element);

   --  The elements of the array at Path below From; none when it is missing or not an array. This must
   --  outlive the loop.
   function Elements
     (This : Document; Path : UTF8_String := ""; From : Node_Count := Root)
      return Node_Iterators.Forward_Iterator'Class;

   --  The members of the object at Path below From, in source order; none when it is missing or not an object.
   function Members
     (This : Document; Path : UTF8_String := ""; From : Node_Count := Root)
      return Node_Iterators.Forward_Iterator'Class;

end Sparrow.Json.Iteration;
