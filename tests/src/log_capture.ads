--  A Sparrow.Logs sink that keeps the lines, for tests.
package Log_Capture is

   procedure Keep (Line : String);

   --  The kept lines containing every one of the parts ("" when none does); the latest first.
   function Find (First_Part : String; Second_Part : String := ""; Third_Part : String := "") return String;

   procedure Clear;

end Log_Capture;
