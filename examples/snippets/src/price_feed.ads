with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Price_Feed is
   procedure Register (Routes : in out Router);
   procedure Publish (Price : Integer);   --  from any task
end Price_Feed;
