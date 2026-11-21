--  The forum's post markup: a post's text as HTML, with [b] [i] [u] [code] [quote] [quote="name"] [url] and
--  [url=address] made into tags and everything else escaped. Only http and https addresses become links. A tag
--  left open is closed at the end of the post; a closing tag with nothing to close stays text.
with Sparrow; use Sparrow;

package Forum_BBCode is

   function To_Html (Text : UTF8_String) return UTF8_String;

end Forum_BBCode;
