--  The AWS counterpart of tests/demo_server's /hello, for a like-for-like benchmark (tests/bench/run.sh).
--  Port 18477; MAX sets Max_Connection (default 64).
with Ada.Environment_Variables;
with AWS.Config.Set;
with AWS.Response;
with AWS.Server;
with AWS.Status;

procedure Aws_Hello is
   function Answer (Request : AWS.Status.Data) return AWS.Response.Data is
      pragma Unreferenced (Request);
   begin
      return AWS.Response.Build ("text/plain", "hello");
   end Answer;

   Web    : AWS.Server.HTTP;
   Config : AWS.Config.Object := AWS.Config.Get_Current;
begin
   AWS.Config.Set.Server_Port (Config, 18_477);
   AWS.Config.Set.Max_Connection
     (Config, Positive'Value (Ada.Environment_Variables.Value ("MAX", "64")));
   AWS.Server.Start (Web, Answer'Unrestricted_Access, Config);
   AWS.Server.Wait (AWS.Server.Forever);
end Aws_Hello;
