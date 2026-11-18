package body Sparrow.Templates.Json_Data is

   use Sparrow.Json;

   --  The node Name names inside Within ("." is Within itself).
   function Node_Of (This : Json_Source; Within : Scope; Name : UTF8_String) return Node_Count is
     (if Within > Scope (Node_Count'Last) then No_Node
      elsif Name = "." then Node_Count (Within)
      else Member (This.Document.all, Node_Count (Within), Name));

   overriding function Kind_Of (This : Json_Source; Within : Scope; Name : UTF8_String) return Value_Kind is
      Node : constant Node_Count := Node_Of (This, Within, Name);
   begin
      if Node = No_Node then
         return Absent;
      end if;
      return (case Kind_Of (This.Document.all, Node) is
                 when Null_Kind | False_Kind     => False_Value,
                 when True_Kind                  => True_Value,
                 when Number_Kind | String_Kind  => Scalar,
                 when Array_Kind                 => List,
                 when Object_Kind                => Object);
   end Kind_Of;

   overriding procedure Append_Value (This : Json_Source; Within : Scope; Name : UTF8_String; To : in out Buffer)
   is begin
      Append_Text (To, Value (This.Document.all, Node_Of (This, Within, Name)));
   end Append_Value;

   overriding function Item_Count (This : Json_Source; Within : Scope; Name : UTF8_String) return Natural is
      Node : constant Node_Count := Node_Of (This, Within, Name);
   begin
      return (case Kind_Of (This.Document.all, Node) is
                 when Array_Kind  => Child_Count (This.Document.all, Node),
                 when Object_Kind => 1,
                 when others      => 0);
   end Item_Count;

   overriding function Item (This : Json_Source; Within : Scope; Name : UTF8_String; Index : Positive) return Scope is
      Node  : constant Node_Count := Node_Of (This, Within, Name);
      Child : Node_Count;
   begin
      case Kind_Of (This.Document.all, Node) is
         when Object_Kind =>
            return Scope (Node);
         when Array_Kind =>
            Child := First_Child (This.Document.all, Node);
            for Skip in 2 .. Index loop
               exit when Child = No_Node;
               Child := Next_Sibling (This.Document.all, Child);
            end loop;
            return (if Child = No_Node then Within else Scope (Child));
         when others =>
            return Within;
      end case;
   end Item;

end Sparrow.Templates.Json_Data;
