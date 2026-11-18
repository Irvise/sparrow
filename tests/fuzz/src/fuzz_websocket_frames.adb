--  WebSocket frames from clients, read one after another as the server reads its input.
--
--  Properties: no frame head or payload is read outside the input; a frame re-encoded (shortest length form,
--  same mask) reads back with the same head and payload.
with Fuzz_Driver; use Fuzz_Driver;
with Interfaces; use Interfaces;
with Sparrow.Http.Frames; use Sparrow.Http.Frames;

procedure Fuzz_Websocket_Frames is

   Largest : constant := 65_536;

   --  A client frame as RFC 6455 5.2 writes it, with Payload masked by Mask.
   function Encoded (Final : Boolean; Kind : Opcode; Mask : String; Payload : String) return String is
      Length : constant Natural := Payload'Length;
      Masked : String (1 .. Length);

      function Byte (Value : Natural) return Character is (Character'Val (Value mod 256));

      Size : constant String :=
        (if Length <= 125 then [1 => Byte (128 + Length)]
         elsif Length <= 65_535 then [Byte (128 + 126), Byte (Length / 256), Byte (Length)]
         else [Byte (128 + 127), Byte (0), Byte (0), Byte (0), Byte (0),
               Byte (Length / 2 ** 24), Byte (Length / 2 ** 16), Byte (Length / 256), Byte (Length)]);
   begin
      for Index in Masked'Range loop
         Masked (Index) := Character'Val (Unsigned_8 (Character'Pos (Payload (Payload'First + Index - 1)))
                                          xor Unsigned_8 (Character'Pos (Mask (Mask'First + (Index - 1) mod 4))));
      end loop;
      return Byte ((if Final then 128 else 0) + Kind) & Size & Mask & Masked;
   end Encoded;

   procedure Test (Input : String) is
      Data : constant String (1 .. Input'Length) := Input;
      Next : Positive := 1;
   begin
      loop
         declare
            Rest : constant String (1 .. Data'Last - Next + 1) := Data (Next .. Data'Last);
            Head : constant Frame_Head := Read_Head (Rest, Largest);
         begin
            exit when Head.Outcome /= Whole_Head or else Total_Length (Head) > Rest'Length;
            declare
               Payload : constant String := Unmasked (Rest, Head);
               Mask    : constant String := Rest (Head.Payload_First - 4 .. Head.Payload_First - 1);
               Again   : constant String := Encoded (Head.Final, Head.Kind, Mask, Payload);
               Reread  : constant Frame_Head := Read_Head (Again, Largest);
            begin
               Check (Reread.Outcome = Whole_Head
                      and then Reread.Final = Head.Final
                      and then Reread.Kind = Head.Kind
                      and then Reread.Payload_Length = Head.Payload_Length
                      and then Total_Length (Reread) = Again'Length
                      and then Unmasked (Again, Reread) = Payload,
                      "a frame re-encoded reads back the same");
            end;
            exit when Total_Length (Head) >= Rest'Length;
            Next := Next + Total_Length (Head);
         end;
      end loop;
   end Test;

   procedure Fuzz is new Run (Test);

begin
   Fuzz;
end Fuzz_Websocket_Frames;
