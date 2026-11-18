with Ada.Command_Line;
with Ada.Text_IO; use Ada.Text_IO;

package body Checks is

   Passed, Failed : Natural := 0;

   procedure Check (Condition : Boolean; Name : String) is begin
      if Condition then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("FAIL: " & Name);
      end if;
   end Check;

   procedure Equal (Actual, Expected : String; Name : String) is begin
      if Actual = Expected then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("FAIL: " & Name);
         Put_Line ("   expected: " & Expected);
         Put_Line ("   actual:   " & Actual);
      end if;
   end Equal;

   procedure Finish (Suite : String) is begin
      Put_Line (Suite & ":" & Passed'Image & " passed," & Failed'Image & " failed");
      Ada.Command_Line.Set_Exit_Status ((if Failed = 0 then Ada.Command_Line.Success else Ada.Command_Line.Failure));
   end Finish;

end Checks;
