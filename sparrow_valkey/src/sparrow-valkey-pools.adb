with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Sparrow.Valkey.Pools is

   protected body Lender is

      entry Borrow (Index : out Positive) when Available > 0 is
      begin
         for Candidate in Lent'Range loop
            if not Lent (Candidate) then
               Lent (Candidate) := True;
               Available        := Available - 1;
               Index            := Candidate;
               return;
            end if;
         end loop;
         raise Program_Error;   --  Available counts the free ones
      end Borrow;

      procedure Give_Back (Index : Positive) is
      begin
         Lent (Index) := False;
         Available    := Available + 1;
      end Give_Back;

   end Lender;

   function New_Pool (Where : Server; Size : Positive) return Pool_Access is
      Result : constant Pool_Access := new Pool (Size);
   begin
      Result.Where := Where;
      return Result;
   end New_Pool;

   procedure With_Connection
     (This : not null Pool_Access; Action : not null access procedure (Link : in out Connection))
   is
      Index : Positive;
   begin
      This.Guard.Borrow (Index);
      declare
         Link : Connection renames This.Links (Index);
      begin
         if not Is_Connected (Link) then
            Connect (Link, This.Where);
         end if;
         begin
            Action (Link);
         exception
            when Connection_Error =>
               Connect (Link, This.Where);
               Action (Link);
         end;
      exception
         when others =>
            if Is_Connected (Link) and then Replies_Due (Link) > 0 then
               Close (Link);   --  replies still due would answer the next borrower's commands
            end if;
            This.Guard.Give_Back (Index);
            raise;
      end;
      This.Guard.Give_Back (Index);
   end With_Connection;

   procedure Read_Replies (Link : in out Connection) is
      Answer  : Reply;
      Refused : Unbounded_String;
   begin
      while Replies_Due (Link) > 0 loop
         Read_Reply (Link, Answer);
         if Kind (Answer) = Error and then Length (Refused) = 0 then
            Refused := To_Unbounded_String (Text (Link, Answer));
         end if;
      end loop;
      if Length (Refused) > 0 then
         raise Command_Error with To_String (Refused);
      end if;
   end Read_Replies;

end Sparrow.Valkey.Pools;
