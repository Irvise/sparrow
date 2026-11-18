--  Sessions kept in Valkey, so that every server behind a load balancer sees the same ones, and they outlive a
--  restart. One line moves a Table_Store there:
--
--     Visitors : constant Sessions.Store :=
--       Sessions.Table_Store (Valkey.Sessions.Table (Environment ("VALKEY_URL")));
--
--  Each session is a key ("<prefix>session:<id>") that Valkey expires on its own; each signed-in user has a set
--  of their session ids ("<prefix>user:<user>"), so that Revoke_User ends them all at once.
--
--  The table holds a few connections, opened as first needed, and lends one to each call; a call that loses its
--  connection opens a new one and tries once more. Handlers that load or save these sessions block on the
--  network: run them on workers. When Valkey cannot be reached, loading or saving raises Connection_Error.
with Sparrow.Stores;
private with Ada.Strings.Unbounded;
private with Sparrow.Valkey.Pools;

package Sparrow.Valkey.Sessions is

   type Valkey_Table is limited new Stores.Session_Table with private;

   --  A table on the server at Url (see Server_At), for Http.Sessions.Table_Store. Prefix starts every key, to
   --  keep applications that share a server apart; Connections is how many calls can run at once.
   function Table
     (Url         : String;
      Prefix      : String := "sparrow:";
      Connections : Positive := 8;
      Trust_File  : String := "") return Stores.Session_Table_Access;

   overriding function Read (This : Valkey_Table; Id : String) return String;
   overriding procedure Write
     (This : in out Valkey_Table; Id : String; User : String; Data : String; Expires : Long_Long_Integer);
   overriding procedure Delete (This : in out Valkey_Table; Id : String);
   overriding procedure Delete_User (This : in out Valkey_Table; User : String);

private

   type Valkey_Table is limited new Stores.Session_Table with record
      Links  : Pools.Pool_Access;
      Prefix : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Sparrow.Valkey.Sessions;
