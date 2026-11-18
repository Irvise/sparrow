with Ada.Calendar;
with Ada.Calendar.Formatting;
with Interfaces; use Interfaces;
with Sparrow.Crypto;
with Sparrow.Crypto.Random;
with Sparrow.Http.Requests;

package body Sparrow.Http.Spans is

   use type Ada.Calendar.Time;

   Unix_Epoch : constant Ada.Calendar.Time := Ada.Calendar.Formatting.Time_Of (1970, 1, 1, 0.0, Time_Zone => 0);

   function Now return Unix_Nanoseconds is
     (Unix_Nanoseconds (Duration'(Ada.Calendar.Clock - Unix_Epoch) / Duration'(0.000_000_001)));

   --  Traces whose last 14 hex digits (56 bits) fall below this are sampled.
   Full_Range : constant := 2 ** 56;

   Active_Exporter : Exporter := null with Atomic;
   Threshold       : Unsigned_64 := 0 with Atomic;

   procedure Set_Exporter (Export : Exporter; Sample_Ratio : Long_Float := 1.0) is begin
      Threshold       := Unsigned_64 (Long_Float'Floor (Sample_Ratio * Long_Float (Full_Range)));
      Active_Exporter := Export;
   end Set_Exporter;

   function Recording (Trace : Trace_Context) return Boolean is
     (Trace.Sampled and then Active_Exporter /= null);

   function Sampled_By_Ratio (Trace_Id : String) return Boolean is
      Value : Unsigned_64 := 0;
   begin
      if Threshold = 0 or else Trace_Id'Length < 14 then
         return False;
      end if;
      for Digit of Trace_Id (Trace_Id'Last - 13 .. Trace_Id'Last) loop
         Value := Value * 16 + (case Digit is
                                   when '0' .. '9' => Character'Pos (Digit) - Character'Pos ('0'),
                                   when 'a' .. 'f' => Character'Pos (Digit) - Character'Pos ('a') + 10,
                                   when 'A' .. 'F' => Character'Pos (Digit) - Character'Pos ('A') + 10,
                                   when others     => 0);
      end loop;
      return Value < Threshold;
   end Sampled_By_Ratio;

   procedure Finish (Item : Finished_Span) is
      Export : constant Exporter := Active_Exporter;
   begin
      if Export /= null and then Item.Trace.Sampled then
         Export (Item);
      end if;
   end Finish;

   procedure Put (Into : out String; Length : out Natural; Text : String) is begin
      Length := Natural'Min (Text'Length, Into'Length);
      Into := [others => ' '];
      Into (Into'First .. Into'First + Length - 1) := Text (Text'First .. Text'First + Length - 1);
   end Put;

   ---------------------------------------------------------------------------------------------------------------

   function Start (Context : Handler_Context; Name : String) return Span is
   begin
      return Result : Span do
         Result.Within := Context;
         if Recording (Context.Trace) then
            declare
               Bytes : String (1 .. 8);
            begin
               Crypto.Random.Fill (Bytes);
               Result.Within.Trace.Parent_Id := Context.Trace.Span_Id;
               Result.Within.Trace.Span_Id   := Crypto.To_Hex (Bytes);
            end;
            Result.Records      := True;
            Result.Item.Trace   := Result.Within.Trace;
            Result.Item.Kind    := Internal;
            Put (Result.Item.Name, Result.Item.Name_Length, Name);
            Result.Item.Started := Now;
         end if;
      end return;
   end Start;

   function Start (Request : Http_Request; Name : String) return Span is
     (Start (Requests.Context (Request), Name));

   procedure Fail (This : in out Span) is begin
      This.Item.Failed := True;
   end Fail;

   function Context (This : Span) return Handler_Context is (This.Within);

   overriding procedure Finalize (This : in out Span) is begin
      if This.Records then
         This.Records    := False;
         This.Item.Ended := Now;
         Finish (This.Item);
      end if;
   end Finalize;

end Sparrow.Http.Spans;
