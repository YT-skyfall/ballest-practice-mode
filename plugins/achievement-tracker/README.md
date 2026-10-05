# Achievement Tracker

An in-game tracker for the 16 Steam achievements in **Ballest of Them All**.

## Current 0.1.0 status

The current Plugin Manager API does **not** expose Steam achievement unlock state or Steam stat values to plugins.

Because of that, 0.1.0 is deliberately a **local-progress beta**:

- It shows all 16 Steam achievement goals in game.
- It tracks the achievements the public Plugin Manager API can infer safely.
- Progress is stored locally by the plugin and survives restarts.
- It can pin any achievement to a small in-game HUD.
- Achievements that cannot be measured reliably with the current API are labelled **Steam sync needed** rather than guessed.

It never calls Steam achievement mutation functions and cannot unlock, clear, or modify Steam achievements.

## Locally tracked in 0.1.0

- The Show Begins
- Great Heights
- Architect
- It's MY track now
- I Would Roll 500 Miles
- Bouncy
- Practice Makes Perfect
- Grounded
- 20 Flat
- Take that!
- Glacial Pace
- Fastball

The following need read-only Steam/game stat support from the host before they can be accurate:

- One Wet Ball
- Air Apparent
- Ahhhh!!!!
- Ahhhh.....

## Important

Local progress begins when this plugin is installed. It is **not yet a replacement for Steam's own unlock state**.

A future version should switch the data layer to read-only Steam achievement/stat APIs when the Plugin Manager exposes them.

## Install for testing

Copy this `achievement-tracker` folder into Ballest's Plugin Manager `plugins` folder and restart the game.

Use the **achievements** footer button to open the browser.

## Safety

This plugin is read-only with respect to Steam achievements. It does not use `Console::` and does not modify leaderboard eligibility, physics, Steam stats, or achievement state.
