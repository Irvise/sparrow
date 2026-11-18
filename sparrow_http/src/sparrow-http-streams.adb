with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Http.Delivery; use Sparrow.Http.Delivery;

package body Sparrow.Http.Streams is

   procedure Post (Target : Connection_Id; Kind : Job_Kind; Data : String; Binary : Boolean) is
      Item : Job_Access;
   begin
      if not Is_Live (Target) then
         return;
      end if;
      Item := new Job;
      Item.Kind       := Kind;
      Item.Binary     := Binary;
      Item.Reactor    := Target.Reactor;
      Item.Slot       := Target.Slot;
      Item.Generation := Target.Generation;
      Item.Stream     := Target.Stream;
      if Data'Length > 0 then
         Allocate (Item.Data, Data'Length);
         Append (Item.Data, Data);
      end if;
      Delivery.Post (Item);
   end Post;

   procedure Send (Target : Connection_Id; Text : UTF8_String) is begin
      Post (Target, Push_Data, String (Text), Binary => False);
   end Send;

   procedure Send_Bytes (Target : Connection_Id; Data : String) is begin
      Post (Target, Push_Data, Data, Binary => True);
   end Send_Bytes;

   procedure Close (Target : Connection_Id) is begin
      Post (Target, Push_Close, "", Binary => False);
   end Close;

   function Is_Open (Target : Connection_Id) return Boolean is (Is_Live (Target));

   ---------------------------------------------------------------------------------------------------------------

   protected body Member_List is

      procedure Add (Member : Connection_Id; Added : out Boolean) is begin
         Prune;
         for Index in 1 .. Total loop
            if Items (Index) = Member then
               Added := True;
               return;
            end if;
         end loop;
         Added := Total < Capacity;
         if Added then
            Total := Total + 1;
            Items (Total) := Member;
         end if;
      end Add;

      procedure Remove (Member : Connection_Id) is begin
         for Index in 1 .. Total loop
            if Items (Index) = Member then
               Items (Index) := Items (Total);
               Total := Total - 1;
               return;
            end if;
         end loop;
      end Remove;

      procedure Prune is
         Index : Positive := 1;
      begin
         while Index <= Total loop
            if Is_Live (Items (Index)) then
               Index := Index + 1;
            else
               Items (Index) := Items (Total);
               Total := Total - 1;
            end if;
         end loop;
      end Prune;

      function Members return Member_Array is (Items (1 .. Total));

   end Member_List;

   procedure Add (This : in out Group; Member : Connection_Id; Added : out Boolean) is begin
      This.List.Add (Member, Added);
   end Add;

   procedure Add (This : in out Group; Member : Connection_Id) is
      Added : Boolean;
   begin
      This.List.Add (Member, Added);
   end Add;

   procedure Remove (This : in out Group; Member : Connection_Id) is begin
      This.List.Remove (Member);
   end Remove;

   --  Sent outside the list's lock, from a copy of it.
   procedure Send (This : in out Group; Text : UTF8_String) is begin
      This.List.Prune;
      for Member of This.List.Members loop
         Send (Member, Text);
      end loop;
   end Send;

   procedure Send_Bytes (This : in out Group; Data : String) is begin
      This.List.Prune;
      for Member of This.List.Members loop
         Send_Bytes (Member, Data);
      end loop;
   end Send_Bytes;

   function Count (This : Group) return Natural is
      Open : Natural := 0;
   begin
      for Member of This.List.Members loop
         if Is_Live (Member) then
            Open := Open + 1;
         end if;
      end loop;
      return Open;
   end Count;

end Sparrow.Http.Streams;
