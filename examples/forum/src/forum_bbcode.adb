with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Forum_BBCode is

   type Kind is (Bold, Italic, Underline, Quote, Link);

   Closing_Html : constant array (Kind) of Unbounded_String :=
     [Bold => To_Unbounded_String ("</strong>"), Italic => To_Unbounded_String ("</em>"),
      Underline => To_Unbounded_String ("</u>"), Quote => To_Unbounded_String ("</div>"),
      Link => To_Unbounded_String ("</a>")];

   Max_Depth   : constant := 32;
   Max_Tag     : constant := 2_048;   --  the longest [url=...] looked at

   --  Text with HTML's special characters escaped; with Breaks, each line feed a <br> too, and carriage returns
   --  dropped.
   function Escaped (Text : String; Breaks : Boolean := False) return String is
      Result : Unbounded_String;
   begin
      for Symbol of Text loop
         case Symbol is
            when '&'      => Append (Result, "&amp;");
            when '<'      => Append (Result, "&lt;");
            when '>'      => Append (Result, "&gt;");
            when '"'      => Append (Result, "&quot;");
            when '''      => Append (Result, "&#39;");
            when ASCII.LF => Append (Result, (if Breaks then "<br>" & ASCII.LF else [ASCII.LF]));
            when ASCII.CR => Append (Result, (if Breaks then "" else [ASCII.CR]));
            when others   => Append (Result, Symbol);
         end case;
      end loop;
      return To_String (Result);
   end Escaped;

   function Is_Web_Address (Address : String) return Boolean is
   begin
      if Address'Length <= 8 or else (for some Symbol of Address => Symbol <= ' ' or else Symbol = '"') then
         return False;
      end if;
      declare
         Lower : constant String := To_Lower (Address (Address'First .. Address'First + 7));
      begin
         return Lower = "https://" or else Lower (Lower'First .. Lower'First + 6) = "http://";
      end;
   end Is_Web_Address;

   function Without_Quotes (Value : String) return String is
     (if Value'Length >= 2 and then Value (Value'First) = '"' and then Value (Value'Last) = '"'
      then Value (Value'First + 1 .. Value'Last - 1) else Value);

   function To_Html (Text : UTF8_String) return UTF8_String is
      Source   : constant String := String (Text);
      Result   : Unbounded_String;
      Open     : array (1 .. Max_Depth) of Kind;
      Depth    : Natural := 0;
      Position : Natural := Source'First;

      --  Where the case-insensitive Closing next starts at or after From, or 0.
      function Find (Closing : String; From : Positive) return Natural is
         Lower : constant String (From .. Source'Last) := To_Lower (Source (From .. Source'Last));
      begin
         return Ada.Strings.Fixed.Index (Lower, Closing);
      end Find;

      procedure Push (Tag : Kind; Html : String) is begin
         Depth        := Depth + 1;
         Open (Depth) := Tag;
         Append (Result, Html);
      end Push;

      --  Close Tag and every tag opened inside it; False when Tag is not open.
      function Close (Tag : Kind) return Boolean is begin
         for Level in reverse 1 .. Depth loop
            if Open (Level) = Tag then
               for Inner in reverse Level .. Depth loop
                  Append (Result, Closing_Html (Open (Inner)));
               end loop;
               Depth := Level - 1;
               return True;
            end if;
         end loop;
         return False;
      end Close;

      --  The tag that starts at Position and ends at Last, as HTML; False when it is not one of ours.
      function Took_Tag (Last : Positive) return Boolean is
         Inside : constant String := Source (Position + 1 .. Last - 1);
         Name   : constant String (Inside'Range) := To_Lower (Inside);
         Equals : constant Natural := Ada.Strings.Fixed.Index (Inside, "=");
         Value  : constant String := (if Equals = 0 then "" else Without_Quotes (Inside (Equals + 1 .. Inside'Last)));
         Head   : constant String := (if Equals = 0 then Name else Name (Name'First .. Equals - 1));
         Ending : Natural;
      begin
         if Name = "code" then
            Ending := Find ("[/code]", Last + 1);
            Append (Result, "<div class=""genmed""><b>Code:</b></div><pre class=""code"">");
            Append (Result, Escaped (Source (Last + 1 .. (if Ending = 0 then Source'Last else Ending - 1))));
            Append (Result, "</pre>");
            Position := (if Ending = 0 then Source'Last + 1 else Ending + 7);
            return True;
         elsif Name = "url" then
            Ending := Find ("[/url]", Last + 1);
            if Ending = 0 or else not Is_Web_Address (Source (Last + 1 .. Ending - 1)) then
               return False;
            end if;
            Append (Result, "<a href=""" & Escaped (Source (Last + 1 .. Ending - 1)) & """ rel=""nofollow ugc"">"
                            & Escaped (Source (Last + 1 .. Ending - 1)) & "</a>");
            Position := Ending + 6;
            return True;
         elsif Name (Name'First) = '/' then
            return
              (Name = "/b" and then Close (Bold)) or else (Name = "/i" and then Close (Italic))
              or else (Name = "/u" and then Close (Underline)) or else (Name = "/quote" and then Close (Quote))
              or else (Name = "/url" and then Close (Link));
         elsif Depth = Max_Depth then
            return False;
         elsif Name = "b" then
            Push (Bold, "<strong>");
         elsif Name = "i" then
            Push (Italic, "<em>");
         elsif Name = "u" then
            Push (Underline, "<u>");
         elsif Name = "quote" then
            Push (Quote, "<div class=""genmed""><b>Quote:</b></div><div class=""quote"">");
         elsif Head = "quote" and then Value'Length in 1 .. 64 then
            Push (Quote, "<div class=""genmed""><b>" & Escaped (Value) & " wrote:</b></div><div class=""quote"">");
         elsif Head = "url" and then Is_Web_Address (Value) then
            Push (Link, "<a href=""" & Escaped (Value) & """ rel=""nofollow ugc"">");
         else
            return False;
         end if;
         return True;
      end Took_Tag;

   begin
      while Position <= Source'Last loop
         declare
            Last : constant Natural :=
              (if Source (Position) /= '[' then 0
               else Ada.Strings.Fixed.Index (Source (Position + 1 .. Natural'Min (Source'Last, Position + Max_Tag)),
                                             "]"));
         begin
            if Last > Position + 1 then
               declare
                  Before : constant Natural := Position;
               begin
                  if Took_Tag (Last) then
                     if Position = Before then
                        Position := Last + 1;
                     end if;
                  else
                     Append (Result, '[');
                     Position := Position + 1;
                  end if;
               end;
            else
               Append (Result, Escaped (Source (Position .. Position), Breaks => True));
               Position := Position + 1;
            end if;
         end;
      end loop;
      for Level in reverse 1 .. Depth loop
         Append (Result, Closing_Html (Open (Level)));
      end loop;
      return UTF8_String (To_String (Result));
   end To_Html;

end Forum_BBCode;
