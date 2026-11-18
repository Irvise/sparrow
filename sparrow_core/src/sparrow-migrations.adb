with Sparrow.Encoding;

package body Sparrow.Migrations is

   function Step (Version : Positive; Sql : String) return Migration_Step is
     ((Version => Version, Sql => new String'(Sql)));

   function Version (Of_Step : Migration_Step) return Positive is (Of_Step.Version);

   function Sql (Of_Step : Migration_Step) return String is (if Of_Step.Sql = null then "" else Of_Step.Sql.all);

   procedure Check_Order (Steps : Step_List) is
      function Image (Value : Positive) return String is (Encoding.Decimal_Image (Long_Long_Integer (Value)));
   begin
      for Index in Steps'First + 1 .. Steps'Last loop
         if Steps (Index).Version <= Steps (Index - 1).Version then
            raise Program_Error with "migration steps must have increasing versions: "
                                     & Image (Steps (Index).Version) & " follows "
                                     & Image (Steps (Index - 1).Version);
         end if;
      end loop;
   end Check_Order;

end Sparrow.Migrations;
