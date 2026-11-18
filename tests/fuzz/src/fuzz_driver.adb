with Ada.Exceptions;
with Ada.Text_IO;
with GNAT.OS_Lib;
with Interfaces.C; use Interfaces.C;
with System;

package body Fuzz_Driver is

   --  The binder keeps the program's arguments here.
   Argc : aliased int with Import, Convention => C, External_Name => "gnat_argc";
   Argv : aliased System.Address with Import, Convention => C, External_Name => "gnat_argv";

   --  Exits rather than aborts: GNAT would turn SIGABRT into an exception. libFuzzer saves the input either way.
   procedure Fail (Report : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "fuzz: " & Report);
      GNAT.OS_Lib.OS_Exit (77);
   end Fail;

   procedure Check (Condition : Boolean; Property : String) is
   begin
      if not Condition then
         Fail ("property broken: " & Property);
      end if;
   end Check;

   procedure Run is

      type Callback is access function (Data : System.Address; Size : size_t) return int with Convention => C;

      function LLVMFuzzerRunDriver (Count : access int; Arguments : access System.Address; Each : Callback)
        return int
         with Import, Convention => C, External_Name => "LLVMFuzzerRunDriver";

      function Each_Input (Data : System.Address; Size : size_t) return int with Convention => C;

      function Each_Input (Data : System.Address; Size : size_t) return int is
      begin
         if Size = 0 then
            Test ("");
         else
            declare
               Input : constant String (1 .. Natural (Size)) with Import, Address => Data;
            begin
               Test (Input);
            end;
         end if;
         return 0;
      exception
         when Error : others =>
            Fail (Ada.Exceptions.Exception_Information (Error));
            return 0;
      end Each_Input;

   begin
      GNAT.OS_Lib.OS_Exit (Integer (LLVMFuzzerRunDriver (Argc'Access, Argv'Access, Each_Input'Access)));
   end Run;

end Fuzz_Driver;
