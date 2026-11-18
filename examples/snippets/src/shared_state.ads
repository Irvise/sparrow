with Sparrow.Http.Limits;
with Sparrow.Http.Sessions;
with Sparrow.IO.Process;
with Sparrow.Valkey.Limits;
with Sparrow.Valkey.Sessions;

package Shared_State is

   Url : constant String :=
     Sparrow.IO.Process.Environment
       ("VALKEY_URL", Default => "valkey://localhost:6379");

   --  Sessions kept in Valkey: every server behind the load balancer sees
   --  them, and they outlive restarts.
   Visitors : constant Sparrow.Http.Sessions.Store :=
     Sparrow.Http.Sessions.Table_Store (Sparrow.Valkey.Sessions.Table (Url));

   --  A rate limit that every server counts together.
   Logins : constant Sparrow.Http.Limits.Limit :=
     Sparrow.Http.Limits.Per_Client
       (0.2, 5, Store => Sparrow.Valkey.Limits.Buckets (Url, "logins"));

   --  Valkey as a cache, over a connection of your own (one per task).
   procedure Cache_Example;

end Shared_State;
