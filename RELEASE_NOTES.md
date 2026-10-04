# Ballest Practice Mode v1.0.1

Small compatibility and reliability update.

## Fixed
- Fixed an intermittent cold-launch issue where the **Mods** button could be missing from Ballest's main menu until the player entered a track and returned.
- Practice Mode now scans for an already-created main-menu widget after startup instead of relying only on the new-object callback.
- If the menu was already constructed before Practice Mode loaded, it now rebuilds the visible rows once so the **Mods** entry actually appears.
- Startup recovery retries briefly and rebuilds each concrete main-menu widget at most once.

## Existing features
- Enter Practice Mode before a track or from the results screen.
- Set or replace a practice start point.
- Normal restart and death return to the practice point.
- Full restart returns to the original track start.
- Practice runs cannot submit leaderboard scores.
- HUD shows Practice Mode state and attempt count.

## Recommended download
**Ballest-PracticeMode-Installer.exe**

The installer detects Ballest, installs UE4SS automatically if needed, installs Practice Mode, and enables it.

## Manual download
**Ballest-PracticeMode-v1.0.1.zip**

> Practice Mode is an unofficial community mod and is not affiliated with or endorsed by the developers of Ballest of Them All.
