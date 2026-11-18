with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;

package Todo_Store is
   procedure Register (Routes : in out Router);

   --  Pass to Servers.Run: each worker opens its connection as it starts.
   function Hooks return Sparrow.Http.Servers.Worker_Hooks;
end Todo_Store;
