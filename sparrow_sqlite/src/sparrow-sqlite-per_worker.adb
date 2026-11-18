package body Sparrow.Sqlite.Per_Worker is

   Connections : array (Worker_Index) of aliased Database;

   --  Workers start together. Opened one at a time, the first sets up the file (WAL, Schema) before the others
   --  arrive, instead of all of them racing for the same exclusive lock.
   protected Gate is
      entry Seize;
      procedure Release;
   private
      Busy : Boolean := False;
   end Gate;

   protected body Gate is
      entry Seize when not Busy is begin
         Busy := True;
      end Seize;

      procedure Release is begin
         Busy := False;
      end Release;
   end Gate;

   procedure Open (Worker : Worker_Index) is begin
      Gate.Seize;
      begin
         Open (Connections (Worker), Path, Settings);
         if Schema'Length > 0 then
            Run_Script (Connections (Worker), Schema);
         end if;
         if Steps'Length > 0 then
            Migrations.Apply (Connections (Worker), Steps);   --  a no-op once the first worker has run them
         end if;
      exception
         when others =>
            Gate.Release;
            raise;
      end;
      Gate.Release;
   end Open;

   procedure Close (Worker : Worker_Index) is begin
      Close (Connections (Worker));
   end Close;

   function Connection (Worker : Worker_Index) return Reference is
     ((Element => Connections (Worker)'Access));

end Sparrow.Sqlite.Per_Worker;
