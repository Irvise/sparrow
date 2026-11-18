--  Template data read from a parsed JSON document: objects are scopes, arrays are lists, strings and numbers
--  are scalars. A scope is a node of the document.
--
--     Data : Json_Source (Document'Access);
--     Render (Pages, "article", Data, Response.Content, Found);
with Sparrow.Json;

package Sparrow.Templates.Json_Data is

   type Json_Source (Document : not null access constant Json.Document) is limited new Data_Source with record
      Start : Json.Node_Index := Json.Root;   --  the node rendering starts in
   end record;

   overriding function Top (This : Json_Source) return Scope is (Scope (This.Start));
   overriding function Kind_Of (This : Json_Source; Within : Scope; Name : UTF8_String) return Value_Kind;
   overriding procedure Append_Value (This : Json_Source; Within : Scope; Name : UTF8_String; To : in out Buffer);
   overriding function Item_Count (This : Json_Source; Within : Scope; Name : UTF8_String) return Natural;
   overriding function Item (This : Json_Source; Within : Scope; Name : UTF8_String; Index : Positive) return Scope;

end Sparrow.Templates.Json_Data;
