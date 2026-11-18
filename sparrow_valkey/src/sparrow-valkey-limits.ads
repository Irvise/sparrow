--  Rate limits counted in Valkey, so that every server behind a load balancer draws from the same buckets:
--
--     Logins : constant Limits.Limit :=
--       Limits.Per_Client (0.2, 5, Store => Valkey.Limits.Buckets (Environment ("VALKEY_URL"), Name => "logins"));
--
--  Each bucket is a small hash ("<prefix>limit:<name>:<key>") that one script reads, refills and takes from,
--  atomically and by the server's clock (the servers' own clocks do not matter); it expires once it would be full
--  again. A request through a limited route waits for one round trip: run those routes on workers.
--
--  When Valkey cannot be reached, requests are let through (a cache outage should not lock everyone out), and a
--  warning is logged, at most every ten seconds.
with Sparrow.Stores;
private with Ada.Strings.Unbounded;
private with Sparrow.Valkey.Pools;

package Sparrow.Valkey.Limits is

   type Valkey_Buckets is limited new Stores.Bucket_Store with private;

   --  Buckets on the server at Url (see Server_At), for Http.Limits.Per_Key and Per_Client. Name sets them
   --  apart from other limits' (give each limit its own); Prefix, from other applications'.
   function Buckets
     (Url         : String;
      Name        : String;
      Prefix      : String := "sparrow:";
      Connections : Positive := 4;
      Trust_File  : String := "") return Stores.Bucket_Store_Access
     with Pre => Name'Length > 0;

   overriding procedure Take
     (This        : in out Valkey_Buckets;
      Key         : String;
      Rate        : Long_Float;
      Burst       : Positive;
      Allowed     : out Boolean;
      Retry_After : out Natural);

private

   type Valkey_Buckets is limited new Stores.Bucket_Store with record
      Links  : Pools.Pool_Access;
      Prefix : Ada.Strings.Unbounded.Unbounded_String;   --  "<prefix>limit:<name>:"
   end record;

end Sparrow.Valkey.Limits;
