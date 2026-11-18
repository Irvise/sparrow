--  What the outbound client reads from a server, or anyone in its place: response heads, and the URLs a redirect
--  names.
--
--  Properties: a complete head parses the same from exactly its own bytes, and is not complete one byte short;
--  every header value found lies inside the head; a URL accepted has a host of a name or an address and a target
--  without spaces or control bytes; nothing raises (contracts are checked: -gnata).
with Fuzz_Driver; use Fuzz_Driver;
with Sparrow.Client_Wire; use Sparrow.Client_Wire;
with Sparrow.Encoding; use Sparrow.Encoding;

procedure Fuzz_Http_Response is

   procedure Test (Input : String) is
      Head : constant Response_Head := Parse_Head (Input, Asked_Head => False, Max_Head_Length => 4096);
      Url  : constant Url_Parts := Split_Url (Input);
   begin
      if Head.Outcome = Complete then
         declare
            Own   : constant Response_Head :=
              Parse_Head (Input (Input'First .. Input'First - 1 + Head.Head_Length), False, 4096);
            Short : constant Response_Head :=
              Parse_Head (Input (Input'First .. Input'First - 2 + Head.Head_Length), False, 4096);
         begin
            Check (Own.Outcome = Complete
                   and then Own.Head_Length = Head.Head_Length
                   and then Own.Status = Head.Status
                   and then Own.Framing = Head.Framing
                   and then Own.Header_Total = Head.Header_Total,
                   "a complete head parses the same from its own bytes");
            Check (Short.Outcome /= Complete, "a head one byte short is not complete");
            for Index in 1 .. Head.Header_Total loop
               Check (Within (Header_Value (Input, Head, Slice (Input, Head.Headers (Index).Name)), Input),
                      "every header value lies inside the head");
            end loop;
         end;
      end if;

      if Url.Valid then
         Check ((for all Symbol of Slice (Input, Url.Host) =>
                   Symbol in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | ':'),
                "an accepted host is a name or an address");
         Check ((for all Symbol of Slice (Input, Url.Target) =>
                   Symbol > ' ' and then Symbol /= Character'Val (127)),
                "an accepted target has no space or control byte");
      end if;
   end Test;

   procedure Fuzz is new Run (Test);

begin
   Fuzz;
end Fuzz_Http_Response;
