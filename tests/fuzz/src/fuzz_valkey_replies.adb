--  Valkey's replies (RESP2), as a server or anyone in its place might send them.
--
--  Properties: a complete reply is waited for when any byte of it is missing, and reads, element by element,
--  to exactly its own length; nothing raises (contracts are checked: -gnata).
with Fuzz_Driver; use Fuzz_Driver;
with Sparrow.Valkey_Protocol; use Sparrow.Valkey_Protocol;

procedure Fuzz_Valkey_Replies is

   procedure Test (Input : String) is
      Found : constant Scan_Result := Scan (Input);
   begin
      if Found.Outcome /= Complete then
         return;
      end if;
      declare
         Reply    : String renames Input (Input'First .. Input'First + Found.Length - 1);
         Position : Positive := Reply'First;
         Shorter  : constant Scan_Result := Scan (Reply (Reply'First .. Reply'Last - 1));
         Half     : constant Scan_Result := Scan (Reply (Reply'First .. Reply'First + Found.Length / 2 - 1));
      begin
         Check (Shorter.Outcome = Waiting and then Half.Outcome = Waiting,
                "a reply missing any of its bytes is waited for");
         Check (Scan (Reply) = Found, "a reply scans the same without what follows it");
         while Position <= Reply'Last loop
            declare
               Item : constant Element := Element_At (Reply, Position);
            begin
               Check (Item.Kind not in Incomplete | Malformed and then Item.Next > Position,
                      "every element of a complete reply reads");
               Position := Item.Next;
            end;
         end loop;
         Check (Position = Reply'Last + 1, "the elements end where the reply ends");
      end;
   end Test;

   procedure Fuzz is new Run (Test);

begin
   Fuzz;
end Fuzz_Valkey_Replies;
