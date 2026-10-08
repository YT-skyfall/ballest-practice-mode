# Ballest Practice Mode

An unofficial Practice Mode mod for **Ballest of Them All**.

Practice Mode lets you set a start point anywhere on a track and repeatedly
restart from that point without submitting practice runs to the leaderboards.

## Download

For normal players, use the **one-click installer** from the latest GitHub Release.
It installs UE4SS automatically when needed.

A manual ZIP is also published for users who already manage UE4SS themselves.

### Watch the trailer on YouTube

**▶ [Watch the Ballest Practice Mode trailer on YouTube](https://youtu.be/Qnr5Lg_EM04?si=EQH5ikE_Awmc4ZF4)**

[![Ballest Practice Mode trailer on YouTube](https://img.youtube.com/vi/Qnr5Lg_EM04/maxresdefault.jpg)](https://youtu.be/Qnr5Lg_EM04?si=EQH5ikE_Awmc4ZF4)

## Found a bug?

**[Report a bug using the simple GitHub form](https://github.com/YT-skyfall/ballest-practice-mode/issues/new?template=bug_report.yml)** — just tell me what went wrong. No technical details or logs are required. You'll need a free GitHub account to submit it.

## v1.0.2 features

- Pre-track and post-track Practice Mode entry
- Set / replace practice start
- Normal restart -> practice point
- Death -> practice point
- Full restart -> original track start
- Post-track Restart Practice
- Leaderboard protection
- Attempt HUD
- Compatibility with Ballest Steam build `25759253` (October 6 update)

## Build the installer

The repository includes an Inno Setup installer and GitHub Actions workflow.
The workflow downloads the pinned UE4SS build from the official UE4SS GitHub
release, verifies its SHA-256, bundles it with Practice Mode, and builds the EXE
on a Windows runner.

## Third-party software

The installer can bundle UE4SS. See `THIRD_PARTY_LICENSES.txt`.

## Disclaimer

Unofficial community mod. Not affiliated with or endorsed by the developers of
Ballest of Them All.
