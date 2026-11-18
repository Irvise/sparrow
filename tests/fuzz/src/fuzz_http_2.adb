--  A client's bytes to an HTTP/2 session, after the preface and an empty SETTINGS: the input is cut into reads
--  where its bytes say (the first byte of each read gives its length), and the session is answered as the server
--  answers it, every request with a small body.
--
--  Properties: nothing raises (contracts are checked: -gnata); a read is never said to be used past its end;
--  after a connection error nothing more is read; what the session sends is whole frames no larger than 16 KiB,
--  and every header block in it decodes on its own (the encoder keeps no table).
with Fuzz_Driver; use Fuzz_Driver;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Http.Hpack;
with Sparrow.Http.Http_2; use Sparrow.Http.Http_2;
with Sparrow.Http.Parser;
with Sparrow.Times;

procedure Fuzz_Http_2 is

   use type Sparrow.Http.Hpack.Outcome;

   Limits : constant Sparrow.Http.Parser.Limits :=
     (Max_Head_Length => 2048, Max_Body_Length => 4096, Max_Streamed_Length => 8192);

   --  Output is whole frames, each at most 16 KiB, and its header blocks decode.
   procedure Check_Output (Output : Buffer) is
      Text     : constant String := Content (Output);
      Position : Natural := Text'First;
      Block    : Buffer;
   begin
      while Position <= Text'Last loop
         Check (Text'Last - Position + 1 >= 9, "the output is whole frames");
         declare
            Length : constant Natural := Character'Pos (Text (Position)) * 65_536
              + Character'Pos (Text (Position + 1)) * 256 + Character'Pos (Text (Position + 2));
            Kind   : constant Natural := Character'Pos (Text (Position + 3));
            Flags  : constant Natural := Character'Pos (Text (Position + 4));
         begin
            Check (Length <= Frame_Size and then Text'Last - Position + 1 - 9 >= Length,
                   "every frame is whole and at most 16 KiB");
            if Kind in 1 | 9 then   --  HEADERS, CONTINUATION
               Append (Block, Text (Position + 9 .. Position + 8 + Length));
               if Flags / 4 mod 2 = 1 then
                  declare
                     Table  : Sparrow.Http.Hpack.Decoder := Sparrow.Http.Hpack.New_Decoder;
                     Names  : String (1 .. 65_536);
                     Last   : Natural;
                     Fields : Sparrow.Http.Hpack.Field_Array (1 .. 256);
                     Count  : Natural;
                     Result : Sparrow.Http.Hpack.Outcome;
                     Whole  : constant String (1 .. Block.Length) := Content (Block);
                  begin
                     Sparrow.Http.Hpack.Decode (Table, Whole, Names, Last, Fields, Count, Result);
                     Check (Result = Sparrow.Http.Hpack.Decoded, "every header block the server sends decodes");
                  end;
                  Clear (Block);
               end if;
            end if;
            Position := Position + 9 + Length;
         end;
      end loop;
      Free (Block);
   end Check_Output;

   procedure Answer (This : in out Session; Output : in out Buffer) is
      Item : Event;
      Into : Buffer;
   begin
      loop
         Next_Event (This, Item);
         exit when Item.Kind = No_Event;
         if Holds (This, Item.Place, Item.Stream) then
            case Item.Kind is
               when Head_Ready =>
                  Check (Head (This, Item.Place)'Length > 0, "a head is never empty");
                  if Item.Stream mod 4 = 1 then
                     Buffer_Body (This, Item.Place, Output);
                  else
                     Stream_Body (This, Item.Place);
                  end if;
               when Request_Ready | Refused =>
                  if Item.Kind = Request_Ready then
                     Take_Request (This, Item.Place, Into);
                     declare
                        Text : constant String (1 .. Into.Length) := Content (Into);
                        Head : constant Sparrow.Http.Parser.Request_Head :=
                          Sparrow.Http.Parser.Parse_Head (Text, Limits);
                        pragma Unreferenced (Head);
                     begin
                        null;   --  the parser decides; it must not fail
                     end;
                  end if;
                  Clear (Into);
                  Append (Into, "answer");
                  Respond (This, Item.Place, 200, "Content-Type: text/plain" & ASCII.CR & ASCII.LF, Into, 6,
                           Finished => Item.Stream mod 8 /= 7, Output => Output);
                  if Item.Stream mod 8 = 7 then
                     Push (This, Item.Place, "more");
                     Finish (This, Item.Place);
                  end if;
               when Body_Ready =>
                  Take_Body (This, Item.Place, Received (This, Item.Place)'Length, Output);
                  if Body_Ended (This, Item.Place) or else Body_Too_Long (This, Item.Place) then
                     Clear (Into);
                     Respond (This, Item.Place, 200, "", Into, 0, Finished => True, Output => Output);
                  end if;
               when Stream_Reset | No_Event =>
                  null;
            end case;
         end if;
      end loop;
      Free (Into);
   end Answer;

   procedure Test (Input : String) is
      This     : Session;
      Output   : Buffer;
      Pending  : Buffer;   --  bytes read and not yet used
      Position : Natural := Input'First;
      Used     : Natural;
      Now      : Sparrow.Times.Milliseconds := 0;
      use type Sparrow.Times.Milliseconds;
   begin
      Start (This, Limits, Output);
      Append (Pending, Preface & ASCII.NUL & ASCII.NUL & ASCII.NUL & Character'Val (4) & ASCII.NUL
              & ASCII.NUL & ASCII.NUL & ASCII.NUL & ASCII.NUL);
      while Position <= Input'Last loop
         declare
            Length : constant Natural := Character'Pos (Input (Position)) * 4 + 1;
            Last   : constant Natural := Natural'Min (Input'Last, Position + Length);
         begin
            Append (Pending, Input (Position + 1 .. Last));
            Position := Last + 1;
         end;
         declare
            Text      : constant String (1 .. Pending.Length) := Content (Pending);
            Was_Failed : constant Boolean := Failed (This);
         begin
            Receive (This, Text, Now, Used, Output);
            Check (Used <= Text'Length, "never more used than read");
            Check (not Was_Failed or else Used = 0, "nothing is read after a connection error");
            Consume (Pending, Used);
         end;
         Answer (This, Output);
         Fill (This, Output, 1_000_000);
         Now := Now + 7;
      end loop;
      Check_Output (Output);
      Free (This);
      Free (Output);
      Free (Pending);
   end Test;

   procedure Fuzz is new Run (Test);

begin
   Fuzz;
end Fuzz_Http_2;
