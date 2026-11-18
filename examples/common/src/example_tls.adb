with Sparrow.IO.Process;
with Sparrow.Logs;

package body Example_Tls is

   Context : aliased Sparrow.Tls.Context;

   function Security return access constant Sparrow.Tls.Context is
      Certificate : constant String := Sparrow.IO.Process.Environment ("CERT_FILE");
      Key         : constant String := Sparrow.IO.Process.Environment ("KEY_FILE");
   begin
      if Certificate = "" or else Key = "" then
         return null;
      end if;
      if not Sparrow.Tls.Is_Open (Context) then
         Sparrow.Tls.Open_Server (Context, Certificate, Key);
         if not Sparrow.Tls.Is_Open (Context) then
            raise Program_Error with "CERT_FILE, KEY_FILE: " & Sparrow.Tls.Last_Failure (Context);
         end if;
         Sparrow.Logs.Info ("serving HTTPS, HTTP/2 offered", Sparrow.Logs.Field ("certificate", Certificate));
      end if;
      return Context'Access;
   end Security;

end Example_Tls;
