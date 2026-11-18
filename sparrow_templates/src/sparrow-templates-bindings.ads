--  Template data set by hand: names bound to text, flags, and lists of items that hold bindings of their own.
--
--     Set (Page, "title", "Articles");
--     Set (Page, "signed_in", True);
--     for Each of Articles loop
--        Row := Add_Item (Page, "articles");
--        Set (Page, "title", Each.Title, Within => Row);
--     end loop;
--
--  Meant for a page's worth of values: lookups scan the bindings. Declare one in the handler (it frees itself
--  when it goes out of scope), or keep one per worker and Clear it for each response.
private with Ada.Finalization;

package Sparrow.Templates.Bindings is

   type Binding_Set is limited new Data_Source with private;

   Top_Scope : constant Scope := 0;

   --  Bind Name inside Within, replacing what it was bound to.
   procedure Set (This : in out Binding_Set; Name : UTF8_String; Value : UTF8_String; Within : Scope := Top_Scope);
   procedure Set
     (This : in out Binding_Set; Name : UTF8_String; Value : Long_Long_Integer; Within : Scope := Top_Scope);
   procedure Set (This : in out Binding_Set; Name : UTF8_String; Value : Boolean; Within : Scope := Top_Scope);

   --  Append an item to the list Name inside Within (making the list on first use); the result is the item's
   --  scope, to Set its values in.
   function Add_Item (This : in out Binding_Set; Name : UTF8_String; Within : Scope := Top_Scope) return Scope;

   --  Bind Name to an empty list, so a section over it renders nothing and its inverted section renders.
   procedure Set_Empty_List (This : in out Binding_Set; Name : UTF8_String; Within : Scope := Top_Scope);

   --  Bind Name to an object; the result is its scope.
   function Add_Object (This : in out Binding_Set; Name : UTF8_String; Within : Scope := Top_Scope) return Scope;

   --  Forget every binding, keeping the storage.
   procedure Clear (This : in out Binding_Set);

   --  Release the storage (done anyway when it goes out of scope).
   procedure Free (This : in out Binding_Set);

   overriding function Top (This : Binding_Set) return Scope is (Top_Scope);
   overriding function Kind_Of (This : Binding_Set; Within : Scope; Name : UTF8_String) return Value_Kind;
   overriding procedure Append_Value (This : Binding_Set; Within : Scope; Name : UTF8_String; To : in out Buffer);
   overriding function Item_Count (This : Binding_Set; Within : Scope; Name : UTF8_String) return Natural;
   overriding function Item (This : Binding_Set; Within : Scope; Name : UTF8_String; Index : Positive) return Scope;

private

   type Binding_Kind is (Text_Binding, Flag_Binding, Item_Binding, Object_Binding, Empty_List_Binding);

   --  One name in one scope. A list is its Item_Bindings, in order; each item's Child is the item's scope.
   type Binding is record
      Owner : Scope := Top_Scope;
      Name  : String_Access;
      Kind  : Binding_Kind := Text_Binding;
      Text  : String_Access;
      Flag  : Boolean := False;
      Child : Scope := Top_Scope;
   end record;

   type Binding_List is array (Positive range <>) of Binding;
   type Binding_List_Access is access Binding_List;

   type Set_Guard (Owner : not null access Binding_Set) is new Ada.Finalization.Limited_Controlled
      with null record;
   overriding procedure Finalize (This : in out Set_Guard);   --  frees Owner

   type Binding_Set is limited new Data_Source with record
      Items       : Binding_List_Access;
      Total       : Natural := 0;
      Scope_Total : Scope := Top_Scope;   --  the last scope handed out
      Guard       : Set_Guard (Binding_Set'Access);
   end record;

end Sparrow.Templates.Bindings;
