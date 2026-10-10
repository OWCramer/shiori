# Shiori compatibility

Which Steam visual novels play in [Shiori](https://github.com/OWCramer), the iOS and iPadOS app that downloads the PC games you own and runs them with native engine runtimes.

One file per engine in `engines/`, one entry per game, keyed by its Steam app id. Shiori reads these files to show a game's status on its page.

| Status | Meaning |
| --- | --- |
| `complete` | Everything the PC version has works. |
| `plays` | Playable from start to end; some extras may be missing (the notes say which). |
| `boots` | Reaches its title or first scene; not yet played through. |
| `unsupported` | Doesn't start, and the notes say why (an engine Shiori doesn't run, encryption without keys, DRM). |

## Reporting a game

Open a pull request that adds or changes an entry in the engine's file:

```json
{
  "appID": 2699690,
  "name": "Harmonia Full HD Edition",
  "status": "plays",
  "tested": "2026-10-10",
  "source": "your-github-name",
  "devices": ["iPhone Air", "iPad Pro 11-inch (M4)"],
  "notes": "What works, what doesn't, and anything a player should know (a beta branch to pick, a setting to change)."
}
```

- `source` is `shiori` for the maintainers' own tests, and your GitHub name for yours.
- `branch` names a Steam beta branch to play instead of the default build.
- `profile` (Luca System) is the screen profile Shiori uses for the game.
- `schema.json` checks the files; keep entries sorted as they are and the notes short.

Not sure which engine a game uses? Shiori's game page shows it after the download.
