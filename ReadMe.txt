Sinclair Pac Manic Miner Man Spectrum (v0.1)
--------------------------------------------

This is a proof-of-concept project to show Jim Bagley's Pac Manic Miner Man
ROMs, written for the Pac-Man hardware, running back on the Spectrum +2A/+3.

Note: this project is *INCOMPLETE*, and only contains sprites for the first
two levels of the game.  If you'd like to convert additional sprites or tiles
for later levels, please get in touch.

The ROMs are not supplied with this program, but are currently available from:

  http://www.jimbagley.co.uk/PacManicMinerMan/pacmmm.zip

You'll need the following files from the archive:

  pacmmm.6e pacmmm.6f pacmmm.6h pacmmm.6j

Copy them to the same directory as this file, then run make.bat (Windows).
Under Mac/Linux/Un*x, use make to build the final pacminer.tap image file,
or combine manually using:

  cat start.part pacmmm.6[efhj] end.part > pacminer.tap

Enjoy!

---

Version 0.1 (2013/06/04)
- Initial release

---

Simon Owen
http://simonowen.com/
