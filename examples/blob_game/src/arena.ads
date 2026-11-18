--  The game world: blobs that grow by eating pellets and each other. One protected object holds it; a task
--  steps it 30 times a second and sends every player its view over its WebSocket. Every operation is short
--  and never blocks, so the socket's handlers run on the reactors.
--
--  The rules: a blob drifts toward where its player points, slower as it grows. Touching a pellet eats it.
--  A blob 25% heavier than another eats it by covering most of it. Big blobs slowly lose mass. Bots fill the
--  arena so one player has something to chase and flee: they come in mixed sizes, run from what can eat them,
--  hunt what they can eat, graze otherwise, and come back a few seconds after being eaten.
with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;

package Arena is

   Max_Players : constant := 64;
   Bot_Count   : constant := 12;

   type Blob_Id is range 1 .. Max_Players + Bot_Count;
   subtype Player_Id is Blob_Id range 1 .. Max_Players;

   --  A new player named Name (1 .. 32 bytes), playing over Socket. Joined is False when the arena is full.
   --  From then on, 30 times a second, the player is sent what it sees, as JSON:
   --
   --     {"you": {"id", "x", "y", "r", "mass", "alive", "eaten_by"}, "size": world size,
   --      "blobs": [[id, x, y, r, hue, name], ...], "pellets": [[x, y, hue], ...],
   --      "top": [[name, mass, is_you], ...]}
   procedure Join (Name : UTF8_String; Socket : Connection_Id; Joined : out Boolean);

   --  Point Socket's player at (X, Y); back into the arena after being eaten; out of it.
   procedure Steer (Socket : Connection_Id; X, Y : Long_Float);
   procedure Respawn (Socket : Connection_Id);
   procedure Leave (Socket : Connection_Id);

   --  Start and stop the task that steps the world.
   procedure Start;
   procedure Stop;

end Arena;
