with Ada.Strings.Fixed;
with Ada.Containers.Indefinite_Vectors;

package body Log_Capture is

   package Line_Vectors is new Ada.Containers.Indefinite_Vectors (Positive, String);

   protected Store is
      procedure Add (Line : String);
      procedure Reset;
      function Matching (First_Part, Second_Part, Third_Part : String) return String;
   private
      Lines : Line_Vectors.Vector;
   end Store;

   protected body Store is
      procedure Add (Line : String) is begin
         Lines.Append (Line);
      end Add;

      procedure Reset is begin
         Lines.Clear;
      end Reset;

      function Matching (First_Part, Second_Part, Third_Part : String) return String is
         function Has (Line, Part : String) return Boolean is
           (Part'Length = 0 or else Ada.Strings.Fixed.Index (Line, Part) > 0);
      begin
         for Index in reverse 1 .. Natural (Lines.Length) loop
            if Has (Lines (Index), First_Part) and then Has (Lines (Index), Second_Part)
              and then Has (Lines (Index), Third_Part)
            then
               return Lines (Index);
            end if;
         end loop;
         return "";
      end Matching;
   end Store;

   procedure Keep (Line : String) is begin
      Store.Add (Line);
   end Keep;

   function Find (First_Part : String; Second_Part : String := ""; Third_Part : String := "") return String is
     (Store.Matching (First_Part, Second_Part, Third_Part));

   procedure Clear is begin
      Store.Reset;
   end Clear;

end Log_Capture;
