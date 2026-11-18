--  Logs from several tasks at once and exits without flushing, for io_tests to read back what reached standard
--  error: every line whole, each task's lines in order, the last ones written at exit.
with Sparrow.Logs; use Sparrow.Logs;

procedure Log_Writer is

   Lines_Per_Task : constant := 2000;

   task type Writer is
      entry Start (Number : Positive);
   end Writer;

   task body Writer is
      Self : Positive;
   begin
      accept Start (Number : Positive) do
         Self := Number;
      end Start;
      for Line in 1 .. Lines_Per_Task loop
         Info ("line", Field ("task", Long_Long_Integer (Self)), Field ("n", Long_Long_Integer (Line)));
         if Self = 1 and then Line = Lines_Per_Task / 2 then
            Info ("long", Field ("task", 1), Field ("text", [1 .. 20_000 => 'x']));   --  written on its own
         end if;
      end loop;
   end Writer;

   Writers : array (1 .. 6) of Writer;

begin
   for Index in Writers'Range loop
      Writers (Index).Start (Index);
   end loop;
end Log_Writer;
