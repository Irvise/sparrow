--  WSAPoll: the poller keeps its own watch list and reports states (level-triggered). The Waker is a loopback
--  socket pair; the console's Ctrl-C, Ctrl-Break and close events are termination requests.
--
--  UNTESTED: written from the Windows SDK headers, compiled but never run (no Windows machine was at hand).
with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Sparrow.IO.Winsock; use Sparrow.IO.Winsock;
with System;

package body Sparrow.IO.Events with SPARK_Mode => Off is

   type Watch_Entry is record
      Item   : Descriptor := No_Descriptor;
      Wanted : Interest := (Readable => False, Writable => False);
   end record;

   type Watch_Array is array (Positive range <>) of Watch_Entry;
   type Watch_Array_Access is access Watch_Array;

   type Watch_List is record
      Items  : Watch_Array_Access;
      Total  : Natural := 0;
      Cursor : Natural := 0;   --  where the next Wait starts reporting, so no descriptor is always last
   end record;

   procedure Free is new Ada.Unchecked_Deallocation (Watch_Array, Watch_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Watch_List, Watch_List_Access);

   --  WSAPOLLFD
   type Poll_Entry is record
      Socket   : Socket_Handle;
      Events   : Unsigned_16;
      Returned : Unsigned_16;
   end record with Convention => C;

   type Poll_Array is array (Positive range <>) of Poll_Entry with Convention => C;

   POLLERR    : constant Unsigned_16 := 16#0001#;
   POLLHUP    : constant Unsigned_16 := 16#0002#;
   POLLNVAL   : constant Unsigned_16 := 16#0004#;
   POLLWRNORM : constant Unsigned_16 := 16#0010#;
   POLLRDNORM : constant Unsigned_16 := 16#0100#;

   function WSAPoll (Entries : System.Address; Count : unsigned_long; Timeout : int) return int
      with Import, Convention => Stdcall, External_Name => "WSAPoll";

   function Failed return Error is
      Result : Error := Last_Failure;
   begin
      if Result.Kind = None then
         Result.Kind := Other;
      end if;
      return Result;
   end Failed;

   function Reports_Changes return Boolean is (False);

   procedure Open (This : in out Poller; Failure : out Error) is begin
      This.Watched := new Watch_List'(Items => new Watch_Array (1 .. 64), Total => 0, Cursor => 0);
      This.Open    := True;
      Failure      := No_Error;
   end Open;

   procedure Close (This : in out Poller) is begin
      if This.Watched /= null then
         Free (This.Watched.Items);
         Free (This.Watched);
      end if;
      This.Open := False;
   end Close;

   function Position_Of (List : Watch_List; Item : Descriptor) return Natural is begin
      for Index in 1 .. List.Total loop
         if List.Items (Index).Item = Item then
            return Index;
         end if;
      end loop;
      return 0;
   end Position_Of;

   procedure Watch (This : in out Poller; Item : Descriptor; Wanted : Interest := (others => <>)) is
      List : Watch_List renames This.Watched.all;
   begin
      if Position_Of (List, Item) /= 0 then
         Rewatch (This, Item, Wanted);
         return;
      end if;
      if List.Total = List.Items'Last then
         declare
            Larger : constant Watch_Array_Access := new Watch_Array (1 .. 2 * List.Items'Last);
         begin
            Larger (1 .. List.Total) := List.Items (1 .. List.Total);
            Free (List.Items);
            List.Items := Larger;
         end;
      end if;
      List.Total := List.Total + 1;
      List.Items (List.Total) := (Item => Item, Wanted => Wanted);
   end Watch;

   procedure Rewatch (This : in out Poller; Item : Descriptor; Wanted : Interest) is
      Position : constant Natural := Position_Of (This.Watched.all, Item);
   begin
      if Position /= 0 then
         This.Watched.Items (Position).Wanted := Wanted;
      end if;
   end Rewatch;

   procedure Unwatch (This : in out Poller; Item : Descriptor) is
      List     : Watch_List renames This.Watched.all;
      Position : constant Natural := Position_Of (List, Item);
   begin
      if Position /= 0 then
         List.Items (Position) := List.Items (List.Total);   --  order does not matter
         List.Total := List.Total - 1;
      end if;
   end Unwatch;

   procedure Wait (This : in out Poller; Into : in out Event_Array; Timeout : Milliseconds; Count : out Natural) is
      List    : Watch_List renames This.Watched.all;
      Entries : Poll_Array (1 .. Natural'Max (List.Total, 1));
      Used    : Natural := 0;
      Got     : int;
   begin
      Count := 0;
      --  Only what is wanted goes to WSAPoll: an entry asking for nothing is an error there.
      for Index in 1 .. List.Total loop
         declare
            Each   : constant Watch_Entry := List.Items (Index);
            Events : constant Unsigned_16 :=
              (if Each.Wanted.Readable then POLLRDNORM else 0) or (if Each.Wanted.Writable then POLLWRNORM else 0);
         begin
            if Events /= 0 then
               Used := Used + 1;
               Entries (Used) := (Socket => To_Handle (Each.Item), Events => Events, Returned => 0);
            end if;
         end;
      end loop;

      if Used = 0 then   --  nothing to wait on: WSAPoll would fail at once
         if Timeout /= 0 then
            delay Duration (Milliseconds'Min (Milliseconds'Max (Timeout, 0), 1_000)) / 1000;
         end if;
         return;
      end if;

      Got := WSAPoll (Entries'Address, unsigned_long (Used),
                      (if Timeout < 0 then -1 else int (Milliseconds'Min (Timeout, Milliseconds (int'Last)))));
      if Got <= 0 then
         return;   --  timed out, or failed (a closed socket in the list): an empty round either way
      end if;

      --  Report from the cursor on, wrapping, so that a busy descriptor early in the list cannot starve the rest.
      for Step in 0 .. Used - 1 loop
         exit when Count = Into'Length;
         declare
            Position : constant Positive := (List.Cursor + Step) mod Used + 1;
            Returned : constant Unsigned_16 := Entries (Position).Returned;
         begin
            if Returned /= 0 then
               Count := Count + 1;
               Into (Into'First + Count - 1) :=
                 (Item     => To_Descriptor (Entries (Position).Socket),
                  Readable => (Returned and POLLRDNORM) /= 0,
                  Writable => (Returned and POLLWRNORM) /= 0,
                  Closed   => (Returned and (POLLERR or POLLHUP or POLLNVAL)) /= 0);
            end if;
         end;
      end loop;
      List.Cursor := (List.Cursor + 1) mod Natural'Max (Used, 1);
   end Wait;

   ---------------------------------------------------------------------------------------------------------------
   --  Waker: two connected loopback sockets

   procedure Open (This : in out Waker; Failure : out Error) is
      Listener : constant Socket_Handle := C_Socket (AF_INET, SOCK_STREAM, 0);
      Where    : aliased Socket_Address := (Address => Swap_Bytes (16#7F00_0001#), others => <>);
      Length   : aliased int := Socket_Address'Size / 8;
      Client   : Socket_Handle := Invalid_Socket;
      Server   : Socket_Handle := Invalid_Socket;
   begin
      if Listener = Invalid_Socket then
         Failure := Failed;
         return;
      end if;

      if C_Bind (Listener, Where'Address, Length) = 0
        and then C_Listen (Listener, 1) = 0
        and then C_Getsockname (Listener, Where'Address, Length'Access) = 0
      then
         Client := C_Socket (AF_INET, SOCK_STREAM, 0);
         if Client /= Invalid_Socket and then C_Connect (Client, Where'Address, Socket_Address'Size / 8) = 0 then
            Server := C_Accept (Listener, System.Null_Address, System.Null_Address);
         end if;
      end if;
      Failure := (if Server = Invalid_Socket then Failed else No_Error);
      if C_Closesocket (Listener) /= 0 then
         null;
      end if;

      if Server = Invalid_Socket or else not Set_Non_Blocking (Server) or else not Set_Non_Blocking (Client) then
         if Succeeded (Failure) then
            Failure := Failed;
         end if;
         Sparrow.IO.Close (To_Descriptor (Client));
         Sparrow.IO.Close (To_Descriptor (Server));
         return;
      end if;
      This.Read_End  := To_Descriptor (Server);
      This.Write_End := To_Descriptor (Client);
   end Open;

   procedure Close (This : in out Waker) is begin
      Sparrow.IO.Close (This.Read_End);
      Sparrow.IO.Close (This.Write_End);
      This.Read_End  := No_Descriptor;
      This.Write_End := No_Descriptor;
   end Close;

   procedure Poke (Socket : Socket_Handle) is
      Byte : aliased Character := 'w';
   begin
      if C_Send (Socket, Byte'Address, 1, 0) < 0 then
         null;   --  a full socket buffer is already signalled
      end if;
   end Poke;

   procedure Signal (This : Waker) is begin
      Poke (To_Handle (This.Write_End));
   end Signal;

   procedure Drain (This : Waker) is
      Bytes : aliased String (1 .. 256);
   begin
      while C_Recv (To_Handle (This.Read_End), Bytes'Address, Bytes'Length, 0) > 0 loop
         null;
      end loop;
   end Drain;

   Termination_Socket : Socket_Handle := Invalid_Socket with Atomic;

   --  Runs on a thread the system starts for the console event.
   function On_Console_Event (Kind : unsigned_long) return int with Convention => Stdcall;

   function On_Console_Event (Kind : unsigned_long) return int is
      Socket : constant Socket_Handle := Termination_Socket;
   begin
      if Kind in 0 .. 2 and then Socket /= Invalid_Socket then   --  Ctrl-C, Ctrl-Break, the window closing
         Poke (Socket);
         return 1;   --  handled: the process is not ended for it
      end if;
      return 0;
   end On_Console_Event;

   function SetConsoleCtrlHandler (Handler : System.Address; Add : int) return int
      with Import, Convention => Stdcall, External_Name => "SetConsoleCtrlHandler";

   procedure Signal_On_Termination (This : Waker) is begin
      Termination_Socket := To_Handle (This.Write_End);
      if SetConsoleCtrlHandler (On_Console_Event'Address, 1) = 0 then
         null;   --  no console: nothing to catch
      end if;
   end Signal_On_Termination;

end Sparrow.IO.Events;
