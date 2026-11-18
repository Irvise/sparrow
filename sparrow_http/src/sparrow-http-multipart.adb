with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;
with Sparrow.Buffers;
with Sparrow.Crypto.Random;
with Sparrow.Encoding;
with Sparrow.Http.Bodies;
with Sparrow.Http.Multipart_Scanning;

package body Sparrow.Http.Multipart is

   package Scanning renames Sparrow.Http.Multipart_Scanning;

   --  Where Pattern first starts in Text (whose indices the scanner accepts), or 0.
   function Index (Text, Pattern : String) return Natural is (Scanning.Find (Text, Pattern));

   --  The text at Item.
   function Text_At (Text : String; Item : Encoding.Span) return String renames Encoding.Slice;

   function Boundary_Of (Content_Type : String) return String is
     (if Content_Type'Last > Scanning.Max_Index then ""
      else Text_At (Content_Type, Scanning.Parameter (Content_Type, "boundary")));

   --  A part described by its header lines (Head, without the blank line that ends them), with no content yet;
   --  its Name is "" when it has no Content-Disposition name.
   function Part_Of (Head : String) return Part is
      Found     : constant Scanning.Part_Head := Scanning.Read_Head (Head);
      Name      : constant String := Text_At (Head, Found.Name);
      File_Name : constant String := Text_At (Head, Found.File_Name);
      Kind      : constant String := Text_At (Head, Found.Kind);
   begin
      return (Name_Length => Name'Length, File_Length => File_Name'Length, Type_Length => Kind'Length,
              Content_Length => 0, Path_Length => 0, Name => Name, File_Name => File_Name,
              Content_Type => Kind, Content => "", Path => "", Size => 0);
   end Part_Of;

   --  The same part with Content.
   function With_Content (Item : Part; Content : String) return Part is
     (Name_Length => Item.Name_Length, File_Length => Item.File_Length, Type_Length => Item.Type_Length,
      Content_Length => Content'Length, Path_Length => 0, Name => Item.Name, File_Name => Item.File_Name,
      Content_Type => Item.Content_Type, Content => Content, Path => "", Size => Content'Length);

   procedure Parse (Request : Requests.Request; Into : out Form; Valid : out Boolean) is
      Media    : constant String := Requests.Header (Request, "Content-Type");
      Boundary : constant String := Boundary_Of (Media);
      Data     : constant String := Requests.Content (Request);
      Marker   : constant String := "--" & Boundary;
      Position : Natural;
   begin
      Into  := (others => <>);
      Valid := False;
      if not Requests.Has_Content_Type (Request, "multipart/form-data") or else Boundary'Length not in 1 .. 70
        or else Data'Last > Scanning.Max_Index
      then
         return;
      end if;
      Position := Scanning.Find (Data, Marker);   --  anything before is a preamble, ignored
      if Position = 0 then
         return;
      end if;
      loop
         declare
            Next : constant Scanning.Step := Scanning.Next_Part (Data, Marker, Position);
         begin
            case Next.Kind is
               when Scanning.Closed =>
                  Valid := True;
                  return;
               when Scanning.Malformed =>
                  return;
               when Scanning.Part_Found =>
                  declare
                     Item : constant Part := Part_Of (Text_At (Data, Next.Head));
                  begin
                     if Item.Name'Length = 0 then
                        return;
                     end if;
                     Into.Parts.Append (With_Content (Item, Text_At (Data, Next.Content)));
                  end;
                  Position := Next.Next;
            end case;
         end;
      end loop;
   end Parse;

   function Part_Count (This : Form) return Natural is (Natural (This.Parts.Length));
   function Name (This : Form; Index : Positive) return String is (This.Parts (Index).Name);
   function File_Name (This : Form; Index : Positive) return String is (This.Parts (Index).File_Name);
   function Content_Type (This : Form; Index : Positive) return String is (This.Parts (Index).Content_Type);
   function Content (This : Form; Index : Positive) return String is (This.Parts (Index).Content);

   function Find (This : Form; Name : String) return Natural is begin
      for Index in 1 .. Part_Count (This) loop
         if This.Parts (Index).Name = Name then
            return Index;
         end if;
      end loop;
      return 0;
   end Find;

   function Field (This : Form; Name : String; Default : UTF8_String := "") return UTF8_String is
      Index : constant Natural := Find (This, Name);
   begin
      if Index = 0 or else This.Parts (Index).File_Name'Length > 0
        or else not Encoding.Valid_Utf8 (This.Parts (Index).Content)
      then
         return Default;
      end if;
      return UTF8_String (This.Parts (Index).Content);
   end Field;

   function Has_File (This : Form; Name : String) return Boolean is
      Index : constant Natural := Find (This, Name);
   begin
      return Index > 0 and then This.Parts (Index).File_Name'Length > 0;
   end Has_File;

   procedure Save (This : Form; Name : String; Path : String) is
      use Ada.Streams.Stream_IO;
      Index : constant Natural := Find (This, Name);
      File  : File_Type;
   begin
      if Index = 0 then
         raise Name_Error with "no part named " & Name;
      end if;
      if This.Parts (Index).Path_Length > 0 then
         declare
            Saved : constant String := This.Parts (Index).Path;
         begin
            if Ada.Directories.Exists (Path) then
               Ada.Directories.Delete_File (Path);
            end if;
            begin
               Ada.Directories.Rename (Saved, Path);
            exception
               when Ada.Directories.Use_Error =>   --  another file system: copy, then delete
                  Ada.Directories.Copy_File (Saved, Path);
                  Ada.Directories.Delete_File (Saved);
            end;
            return;
         end;
      end if;
      Create (File, Out_File, Path);
      String'Write (Stream (File), This.Parts (Index).Content);
      Close (File);
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         raise;
   end Save;

   ---------------------------------------------------------------------------------------------------------------
   --  Streamed bodies

   function Saved_Path (This : Form; Index : Positive) return String is (This.Parts (Index).Path);
   function Saved_Size (This : Form; Index : Positive) return Long_Long_Integer is (This.Parts (Index).Size);

   procedure Discard (This : Form) is begin
      for Item of This.Parts loop
         if Item.Path_Length > 0 and then Ada.Directories.Exists (Item.Path) then
            Ada.Directories.Delete_File (Item.Path);
         end if;
      end loop;
   end Discard;

   procedure Save_Stream
     (Request          : Requests.Request;
      Directory        : String;
      Into             : out Form;
      Valid            : out Boolean;
      Max_Field_Length : Positive := 65_536;
      Max_Parts        : Positive := 100)
   is
      use Sparrow.Buffers;
      use Ada.Streams.Stream_IO;

      Boundary  : constant String := Boundary_Of (Requests.Header (Request, "Content-Type"));
      Marker    : constant String := "--" & Boundary;
      Delimiter : constant String := CRLF & Marker;   --  what ends a part's content
      Max_Head  : constant := 16_384;                 --  a part's header lines

      type Stage is (Preamble, After_Marker, Part_Head, Part_Content, Epilogue);

      Field_Too_Long : exception;

      Window    : Buffer;             --  bytes read and not yet used
      At_End    : Boolean := False;   --  the body has no more
      Current   : Stage := Preamble;
      type Part_Access is access Part;
      procedure Free is new Ada.Unchecked_Deallocation (Part, Part_Access);
      Head      : Part_Access;        --  the current part, without content
      Field     : Buffer;             --  a field's value so far
      File      : File_Type;
      Size      : Long_Long_Integer := 0;
      Path      : Buffers.String_Access;

      --  More of the body into Window; At_End once there is none.
      procedure Read_More is
         Piece : String (1 .. 65_536);
         Last  : Natural;
      begin
         Bodies.Read (Request, Piece, Last);
         if Last < Piece'First then
            At_End := True;
         else
            Append (Window, Piece (1 .. Last));
         end if;
      end Read_More;

      --  A new file in Directory, with a random name.
      function New_Path return String is
         Token : String (1 .. 24);
         Last  : Natural;
      begin
         Crypto.Random.Token (18, Token, Last);
         return Ada.Directories.Compose (Directory, "upload-" & Token (1 .. Last));
      end New_Path;

      --  Content bytes of the current part.
      procedure Take_Content (Bytes : String) is begin
         if Is_Open (File) then
            String'Write (Stream (File), Bytes);
            Size := Size + Bytes'Length;
         elsif Field.Length + Bytes'Length > Max_Field_Length then
            raise Field_Too_Long;
         else
            Append (Field, Bytes);
         end if;
      end Take_Content;

      --  The current part is complete.
      procedure End_Part is begin
         if Is_Open (File) then
            Close (File);
            Into.Parts.Append
              (Part'(Name_Length => Head.Name_Length, File_Length => Head.File_Length, Type_Length => Head.Type_Length,
                Content_Length => 0, Path_Length => Path'Length, Name => Head.Name, File_Name => Head.File_Name,
                Content_Type => Head.Content_Type, Content => "", Path => Path.all, Size => Size));
            Free (Path);
         else
            Into.Parts.Append (With_Content (Head.all, Content (Field)));
            Clear (Field);
         end if;
      end End_Part;

      procedure Clean_Up is begin
         if Is_Open (File) then
            Close (File);
         end if;
         if Path /= null then
            if Ada.Directories.Exists (Path.all) then
               Ada.Directories.Delete_File (Path.all);
            end if;
            Free (Path);
         end if;
         Discard (Into);
         Into := (others => <>);
         Free (Window);
         Free (Field);
         Free (Head);
      end Clean_Up;

      Found : Natural;
   begin
      Into  := (others => <>);
      Valid := False;
      if not Requests.Has_Content_Type (Request, "multipart/form-data") or else Boundary'Length not in 1 .. 70 then
         return;
      end if;

      loop
         case Current is
            when Preamble =>   --  up to the first marker; what comes before it is ignored
               Found := Index (Content (Window), Marker);
               if Found > 0 then
                  Consume (Window, Found - 1 + Marker'Length);
                  Current := After_Marker;
               elsif At_End then
                  exit;
               else
                  if Window.Length > Marker'Length then
                     Consume (Window, Window.Length - Marker'Length);
                  end if;
                  Read_More;
               end if;

            when After_Marker =>   --  "--" ends the body; else blanks, then the line's end
               if Window.Length >= 2 and then Window.Data (1 .. 2) = "--" then
                  Current := Epilogue;
               else
                  Found := Index (Content (Window), CRLF);
                  if Found > 0 then
                     exit when (for some Symbol of Window.Data (1 .. Found - 1) => Symbol not in ' ' | ASCII.HT);
                     Consume (Window, Found + 1);
                     Current := Part_Head;
                  elsif At_End or else Window.Length > 256 then
                     exit;
                  else
                     Read_More;
                  end if;
               end if;

            when Part_Head =>
               if Window.Length >= 2 and then Window.Data (1 .. 2) = CRLF then
                  Found := 1;   --  no header lines
               else
                  Found := Index (Content (Window), CRLF & CRLF);
                  Found := (if Found = 0 then 0 else Found + 2);
               end if;
               if Found > 0 then
                  exit when Natural (Into.Parts.Length) = Max_Parts;
                  declare
                     Item : constant Part := Part_Of (Window.Data (1 .. Found - 1 - (if Found = 1 then 0 else 2)));
                  begin
                     exit when Item.Name'Length = 0;
                     Free (Head);
                     Head := new Part'(Item);
                  end;
                  Consume (Window, Found + 1);
                  if Head.File_Length > 0 then
                     Path := new String'(New_Path);
                     Create (File, Out_File, Path.all);
                     Size := 0;
                  end if;
                  Current := Part_Content;
               elsif At_End or else Window.Length > Max_Head then
                  exit;
               else
                  Read_More;
               end if;

            when Part_Content =>   --  up to CRLF and the marker; keep what might be the start of one
               Found := Index (Content (Window), Delimiter);
               if Found > 0 then
                  Take_Content (Window.Data (1 .. Found - 1));
                  Consume (Window, Found - 1 + Delimiter'Length);
                  End_Part;
                  Current := After_Marker;
               elsif At_End then
                  exit;
               else
                  if Window.Length >= Delimiter'Length then
                     Take_Content (Window.Data (1 .. Window.Length - Delimiter'Length + 1));
                     Consume (Window, Window.Length - Delimiter'Length + 1);
                  end if;
                  Read_More;
               end if;

            when Epilogue =>   --  read to the end, so the connection stays usable
               Clear (Window);
               if At_End then
                  Valid := True;
                  Free (Window);
                  Free (Field);
                  Free (Head);
                  return;
               end if;
               Read_More;
         end case;
      end loop;
      Clean_Up;   --  malformed
   exception
      when Field_Too_Long =>
         Clean_Up;
      when others =>
         Clean_Up;
         raise;
   end Save_Stream;

end Sparrow.Http.Multipart;
