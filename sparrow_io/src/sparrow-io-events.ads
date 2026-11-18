--  Readiness events: a Poller watches descriptors and reports which can be read or written; a Waker lets
--  another task interrupt a Poller's wait.
--
--     Linux            epoll, eventfd                       reports changes
--     macOS, BSDs      kqueue, a pipe                       reports changes
--     Windows          WSAPoll, a loopback socket pair      reports states
--
--  The two kinds of report differ, and code written as below is right under both:
--    * after an event, read (or write) until Would_Block before waiting again;
--    * tolerate an event with nothing behind it;
--    * where Reports_Changes is False, a descriptor is reported for as long as it stays ready: Rewatch it
--      without Readable while its input is not wanted, and with Writable only while output is pending.
--      Where it is True those calls are unnecessary and can be skipped.
--
--  SPARK spec, system-call bodies (see Sparrow.IO).
with Sparrow.Times; use Sparrow.Times;

package Sparrow.IO.Events with SPARK_Mode is

   --  True: a descriptor is reported once each time it becomes ready (edge-triggered). False: on every Wait
   --  while it is ready (level-triggered). Fixed for a platform, so a test of it costs nothing.
   function Reports_Changes return Boolean with Global => null;

   type Interest is record
      Readable : Boolean := True;
      Writable : Boolean := False;
   end record;

   type Event is record
      Item     : Descriptor := No_Descriptor;
      Readable : Boolean := False;
      Writable : Boolean := False;
      Closed   : Boolean := False;   --  the peer hung up, or the descriptor is in error
   end record;

   type Event_Array is array (Positive range <>) of Event;

   ---------------------------------------------------------------------------------------------------------------
   --  A Poller belongs to one task.

   type Poller is limited private;

   function Is_Open (This : Poller) return Boolean;

   procedure Open (This : in out Poller; Failure : out Error)
      with Global => (In_Out => Kernel),
           Pre    => not Is_Open (This),
           Post   => Is_Open (This) = Succeeded (Failure);

   procedure Close (This : in out Poller)
      with Global => (In_Out => Kernel), Post => not Is_Open (This);

   procedure Watch (This : in out Poller; Item : Descriptor; Wanted : Interest := (others => <>))
      with Global => (In_Out => Kernel), Pre => Is_Open (This), Post => Is_Open (This);

   --  Change what a watched descriptor is watched for.
   procedure Rewatch (This : in out Poller; Item : Descriptor; Wanted : Interest)
      with Global => (In_Out => Kernel), Pre => Is_Open (This), Post => Is_Open (This);

   --  Call it before closing the descriptor.
   procedure Unwatch (This : in out Poller; Item : Descriptor)
      with Global => (In_Out => Kernel), Pre => Is_Open (This), Post => Is_Open (This);

   --  Wait for events into Into (Into'First .. Into'First + Count - 1). Timeout < 0 waits forever, 0 only
   --  polls. Count is 0 on a timeout or an interrupted wait.
   procedure Wait (This : in out Poller; Into : in out Event_Array; Timeout : Milliseconds; Count : out Natural)
      with Global => (In_Out => Kernel),
           Pre    => Is_Open (This) and then Into'Length in 1 .. 4096,
           Post   => Is_Open (This) and then Count <= Into'Length;

   ---------------------------------------------------------------------------------------------------------------
   --  A Waker is watched by one Poller and signalled by any task.

   type Waker is limited private;

   function Is_Open (This : Waker) return Boolean;

   procedure Open (This : in out Waker; Failure : out Error)
      with Global => (In_Out => Kernel),
           Pre    => not Is_Open (This),
           Post   => Is_Open (This) = Succeeded (Failure);

   procedure Close (This : in out Waker)
      with Global => (In_Out => Kernel), Post => not Is_Open (This);

   --  What to Watch; it becomes readable when signalled.
   function Watched_End (This : Waker) return Descriptor;

   procedure Signal (This : Waker) with Global => (In_Out => Kernel);

   --  Make it unreadable again (after the event was seen, before looking at whatever it announced).
   procedure Drain (This : Waker) with Global => (In_Out => Kernel);

   --  From now on the system's requests to end the process (SIGINT and SIGTERM; Ctrl-C, Ctrl-Break and a
   --  closed console on Windows) signal This instead of ending it. One Waker per process; call it before
   --  starting tasks.
   procedure Signal_On_Termination (This : Waker)
      with Global => (In_Out => Kernel), Pre => Is_Open (This);

private
   pragma SPARK_Mode (Off);

   --  Where the system keeps the watch list itself (epoll, kqueue), Handle is all there is. Where it does not
   --  (WSAPoll), the body keeps the list in storage Watched points to.
   type Watch_List;
   type Watch_List_Access is access Watch_List;

   type Poller is limited record
      Handle  : Descriptor := No_Descriptor;
      Watched : Watch_List_Access;
      Open    : Boolean := False;
   end record;

   type Waker is limited record
      Read_End  : Descriptor := No_Descriptor;
      Write_End : Descriptor := No_Descriptor;   --  the same descriptor where one serves both ends
   end record;

   function Is_Open (This : Poller) return Boolean is (This.Open);
   function Is_Open (This : Waker) return Boolean is (This.Read_End /= No_Descriptor);
   function Watched_End (This : Waker) return Descriptor is (This.Read_End);

end Sparrow.IO.Events;
