# Practice Mode — Plugin Manager edition

A source-only port of **Ballest Practice Mode** for the
[AnythingGoes Ballest Plugin Manager](https://github.com/AnythingGoes-ballest/ballest-plugin-manager).

## What it does

- Set or replace one practice point anywhere on a track.
- Normal restart, checkpoint respawn, and falls return to the saved practice point.
- Full restart returns to the original track start.
- Shows a small Practice Mode HUD with attempt count.
- Uses the Plugin Manager's `Race::StartPractice()` / `Race::LoadBall()` safety path so a restored practice position cannot submit a leaderboard time.
- Uses only the public Plugin Manager API. There is no `Console::` access and no binary code in this plugin.

## Important

This is a separate implementation from the standalone UE4SS edition.

**Do not run the standalone UE4SS Practice Mode and this Plugin Manager edition at the same time.**
They both react to race restarts and would interfere with each other.

## Using it

1. Open a track and start the race.
2. Open the Plugin Manager footer and choose **practice mode**.
3. Click **set practice point** where you want to practice.
4. Use Ballest's normal restart or die/fall to return to the practice point.
5. Use Ballest's full restart to return to the original track start.
6. Use **clear practice point** when you are done.

If you have rebound Ballest's full-restart control, set **Full restart key** in this plugin's settings to the same key/button.

## Local testing

Copy this `practice-mode` folder into Ballest's Plugin Manager `plugins` folder and restart Ballest.

The host log is at:

`%LOCALAPPDATA%\Ballest\Saved\PluginManager\host.log`

Before registry submission, verify:

- the plugin compiles with no errors or warnings;
- setting/replacing a point works;
- normal restart returns to the point;
- checkpoint respawn returns to the point;
- a fall returns to the point;
- full restart returns to the original start;
- the practice HUD and attempt count behave correctly;
- a practice run cannot finish or submit a leaderboard time.

## Screenshot

A screenshot of the Plugin Manager edition will be added after the first in-game test.

## Versioning

The Plugin Manager edition has its own version number. Its first registry version is **0.1.0**.

## Disclaimer

Unofficial community mod. Not affiliated with or endorsed by the developers of Ballest of Them All.
