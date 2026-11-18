--  A JSON writer bound to the buffer it writes into, so calls name only what they write:
--
--     Responses.Begin_Content (Response, OK, Application_Json);
--     declare
--        Json : Builders.Builder (Response.Content'Access);
--     begin
--        Json.Begin_Object;
--        Json.Member ("id", 42);
--        Json.Member ("title", Title);
--        Json.Key ("tags");
--        Json.Begin_Array;
--        ...
--     end;
--
--  The same rules as Sparrow.Json.Writers, which it wraps: a call that does not fit the structure writes
--  nothing and clears Well_Formed. Writers stays for proved code; this is a thin layer over it.
with Sparrow.Buffers; use Sparrow.Buffers;
private with Sparrow.Json.Writers;

package Sparrow.Json.Builders with SPARK_Mode => Off is

   type Builder (Into : not null access Buffer) is tagged limited private;

   function Well_Formed (This : Builder) return Boolean;
   function Complete (This : Builder) return Boolean;   --  one whole value written

   procedure Begin_Object (This : in out Builder);
   procedure End_Object (This : in out Builder);
   procedure Begin_Array (This : in out Builder);
   procedure End_Array (This : in out Builder);

   procedure Key (This : in out Builder; Name : UTF8_String);

   procedure Value (This : in out Builder; Text : UTF8_String);
   procedure Value (This : in out Builder; Number : Long_Long_Integer);
   procedure Value (This : in out Builder; Number : Long_Float);   --  null when not finite
   procedure Value (This : in out Builder; Flag : Boolean);
   procedure Null_Value (This : in out Builder);

   --  Already-encoded JSON, written as it is (for example a stored document).
   procedure Raw_Value (This : in out Builder; Fragment : UTF8_String);

   --  Key then Value, inside an object.
   procedure Member (This : in out Builder; Name : UTF8_String; Text : UTF8_String);
   procedure Member (This : in out Builder; Name : UTF8_String; Number : Long_Long_Integer);
   procedure Member (This : in out Builder; Name : UTF8_String; Number : Long_Float);
   procedure Member (This : in out Builder; Name : UTF8_String; Flag : Boolean);
   procedure Null_Member (This : in out Builder; Name : UTF8_String);

private

   type Builder (Into : not null access Buffer) is tagged limited record
      State : Writers.Writer;
   end record;

end Sparrow.Json.Builders;
