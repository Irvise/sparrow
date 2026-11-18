package body Sparrow.Json.Iteration is

   type Document_View is access constant Document;

   type Child_Walk is new Node_Iterators.Forward_Iterator with record
      Source : Document_View;
      Parent : Node_Count;   --  No_Node: nothing to walk
   end record;

   overriding function First (Object : Child_Walk) return Node_Count is
     (if Object.Parent = No_Node then No_Node else First_Child (Object.Source.all, Object.Parent));

   overriding function Next (Object : Child_Walk; Position : Node_Count) return Node_Count is
     (Next_Sibling (Object.Source.all, Position));

   --  Document is limited, so passed by reference: the view stays good while the caller's document does.
   function Walk (This : Document; Path : UTF8_String; From : Node_Count; Wanted : Kind)
      return Node_Iterators.Forward_Iterator'Class
   is
      Parent : constant Node_Count := Find (This, Path, From);
   begin
      return Child_Walk'(Source => This'Unrestricted_Access,
                         Parent => (if Kind_Of (This, Parent) = Wanted then Parent else No_Node));
   end Walk;

   function Elements
     (This : Document; Path : UTF8_String := ""; From : Node_Count := Root)
      return Node_Iterators.Forward_Iterator'Class is (Walk (This, Path, From, Array_Kind));

   function Members
     (This : Document; Path : UTF8_String := ""; From : Node_Count := Root)
      return Node_Iterators.Forward_Iterator'Class is (Walk (This, Path, From, Object_Kind));

end Sparrow.Json.Iteration;
