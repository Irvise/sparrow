with Sparrow.Crypto;
with Sparrow.Crypto.Random;

with Sparrow.Http.Requests;
with Sparrow.Http.Spans;

package body Sparrow.Http.Log is

   function Request_Id (Trace : Trace_Context) return String is (Trace.Id (1 .. Trace.Id_Length));
   function Request_Id (Context : Handler_Context) return String is (Request_Id (Context.Trace));
   function Request_Id (Request : Http_Request) return String is (Request_Id (Requests.Trace (Request)));
   function Trace_Id (Trace : Trace_Context) return String is (Trace.Trace_Id);
   function Span_Id (Trace : Trace_Context) return String is (Trace.Span_Id);
   function Parent_Id (Trace : Trace_Context) return String is (Trace.Parent_Id);

   function Trace_Fields (Trace : Trace_Context) return Fields is
     (if Trace.Id_Length = 0 then No_Fields
      elsif Request_Id (Trace) = Trace.Trace_Id then Field ("request_id", Request_Id (Trace))
      else Field ("request_id", Request_Id (Trace)) & Field ("trace_id", Trace.Trace_Id));

   procedure Debug
     (Context : Handler_Context;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields)
   is begin
      if Logs.Enabled (Logs.Debug) then
         Logs.Log (Logs.Debug, Message,
                   Trace_Fields (Context.Trace) & First & Second & Third & Fourth & Fifth & Sixth);
      end if;
   end Debug;

   procedure Info
     (Context : Handler_Context;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields)
   is begin
      if Logs.Enabled (Logs.Info) then
         Logs.Log (Logs.Info, Message,
                   Trace_Fields (Context.Trace) & First & Second & Third & Fourth & Fifth & Sixth);
      end if;
   end Info;

   procedure Warning
     (Context : Handler_Context;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields)
   is begin
      if Logs.Enabled (Logs.Warning) then
         Logs.Log (Logs.Warning, Message,
                   Trace_Fields (Context.Trace) & First & Second & Third & Fourth & Fifth & Sixth);
      end if;
   end Warning;

   procedure Error
     (Context : Handler_Context;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields)
   is begin
      if Logs.Enabled (Logs.Error) then
         Logs.Log (Logs.Error, Message,
                   Trace_Fields (Context.Trace) & First & Second & Third & Fourth & Fifth & Sixth);
      end if;
   end Error;

   procedure Debug
     (Request : Http_Request;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields)
   is begin
      Debug (Requests.Context (Request), Message, First, Second, Third, Fourth, Fifth, Sixth);
   end Debug;

   procedure Info
     (Request : Http_Request;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields)
   is begin
      Info (Requests.Context (Request), Message, First, Second, Third, Fourth, Fifth, Sixth);
   end Info;

   procedure Warning
     (Request : Http_Request;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields)
   is begin
      Warning (Requests.Context (Request), Message, First, Second, Third, Fourth, Fifth, Sixth);
   end Warning;

   procedure Error
     (Request : Http_Request;
      Message : String;
      First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields)
   is begin
      Error (Requests.Context (Request), Message, First, Second, Third, Fourth, Fifth, Sixth);
   end Error;

   function Is_Hex (Text : String) return Boolean is (for all Symbol of Text => Symbol in '0' .. '9' | 'a' .. 'f');
   function All_Zeros (Text : String) return Boolean is (for all Symbol of Text => Symbol = '0');

   --  version "00": 00-<trace-id: 32 hex>-<parent-id: 16 hex>-<flags: 2 hex>, neither id all zeros.
   function Valid_Traceparent (Text : String) return Boolean is
     (Text'Length = 55
      and then Text (Text'First .. Text'First + 2) = "00-"
      and then Text (Text'First + 35) = '-' and then Text (Text'First + 52) = '-'
      and then Is_Hex (Text (Text'First + 3 .. Text'First + 34))
      and then Is_Hex (Text (Text'First + 36 .. Text'First + 51))
      and then Is_Hex (Text (Text'First + 53 .. Text'First + 54))
      and then not All_Zeros (Text (Text'First + 3 .. Text'First + 34))
      and then not All_Zeros (Text (Text'First + 36 .. Text'First + 51)));

   function Valid_Request_Id (Text : String) return Boolean is
     (Text'Length in 1 .. Request_Id_Text'Length
      and then (for all Symbol of Text =>
                  Symbol in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | ':' | '@' | '/'));

   function Random_Hex (Byte_Count : Positive) return String is
      Bytes : String (1 .. Byte_Count);
   begin
      Crypto.Random.Fill (Bytes);
      return Crypto.To_Hex (Bytes);
   end Random_Hex;

   function Start_Trace (Request_Id_Header, Traceparent_Header : String; Trust_Callers : Boolean := True)
     return Trace_Context
   is
      Result : Trace_Context;
   begin
      Result.Span_Id := Random_Hex (8);
      if Trust_Callers and then Valid_Traceparent (Traceparent_Header) then
         declare
            Header : String renames Traceparent_Header;
            First  : constant Positive := Header'First;
         begin
            Result.Trace_Id  := Header (First + 3 .. First + 34);
            Result.Parent_Id := Header (First + 36 .. First + 51);
            Result.Sampled   := Header (First + 54) in '1' | '3' | '5' | '7' | '9' | 'b' | 'd' | 'f';
         end;
      else
         Result.Trace_Id := Random_Hex (16);
         Result.Sampled  := Spans.Sampled_By_Ratio (Result.Trace_Id);
      end if;
      if Trust_Callers and then Valid_Request_Id (Request_Id_Header) then
         Result.Id_Length := Request_Id_Header'Length;
         Result.Id (1 .. Result.Id_Length) := Request_Id_Header;
      else
         Result.Id_Length := Result.Trace_Id'Length;
         Result.Id (1 .. Result.Id_Length) := Result.Trace_Id;
      end if;
      return Result;
   end Start_Trace;

   function Trace_Headers (Request : Http_Request) return String is (Trace_Headers (Requests.Context (Request)));

   function Trace_Headers (Context : Handler_Context) return String is
      Trace : Trace_Context renames Context.Trace;
   begin
      if Trace.Id_Length = 0 then
         return "";
      end if;
      return "traceparent: 00-" & Trace.Trace_Id & "-" & Trace.Span_Id & "-" & (if Trace.Sampled then "01" else "00")
             & ASCII.LF & "X-Request-Id: " & Request_Id (Trace);
   end Trace_Headers;

end Sparrow.Http.Log;
