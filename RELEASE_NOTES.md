# Ballest Practice Mode v1.0.2

Compatibility update for Ballest's October 6, 2026 update.

## Updated
- Added support for Ballest Steam build `25759253`.
- Retained support for the previous tested Steam build `25608493`.
- Verified Practice Mode entry before a track and from the results screen.
- Verified set/replace practice point, normal restart, death/respawn, full restart, and post-track Restart Practice.
- Verified Ballest's new results-screen restart-race bind works correctly with Practice Mode.
- Verified the mandatory leaderboard protection hooks remain ready on build `25759253`.
- Added restart-hook readiness to the F8 diagnostics.

## Safety
Practice Mode remains fail-closed. Unknown Ballest builds are disabled until they are explicitly tested and added.

Practice runs remain blocked from leaderboard submission by the existing primary and secondary protections.

## Recommended download
**Ballest-PracticeMode-Installer.exe**

The installer detects Ballest, installs UE4SS automatically if needed, installs Practice Mode, and enables it.

## Manual download
**Ballest-PracticeMode-v1.0.2.zip**

> Practice Mode is an unofficial community mod and is not affiliated with or endorsed by the developers of Ballest of Them All.
