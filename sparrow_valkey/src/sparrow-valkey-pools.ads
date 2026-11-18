--  A few connections to one server, lent to one task at a time: for the tables and stores that every worker
--  shares (Sessions, Limits). Connections open as first needed.
private package Sparrow.Valkey.Pools is

   type Pool (Size : Positive) is limited private;
   type Pool_Access is access Pool;

   function New_Pool (Where : Server; Size : Positive) return Pool_Access;

   --  Lend a connection to Action, connected and with no replies due. When it turns out to be lost (the server
   --  restarted, or closed it as idle), connect again and run Action once more; a second Connection_Error, or any
   --  other exception, goes to the caller.
   procedure With_Connection
     (This : not null Pool_Access; Action : not null access procedure (Link : in out Connection));

   --  Read every reply due, raising Command_Error with the first refusal.
   procedure Read_Replies (Link : in out Connection);

private

   type Connection_Array is array (Positive range <>) of Connection;
   type Lent_Array is array (Positive range <>) of Boolean;

   protected type Lender (Size : Positive) is
      entry Borrow (Index : out Positive);
      procedure Give_Back (Index : Positive);
   private
      Lent      : Lent_Array (1 .. Size) := [others => False];
      Available : Natural := Size;
   end Lender;

   type Pool (Size : Positive) is limited record
      Where : Server;
      Guard : Lender (Size);
      Links : Connection_Array (1 .. Size);
   end record;

end Sparrow.Valkey.Pools;
