--  The smallest test harness: count what holds and what does not, and exit accordingly.
package Checks is

   procedure Check (Condition : Boolean; Name : String);
   procedure Equal (Actual, Expected : String; Name : String);

   --  Print the totals and set the exit status.
   procedure Finish (Suite : String);

end Checks;
