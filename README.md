# Nathan Drake Collection for Mac

Experimental Apple Silicon launcher for [BilalReloaded](https://github.com/bc160201983)’s PC port of *Uncharted: The Nathan Drake Collection*.

**This repository does not contain game files.** You need your own decrypted PS4 dump. The launcher is not affiliated with Sony, Naughty Dog, or Bluepoint.

## Requirements

- Apple Silicon (M1 or newer)
- macOS 26 or newer
- Rosetta 2
- A decrypted dump of CUSA02344, CUSA02320, or CUSA02343 (`eboot.bin`, `sce_sys`, `u1data` / `u2data` / `u3data`)
- A local [BilalReloaded](https://github.com/bc160201983) native probe (`gow3-probe`) plus KosmicKrisp. Point the app at it with `UNCHARTED_NATIVE`, or keep a `native-root.txt` next to the app resources.

Intel Macs are not supported. Python and Homebrew are not required to run the packaged app.

## Use

1. Open `NathanDrakeCollection.app`.
2. Choose the game folder (`eboot.bin` and `sce_sys`).
3. If update 1.02 was dumped separately, choose that folder too. A sibling folder named like the game plus `-patch` or `-update` is detected automatically. Dumps are not copied or merged on disk.
4. Pick a game and press Play.

Recommended first settings: Medium (1080p, 60 FPS) in **Game Settings**. The in-game menu is Insert or R3+L2.

Saves, settings, and logs stay in `~/Library/Application Support/NathanDrakeCollection`. Replacing the app preserves that folder.

If macOS quarantines a download:

```
xattr -dr com.apple.quarantine /Applications/NathanDrakeCollection.app
```

Do not disable Gatekeeper globally.

## Credits

- **PC port:** BilalReloaded, from SuperMedo’s Bloodborne / Uncharted work
- **KosmicKrisp:** Mesa Vulkan on Metal (MIT)
- **SpartanPort:** God of War III Remastered Mac launcher — the Apple Silicon, KosmicKrisp, and packaging model for this app ([SpartanPort](https://github.com/FelipePrado0/SpartanPort); Fleurat, nizwar, Incognito-Coder)
- **This launcher:** MacGameTest

See `NOTICES.txt` and Credits & Licenses in the app.
