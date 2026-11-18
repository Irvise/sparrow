package body Sparrow.Json.Builders is

   use Writers;

   function Well_Formed (This : Builder) return Boolean is (Well_Formed (This.State));
   function Complete (This : Builder) return Boolean is (Complete (This.State));

   procedure Begin_Object (This : in out Builder) is begin
      Begin_Object (This.State, This.Into.all);
   end Begin_Object;

   procedure End_Object (This : in out Builder) is begin
      End_Object (This.State, This.Into.all);
   end End_Object;

   procedure Begin_Array (This : in out Builder) is begin
      Begin_Array (This.State, This.Into.all);
   end Begin_Array;

   procedure End_Array (This : in out Builder) is begin
      End_Array (This.State, This.Into.all);
   end End_Array;

   procedure Key (This : in out Builder; Name : UTF8_String) is begin
      Key (This.State, This.Into.all, Name);
   end Key;

   procedure Value (This : in out Builder; Text : UTF8_String) is begin
      Value (This.State, This.Into.all, Text);
   end Value;

   procedure Value (This : in out Builder; Number : Long_Long_Integer) is begin
      Value (This.State, This.Into.all, Number);
   end Value;

   procedure Value (This : in out Builder; Number : Long_Float) is begin
      Value (This.State, This.Into.all, Number);
   end Value;

   procedure Value (This : in out Builder; Flag : Boolean) is begin
      Value (This.State, This.Into.all, Flag);
   end Value;

   procedure Null_Value (This : in out Builder) is begin
      Null_Value (This.State, This.Into.all);
   end Null_Value;

   procedure Raw_Value (This : in out Builder; Fragment : UTF8_String) is begin
      Raw_Value (This.State, This.Into.all, Fragment);
   end Raw_Value;

   procedure Member (This : in out Builder; Name : UTF8_String; Text : UTF8_String) is begin
      Key (This, Name);
      Value (This, Text);
   end Member;

   procedure Member (This : in out Builder; Name : UTF8_String; Number : Long_Long_Integer) is begin
      Key (This, Name);
      Value (This, Number);
   end Member;

   procedure Member (This : in out Builder; Name : UTF8_String; Number : Long_Float) is begin
      Key (This, Name);
      Value (This, Number);
   end Member;

   procedure Member (This : in out Builder; Name : UTF8_String; Flag : Boolean) is begin
      Key (This, Name);
      Value (This, Flag);
   end Member;

   procedure Null_Member (This : in out Builder; Name : UTF8_String) is begin
      Key (This, Name);
      Null_Value (This);
   end Null_Member;

end Sparrow.Json.Builders;
