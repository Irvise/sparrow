procedure Sparrow.Templates.Bindings.Add_Rows
  (This : in out Binding_Set; Name : UTF8_String; From : in out Rows; Within : Scope := Top_Scope)
is
   Item : Scope;
begin
   Set_Empty_List (This, Name, Within);
   while Next_Row (From) loop
      Item := Add_Item (This, Name, Within);
      for Column in 1 .. Column_Count (From) loop
         declare
            Key : constant UTF8_String := UTF8_String (Column_Name (From, Column));
         begin
            if Is_Null (From, Column) then
               Set (This, Key, False, Within => Item);
            else
               Set (This, Key, Text (From, Column), Within => Item);
            end if;
         end;
      end loop;
   end loop;
end Sparrow.Templates.Bindings.Add_Rows;
