with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Sparrow.Encoding;
with Sparrow.Http.Compression;
with Sparrow.Http.Ranges;
with Sparrow.Times;

package body Sparrow.Http.Static with SPARK_Mode is

   -------------------
   -- Media_Type_Of --
   -------------------

   function Media_Type_Of (File_Name : String) return String is
      Dot : Natural := 0;
   begin
      for Index in reverse File_Name'Range loop
         exit when File_Name (Index) = '/';
         if File_Name (Index) = '.' then
            Dot := Index;
            exit;
         end if;
      end loop;
      if Dot = 0 or else Dot = File_Name'Last then
         return "application/octet-stream";
      end if;

      declare
         Extension : constant String := File_Name (Dot + 1 .. File_Name'Last);

         function Ext (Name : String) return Boolean is (Encoding.Equal_Ignoring_Case (Extension, Name));
      begin
         return
           (if Ext ("html") or else Ext ("htm") then Text_Html
            elsif Ext ("css") then "text/css; charset=utf-8"
            elsif Ext ("js") or else Ext ("mjs") then "text/javascript; charset=utf-8"
            elsif Ext ("json") or else Ext ("map") then Application_Json
            elsif Ext ("txt") then Text_Plain
            elsif Ext ("csv") then "text/csv; charset=utf-8"
            elsif Ext ("xml") then "application/xml"
            elsif Ext ("svg") then "image/svg+xml"
            elsif Ext ("png") then "image/png"
            elsif Ext ("jpg") or else Ext ("jpeg") then "image/jpeg"
            elsif Ext ("gif") then "image/gif"
            elsif Ext ("webp") then "image/webp"
            elsif Ext ("avif") then "image/avif"
            elsif Ext ("ico") then "image/x-icon"
            elsif Ext ("woff2") then "font/woff2"
            elsif Ext ("woff") then "font/woff"
            elsif Ext ("wasm") then "application/wasm"
            elsif Ext ("pdf") then "application/pdf"
            elsif Ext ("mp4") then "video/mp4"
            elsif Ext ("webm") then "video/webm"
            elsif Ext ("mp3") then "audio/mpeg"
            else "application/octet-stream");
      end;
   end Media_Type_Of;

   ------------------
   -- Is_Safe_Path --
   ------------------

   function Is_Safe_Path (Relative : String) return Boolean is
      Start : Positive;
   begin
      if Relative'Length = 0 or else Relative'Last = Positive'Last then
         return False;
      end if;
      Start := Relative'First;
      for Symbol of Relative loop
         if Symbol in ASCII.NUL .. ASCII.US | ASCII.DEL | '\' | ':' then
            return False;   --  control bytes; Windows separators and drive letters
         end if;
      end loop;

      --  Each segment: not empty (which also refuses a leading '/') and not starting with '.' (which refuses
      --  "." and ".." and hidden files such as .env and .git).
      for Index in Relative'Range loop
         pragma Loop_Invariant (Start in Relative'First .. Index);
         if Relative (Index) = '/' then
            if Index = Start or else Relative (Start) = '.' then
               return False;
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Start <= Relative'Last and then Relative (Start) /= '.';   --  the last segment
   end Is_Safe_Path;

   ----------------
   -- Serve_File --
   ----------------

   procedure Serve_File
     (Request  : Requests.Request;
      Response : in out Responses.Response;
      Root     : String;
      Relative : String;
      Max_Age  : Natural := 0)
   with SPARK_Mode => Off
   is
      use Ada.Directories;
      use type Ada.Calendar.Time;

      Wants_Index : constant Boolean := Relative'Length = 0 or else Relative (Relative'Last) = '/';
      Name        : constant String  := (if Wants_Index then Relative & "index.html" else Relative);
      Unix_Epoch  : constant Ada.Calendar.Time := Ada.Calendar.Formatting.Time_Of (1970, 1, 1, 0.0, Time_Zone => 0);

      --  Count bytes of Path from offset From into Response.Content, replacing what it held.
      procedure Read (Path : String; From : Long_Long_Integer; Count : Natural) is
         use Ada.Streams;
         File : Stream_IO.File_Type;
      begin
         Buffers.Clear (Response.Content);
         if Count = 0 then
            return;
         end if;
         Buffers.Reserve (Response.Content, Count);
         if Buffers.Capacity (Response.Content) < Count then
            raise Storage_Error with "a file too large for a response";
         end if;
         declare
            Target : Stream_Element_Array (1 .. Stream_Element_Offset (Count))
               with Import, Address => Response.Content.Data (1)'Address;
            Last   : Stream_Element_Offset;
         begin
            Stream_IO.Open (File, Stream_IO.In_File, Path);
            Stream_IO.Set_Index (File, Stream_IO.Positive_Count (From + 1));
            Stream_IO.Read (File, Target, Last);
            Stream_IO.Close (File);
            Buffers.Extend (Response.Content, Natural (Last));
         end;
      exception
         when others =>
            if Stream_IO.Is_Open (File) then
               Stream_IO.Close (File);
            end if;
            raise;
      end Read;

      function Image (Value : Long_Long_Integer) return String renames Encoding.Decimal_Image;
   begin
      if not Is_Safe_Path (Name) then
         Responses.Fail (Response, Not_Found);
         return;
      end if;

      declare
         Full : constant String := (if Root'Length = 0 then Name else Root & "/" & Name);
      begin
         if not Exists (Full) then
            Responses.Fail (Response, Not_Found);
            return;
         elsif Kind (Full) = Directory then
            if Wants_Index then
               Responses.Fail (Response, Not_Found);
            else
               Responses.Redirect (Response, Requests.Path (Request) & "/", Moved_Permanently);
            end if;
            return;
         elsif Kind (Full) /= Ordinary_File then
            Responses.Fail (Response, Not_Found);
            return;
         end if;

         declare
            Length     : constant Long_Long_Integer := Long_Long_Integer (Size (Full));
            Modified   : constant Sparrow.Times.Unix_Seconds :=
              Sparrow.Times.Unix_Seconds (Long_Long_Integer (Modification_Time (Full) - Unix_Epoch));
            Tag        : constant String := '"' & Image (Length) & '-' & Image (Long_Long_Integer (Modified)) & '"';
            Date       : constant String := Sparrow.Times.Http_Date (Modified);
            Matches    : constant String := Requests.Header (Request, "If-None-Match");
            Media_Type : constant String := Media_Type_Of (Name);
            Shrinks    : constant Boolean := Compression.Compressible (Media_Type);
            Wanted     : Ranges.Byte_Range;
         begin
            Responses.Set_Header (Response, "ETag", Tag);
            Responses.Set_Header (Response, "Last-Modified", Date);
            Responses.Set_Header
              (Response, "Cache-Control",
               (if Max_Age = 0 then "no-cache" else "public, max-age=" & Image (Long_Long_Integer (Max_Age))));
            Responses.Set_Header (Response, "X-Content-Type-Options", "nosniff");
            Responses.Set_Header (Response, "Accept-Ranges", "bytes");
            if Shrinks then
               Responses.Set_Header (Response, "Vary", "Accept-Encoding");
            end if;

            --  If-None-Match compares weakly: W/"..." (the gzip form's tag) matches too.
            if (Matches'Length > 0 and then (Ada.Strings.Fixed.Index (Matches, Tag) > 0 or else Matches = "*"))
              or else (Matches'Length = 0 and then Requests.Header (Request, "If-Modified-Since") = Date)
            then
               Response.Status := Not_Modified;
               Buffers.Clear (Response.Content);
               if Ada.Strings.Fixed.Index (Matches, "W/" & Tag) > 0 then   --  the client holds the gzip form
                  Responses.Remove_Header (Response, "ETag");
                  Responses.Set_Header (Response, "ETag", "W/" & Tag);
               end if;
               return;
            end if;

            --  A range, unless If-Range names another version (it compares strongly: the tag or the date).
            declare
               Asked    : constant String := Requests.Header (Request, "Range");
               If_Range : constant String := Requests.Header (Request, "If-Range");
            begin
               if Asked'Length > 0 and then Requests.Verb (Request) in Get | Head
                 and then (If_Range'Length = 0 or else If_Range = Tag or else If_Range = Date)
               then
                  Wanted := Ranges.Parse (Asked, Ranges.Byte_Count (Long_Long_Integer'Min (Length, 2 ** 62)));
               end if;
            end;

            case Wanted.Kind is
               when Ranges.Unsatisfiable =>
                  Responses.Fail (Response, Range_Not_Satisfiable);
                  Responses.Set_Header (Response, "Content-Range", "bytes */" & Image (Length));

               when Ranges.Part =>
                  --  At most Max_File_Size bytes of it: clients ask again for the rest.
                  declare
                     Last : constant Long_Long_Integer :=
                       Long_Long_Integer'Min (Wanted.Last, Wanted.First + Max_File_Size - 1);
                  begin
                     Response.Status := Partial_Content;
                     Responses.Set_Content_Type (Response, Media_Type);
                     Responses.Set_Header
                       (Response, "Content-Range",
                        "bytes " & Image (Wanted.First) & "-" & Image (Last) & "/" & Image (Length));
                     Read (Full, Wanted.First, Natural (Last - Wanted.First + 1));
                  end;

               when Ranges.Whole =>
                  --  A file.gz beside the file, made ahead of time, saves compressing it for every request.
                  if Shrinks and then Compression.Accepts_Gzip (Requests.Header (Request, "Accept-Encoding"))
                    and then Exists (Full & ".gz") and then Kind (Full & ".gz") = Ordinary_File
                    and then Size (Full & ".gz") <= File_Size (Max_File_Size)
                  then
                     Response.Status := OK;
                     Responses.Set_Content_Type (Response, Media_Type);
                     Responses.Set_Header (Response, "Content-Encoding", "gzip");
                     Responses.Remove_Header (Response, "ETag");
                     Responses.Set_Header (Response, "ETag", "W/" & Tag);
                     Read (Full & ".gz", 0, Natural (Size (Full & ".gz")));
                  elsif Length > Max_File_Size then
                     Responses.Fail (Response, Not_Found);
                  else
                     Response.Status := OK;
                     Responses.Set_Content_Type (Response, Media_Type);
                     Read (Full, 0, Natural (Length));
                  end if;
            end case;
         end;
      end;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error | Ada.IO_Exceptions.End_Error =>
         Responses.Clear (Response);
         Responses.Fail (Response, Not_Found);   --  removed or unreadable between the checks and the read
   end Serve_File;

   ------------
   -- Folder --
   ------------

   package body Routes with SPARK_Mode => Off is

      overriding procedure Handle
        (This : Folder_Route; Request : Requests.Request; Response : in out Responses.Response)
      is begin
         Serve_File (Request, Response, This.Root.all, Requests.Parameter (Request, This.Capture.all), This.Max_Age);
      end Handle;

      function Make (Root : String; Capture : String; Max_Age : Natural) return Folder_Route is
        ((Root => new String'(Root), Capture => new String'(Capture), Max_Age => Max_Age));

   end Routes;

   function Folder (Root : String; Capture : String := "file"; Max_Age : Natural := 0) return Routes.Folder_Route
   is (Routes.Make (Root, Capture, Max_Age))
   with SPARK_Mode => Off;

end Sparrow.Http.Static;
