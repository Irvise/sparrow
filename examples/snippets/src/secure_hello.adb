with Greetings;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.Tls;

procedure Secure_Hello is
   Routes      : Router (Capacity => 8);
   Certificate : aliased Sparrow.Tls.Context;
begin
   Sparrow.Tls.Open_Server (Certificate, "cert.pem", "key.pem");
   if not Sparrow.Tls.Is_Open (Certificate) then
      raise Program_Error with Sparrow.Tls.Last_Failure (Certificate);
   end if;

   Greetings.Register (Routes);
   Servers.Run
     (Servers.From_Environment, Routes, Security => Certificate'Access);
end Secure_Hello;
