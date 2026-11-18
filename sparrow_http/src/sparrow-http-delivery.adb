with Ada.Unchecked_Deallocation;

package body Sparrow.Http.Delivery is

   procedure Deallocate is new Ada.Unchecked_Deallocation (Job, Job_Access);

   procedure Free (Item : in out Job_Access) is begin
      if Item /= null then
         Requests.Free (Item.Request);
         Responses.Free (Item.Response);
         Free (Item.Data);
         Deallocate (Item);
      end if;
   end Free;

   function Id_Of (Item : Job) return Connection_Id is
     ((Reactor => Item.Reactor, Slot => Item.Slot, Generation => Item.Generation, Stream => Item.Stream));

   protected body Mailbox is

      procedure Push (Item : in out Job_Access) is begin
         Item.Next := null;
         if Last = null then
            First := Item;
         else
            Last.Next := Item;
         end if;
         Last := Item;
         Item := null;
      end Push;

      procedure Take_All (Chain : out Job_Access) is begin
         Chain := First;
         First := null;
         Last  := null;
      end Take_All;

   end Mailbox;

   procedure Post (Item : in out Job_Access) is
      Boxes  : constant Mailbox_Array_Access := Mailboxes;
      Alarms : constant Waker_Array_Access := Wakers;
   begin
      if Boxes = null or else Alarms = null or else Item.Reactor not in Boxes'Range then
         Free (Item);
         return;
      end if;
      declare
         Reactor : constant Reactor_Index := Item.Reactor;
      begin
         Boxes (Reactor).Push (Item);
         if IO.Events.Is_Open (Alarms (Reactor)) then
            IO.Events.Signal (Alarms (Reactor));
         end if;
      end;
   end Post;

   function Is_Live (Id : Connection_Id) return Boolean is
      Table : constant Live_Table_Access := Live;
   begin
      return Table /= null and then Id.Reactor in Table'Range and then Table (Id.Reactor) /= null
        and then Id.Slot in Table (Id.Reactor)'Range
        and then Natural (Table (Id.Reactor) (Id.Slot)) = Id.Generation + 1
        and then (Id.Stream = 0 or else Lane_Of (Id) /= 0);
   end Is_Live;

   function Lane_Of (Id : Connection_Id) return Natural is
      Table : constant Lane_Table_Access := Lanes;
      Slots : Lane_Slots_Access;
      Found : Lane_Access;
   begin
      if Id.Stream = 0 or else Table = null or else Id.Reactor not in Table'Range then
         return 0;
      end if;
      Slots := Table (Id.Reactor);
      if Slots = null or else Id.Slot not in Slots'Range then
         return 0;
      end if;
      Found := Slots (Id.Slot);
      if Found = null then
         return 0;
      end if;
      for Place in Found.Streams'Range loop
         if Natural (Found.Streams (Place)) = Id.Stream then
            return Place;
         end if;
      end loop;
      return 0;
   end Lane_Of;

   function Register (Item : Endpoint_Entry) return Positive is begin
      if Endpoint_Total = Max_Endpoints then
         raise Program_Error with "more than" & Max_Endpoints'Image & " WebSocket endpoints";
      end if;
      Endpoint_Total := Endpoint_Total + 1;
      Endpoints (Endpoint_Total) := Item;
      return Endpoint_Total;
   end Register;

   ---------------
   -- Body_Pipe --
   ---------------

   protected body Body_Pipe is

      procedure Open (Generation : Natural; Stream : Natural := 0) is begin
         First   := 1;
         Length  := 0;
         Current := Flowing;
         Why     := Client_Closed;
         Owner   := Generation;
         Owner_Stream := Stream;
         Waiting := False;
      end Open;

      procedure Put (Data : String; Taken : out Natural) is
         Room  : constant Natural := Pipe_Capacity - Length;
         Start : constant Positive := (First - 1 + Length) mod Pipe_Capacity + 1;   --  the first free byte
         Upto  : Natural;   --  how many fit before the end of the ring
      begin
         Taken := Natural'Min (Room, Data'Length);
         Upto  := Natural'Min (Taken, Pipe_Capacity - Start + 1);
         Body_Pipe.Data (Start .. Start + Upto - 1) := Data (Data'First .. Data'First + Upto - 1);
         Body_Pipe.Data (1 .. Taken - Upto) := Data (Data'First + Upto .. Data'First + Taken - 1);
         Length  := Length + Taken;
         --  Until a Take tells the reactor, which then reads the socket again: a later Put that takes it all does
         --  not mean the reactor is reading.
         Waiting := Waiting or else Taken < Data'Length;
      end Put;

      procedure Finish is begin
         if Current = Flowing then
            Current := Finished;
         end if;
      end Finish;

      procedure Break (Status : Status_Code) is begin
         if Current = Flowing then
            Current := Broken;
            Why     := Status;
         end if;
      end Break;

      entry Take
        (Generation  : Natural;
         Stream      : Natural;
         Into        : out String;
         Last        : out Natural;
         State       : out Pipe_State;
         Status      : out Status_Code;
         Wanted_More : out Boolean) when Length > 0 or else Current /= Flowing
      is
         Count : Natural;
         Upto  : Natural;
      begin
         Wanted_More := False;
         Status      := Why;
         if Generation /= Owner or else Stream /= Owner_Stream or else (Current = Broken and then Length = 0) then
            Last  := Into'First - 1;
            State := Broken;
            if Generation /= Owner or else Stream /= Owner_Stream then
               Status := Client_Closed;
            end if;
            return;
         end if;
         --  A break after the last byte arrived (the client left as the handler answered) is no break.
         Count := Natural'Min (Length, Into'Length);
         Upto  := Natural'Min (Count, Pipe_Capacity - First + 1);
         Into (Into'First .. Into'First + Upto - 1) := Data (First .. First + Upto - 1);
         Into (Into'First + Upto .. Into'First + Count - 1) := Data (1 .. Count - Upto);
         First  := (First - 1 + Count) mod Pipe_Capacity + 1;
         Length := Length - Count;
         Last   := Into'First + Count - 1;
         State  := (if Count = 0 then Current else Flowing);
         if Waiting and then Length <= Pipe_Capacity / 2 then
            Waiting     := False;
            Wanted_More := True;
         end if;
      end Take;

   end Body_Pipe;

end Sparrow.Http.Delivery;
