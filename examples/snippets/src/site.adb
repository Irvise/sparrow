with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Static;

package body Site is

   procedure Register (Routes : in out Router) is
   begin
      --  public/index.html at /, public/css/app.css at /css/app.css.
      --  Other routes still win over this one.
      Add (Routes, Get, "/*file", Static.Folder ("public", Max_Age => 3600));
   end Register;

end Site;
