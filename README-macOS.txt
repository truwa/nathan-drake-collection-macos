Nathan Drake Collection: experimental Apple Silicon build

Requirements: Apple Silicon (M1 or newer), macOS 26 or newer, and Rosetta 2.
Intel Macs are not supported. Python and Homebrew are not required to run the
packaged app.

This download contains no game files. You need your own decrypted PS4 dump of
Uncharted: The Nathan Drake Collection (CUSA02344, CUSA02320, or CUSA02343).

1. Open NathanDrakeCollection.app.
2. Choose the game folder (eboot.bin and sce_sys).
3. If update 1.02 was dumped separately, choose that folder too. A sibling
   folder named like the game plus -patch or -update is detected automatically.
   The dumps are not copied or merged on disk.
4. Pick a game and press Play. First start prepares the game image.

Recommended first settings: Medium (1080p, 60 FPS). Graphics, upscaling, and
the frame-rate cap are in Options; the in-game menu is Insert or R3+L2.

Saves, settings and logs stay outside the application:
  ~/Library/Application Support/NathanDrakeCollection
Replacing the application preserves that folder.

If macOS blocks an ad-hoc build:
  xattr -dr com.apple.quarantine /Applications/NathanDrakeCollection.app
Do not disable Gatekeeper globally.
