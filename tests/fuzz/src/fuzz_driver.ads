--  Runs libFuzzer (LLVMFuzzerRunDriver) with the program's arguments, calling Test with each input. Test
--  checks properties with Check; a failed check or any exception ends the process (exit status 77), and
--  libFuzzer saves the input.
package Fuzz_Driver is

   generic
      with procedure Test (Input : String);
   procedure Run;

   --  Aborts with Property in the report when Condition is False.
   procedure Check (Condition : Boolean; Property : String);

end Fuzz_Driver;
