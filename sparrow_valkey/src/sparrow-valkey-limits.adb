with Ada.Exceptions;
with Ada.Real_Time; use Ada.Real_Time;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Sparrow.Logs;

package body Sparrow.Valkey.Limits is

   --  KEYS[1]: the bucket; ARGV: rate (tokens a second), burst. Returns {allowed (0 or 1), seconds to wait}.
   Take_Script : constant String :=
     "local rate = tonumber(ARGV[1]) local burst = tonumber(ARGV[2]) "
     & "local time = redis.call('TIME') local now = tonumber(time[1]) + tonumber(time[2]) / 1000000 "
     & "local saved = redis.call('HMGET', KEYS[1], 'tokens', 'updated') "
     & "local tokens = tonumber(saved[1]) "
     & "if tokens == nil then tokens = burst "
     & "else tokens = math.min(burst, tokens + rate * math.max(0, now - tonumber(saved[2]))) end "
     & "local allowed = 0 local wait = 0 "
     & "if tokens >= 1 then tokens = tokens - 1 allowed = 1 "
     & "else wait = math.max(1, math.ceil((1 - tokens) / rate)) end "
     & "redis.call('HSET', KEYS[1], 'tokens', tostring(tokens), 'updated', tostring(now)) "
     & "redis.call('PEXPIRE', KEYS[1], math.ceil((burst - tokens) / rate * 1000) + 1000) "
     & "return {allowed, wait}";

   --  When the last warning about an unreachable server was logged: one every ten seconds is enough.
   protected Warnings is
      procedure Due (Now : Time; Log : out Boolean; Skipped : out Natural);
   private
      Warned : Boolean := False;
      Last   : Time := Time_First;
      Quiet  : Natural := 0;
   end Warnings;

   protected body Warnings is
      procedure Due (Now : Time; Log : out Boolean; Skipped : out Natural) is
      begin
         Log := not Warned or else Now - Last >= Seconds (10);
         if Log then
            Warned  := True;
            Last    := Now;
            Skipped := Quiet;
            Quiet   := 0;
         else
            Skipped := 0;
            Quiet   := Quiet + 1;
         end if;
      end Due;
   end Warnings;

   function Buckets
     (Url         : String;
      Name        : String;
      Prefix      : String := "sparrow:";
      Connections : Positive := 4;
      Trust_File  : String := "") return Stores.Bucket_Store_Access
   is
     (new Valkey_Buckets'(Links  => Pools.New_Pool (Server_At (Url, Trust_File => Trust_File), Connections),
                          Prefix => To_Unbounded_String (Prefix & "limit:" & Name & ":")));

   overriding procedure Take
     (This        : in out Valkey_Buckets;
      Key         : String;
      Rate        : Long_Float;
      Burst       : Positive;
      Allowed     : out Boolean;
      Retry_After : out Natural)
   is
      Result_Allowed : Boolean := True;
      Result_Wait    : Natural := 0;

      procedure Action (Link : in out Connection) is
         Answer : Reply;
      begin
         Start (Link, "EVAL"); Add (Link, Take_Script); Add (Link, 1);
         Add (Link, To_String (This.Prefix) & Key);
         Add (Link, Long_Float'Image (Rate)); Add (Link, Long_Long_Integer (Burst));
         Read_Reply (Link, Answer);
         if Kind (Answer) = Error then
            raise Command_Error with Text (Link, Answer);
         elsif Kind (Answer) /= List or else Count (Answer) /= 2
           or else Kind (Item (Link, Answer, 1)) /= Number or else Kind (Item (Link, Answer, 2)) /= Number
         then
            raise Command_Error with "an unexpected reply to the rate limit script";
         end if;
         Result_Allowed := Number (Item (Link, Answer, 1)) = 1;
         Result_Wait    := Natural (Long_Long_Integer'Min (Number (Item (Link, Answer, 2)), 86_400 * 365));
      end Action;
   begin
      begin
         Pools.With_Connection (This.Links, Action'Access);
      exception
         when Problem : Connection_Error | Command_Error =>
            declare
               Log     : Boolean;
               Skipped : Natural;
            begin
               Warnings.Due (Clock, Log, Skipped);
               if Log then
                  Logs.Warning ("rate limit not checked, request let through: "
                                & Ada.Exceptions.Exception_Message (Problem)
                                & (if Skipped > 0 then " (and" & Skipped'Image & " more since the last warning)"
                                   else ""));
               end if;
            end;
            Result_Allowed := True;
            Result_Wait    := 0;
      end;
      Allowed     := Result_Allowed;
      Retry_After := Result_Wait;
   end Take;

end Sparrow.Valkey.Limits;
