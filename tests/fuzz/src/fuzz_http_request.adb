--  The HTTP/1.1 head parser and the request accessors built on it.
--
--  Properties: a complete head parses the same from exactly its own bytes, and is not complete one byte
--  short; a chunked body decodes the same whole as a byte at a time, never past its limit; every accessor of
--  a loaded request returns without raising (contracts are checked: -gnata).
with Fuzz_Driver; use Fuzz_Driver;
with Sparrow.Encoding;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Http.Multipart;
with Sparrow.Http.Parser; use Sparrow.Http.Parser;
with Sparrow.Chunked; use Sparrow.Chunked;
with Sparrow.Http.Requests;

procedure Fuzz_Http_Request is

   use type Sparrow.Http.Method;
   use type Sparrow.Encoding.Span;

   type Decoding is record
      State : Decoder_State;
      Used  : Natural;     --  bytes consumed, through the body's end
      Kept  : Buffer;      --  the body
   end record;

   --  Decode Framed, Step bytes at a time as they would arrive.
   function Decoded (Framed : String; Step : Positive) return Decoding is
      Chunks   : Sparrow.Chunked.Decoder := New_Decoder (Max_Body_Length => 64, Max_Framing => 64);
      Result   : Decoding := (State => Size_Start, Used => 0, Kept => <>);
      First    : Positive := Framed'First;
      Last     : Natural;
      Consumed : Natural;
      Part     : Sparrow.Encoding.Span;
   begin
      while First <= Framed'Last and then Chunks.State not in Done | Failed loop
         Last := Natural'Min (Framed'Last, First + Step - 1);
         while First <= Last and then Chunks.State not in Done | Failed loop
            Decode (Chunks, Framed (First .. Last), Consumed, Part);
            Append (Result.Kept, Sparrow.Encoding.Slice (Framed, Part));
            First := First + Consumed;
         end loop;
      end loop;
      Check (Chunks.Decoded <= 64 and then Result.Kept.Length = Natural (Chunks.Decoded),
             "a chunked body stays within its limit");
      Result.State := Chunks.State;
      Result.Used  := First - Framed'First;
      return Result;
   end Decoded;

   procedure Test (Input : String) is
      Head : constant Request_Head := Parse_Head (Input);
   begin
      if Head.Outcome = Complete then
         declare
            Own   : constant Request_Head := Parse_Head (Input (Input'First .. Input'First - 1 + Head.Head_Length));
            Short : constant Request_Head := Parse_Head (Input (Input'First .. Input'First - 2 + Head.Head_Length));
         begin
            Check (Own.Outcome = Complete
                   and then Own.Head_Length = Head.Head_Length
                   and then Own.Verb = Head.Verb
                   and then Own.Path = Head.Path
                   and then Own.Query = Head.Query
                   and then Own.Header_Total = Head.Header_Total
                   and then Own.Body_Length = Head.Body_Length
                   and then Own.Keep_Alive = Head.Keep_Alive,
                   "a head parses the same without what follows it");
            Check (Short.Outcome /= Complete, "a head is not complete before its blank line");
            Check (Header_Value (Input, Head, "host") = Header_Value (Input, Head, "HOST"),
                   "header names compare without case");
         end;
         if Head.Chunked then
            declare
               Framed : String renames Input (Input'First + Head.Head_Length .. Input'Last);
               Whole  : Decoding := Decoded (Framed, Step => Positive'Last / 2);
               Bytes  : Decoding := Decoded (Framed, Step => 1);
            begin
               Check (Whole.State = Bytes.State and then Content (Whole.Kept) = Content (Bytes.Kept)
                      and then (Whole.State /= Done or else Whole.Used = Bytes.Used),
                      "a chunked body decodes the same whole or a byte at a time");
               Free (Whole.Kept);
               Free (Bytes.Kept);
            end;
         end if;
      end if;

      declare
         Request : Sparrow.Http.Requests.Request;
         Bytes   : Buffer;
         Valid   : Boolean;
      begin
         Append (Bytes, Input);
         Sparrow.Http.Requests.Load (Request, Bytes, Valid);
         if Valid then
            declare
               use Sparrow.Http.Requests;
               Upload      : Sparrow.Http.Multipart.Form;
               Upload_Read : Boolean;
               Unused      : Natural := 0;
               Number      : constant Long_Long_Integer := Integer_Query (Request, "n", Default => -1);
               Is_Json     : constant Boolean := Has_Content_Type (Request, "application/json");
               pragma Unreferenced (Number, Is_Json);
            begin
               Unused := Unused + Path (Request)'Length + Sparrow.Http.Requests.Header (Request, "Host")'Length
                         + Query_Value (Request, "q")'Length + Form_Value (Request, "a")'Length
                         + Cookie (Request, "session")'Length + Content (Request)'Length
                         + String (Query_Text (Request, "q", Default => "?"))'Length
                         + String (Form_Text (Request, "a", Default => "?"))'Length;
               Sparrow.Http.Multipart.Parse (Request, Upload, Upload_Read);
               if Upload_Read then
                  for Index in 1 .. Sparrow.Http.Multipart.Part_Count (Upload) loop
                     Unused := Unused + Sparrow.Http.Multipart.Name (Upload, Index)'Length
                               + Sparrow.Http.Multipart.File_Name (Upload, Index)'Length;
                  end loop;
               end if;
               pragma Unreferenced (Unused);
            end;
         end if;
         Sparrow.Http.Requests.Free (Request);
         Free (Bytes);
      end;
   end Test;

   procedure Fuzz is new Run (Test);

begin
   Fuzz;
end Fuzz_Http_Request;
