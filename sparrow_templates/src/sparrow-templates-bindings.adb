with Ada.Unchecked_Deallocation;
with Sparrow.Encoding;

package body Sparrow.Templates.Bindings is

   procedure Free is new Ada.Unchecked_Deallocation (Binding_List, Binding_List_Access);

   function Named (Item : Binding; Within : Scope; Name : UTF8_String) return Boolean is
     (Item.Owner = Within and then Item.Name /= null and then Item.Name.all = String (Name));

   --  The binding of Name in Within that is not a list item; 0 when there is none.
   function Find (This : Binding_Set; Within : Scope; Name : UTF8_String) return Natural is begin
      for Index in 1 .. This.Total loop
         if Named (This.Items (Index), Within, Name) and then This.Items (Index).Kind /= Item_Binding then
            return Index;
         end if;
      end loop;
      return 0;
   end Find;

   procedure Append (This : in out Binding_Set; Item : Binding) is begin
      if This.Items = null or else This.Total = This.Items'Last then
         declare
            Larger : constant Binding_List_Access :=
              new Binding_List (1 .. (if This.Items = null then 32 else 2 * This.Items'Last));
         begin
            if This.Items /= null then
               Larger (1 .. This.Total) := This.Items (1 .. This.Total);
               Free (This.Items);
            end if;
            This.Items := Larger;
         end;
      end if;
      This.Total := This.Total + 1;
      This.Items (This.Total) := Item;
   end Append;

   --  Drop every binding of Name in Within: the one replacing them follows.
   procedure Forget (This : in out Binding_Set; Within : Scope; Name : UTF8_String) is
      Kept : Natural := 0;
   begin
      for Index in 1 .. This.Total loop
         if Named (This.Items (Index), Within, Name) then
            Free (This.Items (Index).Name);
            Free (This.Items (Index).Text);
         else
            Kept := Kept + 1;
            This.Items (Kept) := This.Items (Index);
         end if;
      end loop;
      This.Total := Kept;
   end Forget;

   procedure Set (This : in out Binding_Set; Name : UTF8_String; Value : UTF8_String; Within : Scope := Top_Scope)
   is begin
      Forget (This, Within, Name);
      Append (This, (Owner => Within, Name => new String'(String (Name)), Kind => Text_Binding,
                     Text => new String'(String (Value)), others => <>));
   end Set;

   procedure Set
     (This : in out Binding_Set; Name : UTF8_String; Value : Long_Long_Integer; Within : Scope := Top_Scope)
   is begin
      Set (This, Name, Encoding.To_UTF8 (Encoding.Decimal_Image (Value)), Within);
   end Set;

   procedure Set (This : in out Binding_Set; Name : UTF8_String; Value : Boolean; Within : Scope := Top_Scope) is
   begin
      Forget (This, Within, Name);
      Append (This, (Owner => Within, Name => new String'(String (Name)), Kind => Flag_Binding, Flag => Value,
                     others => <>));
   end Set;

   function Add_Item (This : in out Binding_Set; Name : UTF8_String; Within : Scope := Top_Scope) return Scope is
      Existing : constant Natural := Find (This, Within, Name);
   begin
      if Existing /= 0 then   --  something else of that name (an empty list among them) gives way to the list
         Forget (This, Within, Name);
      end if;
      This.Scope_Total := This.Scope_Total + 1;
      Append (This, (Owner => Within, Name => new String'(String (Name)), Kind => Item_Binding,
                     Child => This.Scope_Total, others => <>));
      return This.Scope_Total;
   end Add_Item;

   procedure Set_Empty_List (This : in out Binding_Set; Name : UTF8_String; Within : Scope := Top_Scope) is begin
      Forget (This, Within, Name);
      Append (This, (Owner => Within, Name => new String'(String (Name)), Kind => Empty_List_Binding,
                     others => <>));
   end Set_Empty_List;

   function Add_Object (This : in out Binding_Set; Name : UTF8_String; Within : Scope := Top_Scope) return Scope is
   begin
      Forget (This, Within, Name);
      This.Scope_Total := This.Scope_Total + 1;
      Append (This, (Owner => Within, Name => new String'(String (Name)), Kind => Object_Binding,
                     Child => This.Scope_Total, others => <>));
      return This.Scope_Total;
   end Add_Object;

   procedure Clear (This : in out Binding_Set) is begin
      for Index in 1 .. This.Total loop
         Free (This.Items (Index).Name);
         Free (This.Items (Index).Text);
      end loop;
      This.Total       := 0;
      This.Scope_Total := Top_Scope;
   end Clear;

   procedure Free (This : in out Binding_Set) is begin
      Clear (This);
      Free (This.Items);
   end Free;

   overriding function Kind_Of (This : Binding_Set; Within : Scope; Name : UTF8_String) return Value_Kind is
   begin
      if Name = "." then
         return Object;
      end if;
      for Index in 1 .. This.Total loop
         declare
            Item : Binding renames This.Items (Index);
         begin
            if Named (Item, Within, Name) then
               return (case Item.Kind is
                          when Text_Binding                      => Scalar,
                          when Flag_Binding                      => (if Item.Flag then True_Value else False_Value),
                          when Item_Binding | Empty_List_Binding => List,
                          when Object_Binding                    => Object);
            end if;
         end;
      end loop;
      return Absent;
   end Kind_Of;

   overriding procedure Append_Value (This : Binding_Set; Within : Scope; Name : UTF8_String; To : in out Buffer) is
      Index : constant Natural := Find (This, Within, Name);
   begin
      if Index /= 0 and then This.Items (Index).Kind = Text_Binding then
         Append (To, This.Items (Index).Text.all);
      end if;
   end Append_Value;

   overriding function Item_Count (This : Binding_Set; Within : Scope; Name : UTF8_String) return Natural is
      Count : Natural := 0;
   begin
      for Index in 1 .. This.Total loop
         if Named (This.Items (Index), Within, Name) then
            case This.Items (Index).Kind is
               when Item_Binding   => Count := Count + 1;
               when Object_Binding => return 1;
               when others         => null;
            end case;
         end if;
      end loop;
      return Count;
   end Item_Count;

   overriding function Item (This : Binding_Set; Within : Scope; Name : UTF8_String; Index : Positive) return Scope is
      Seen : Natural := 0;
   begin
      for Position in 1 .. This.Total loop
         declare
            Each : Binding renames This.Items (Position);
         begin
            if Named (Each, Within, Name) and then Each.Kind in Item_Binding | Object_Binding then
               Seen := Seen + 1;
               if Seen = Index then
                  return Each.Child;
               end if;
            end if;
         end;
      end loop;
      return Within;
   end Item;

   overriding procedure Finalize (This : in out Set_Guard) is begin
      Free (This.Owner.all);
   end Finalize;

end Sparrow.Templates.Bindings;
