with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Article_Pages is
   procedure Load_Views;   --  once, at start
   procedure Register (Routes : in out Router);
end Article_Pages;
