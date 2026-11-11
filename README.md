# Saber Launcher Plugins

Extra plugins and apps for Saber Launcher. Add this repo to `plugins/pluginrepos.txt` to install
them from Saber in Online Mode: PLUGINS > Y (GET PLUGINS) and APPS > Y (GET APPS).

- `Plugins/<name>/plugin.lua` (optional `icon.png`): one plugin. You can also copy the folder into `APP/plugins/`.
- `Apps/<name>/app.lua`: one app. Saber downloads it, unpacks it into `APP/apps/<name>/` and adds the APPS card
  right away. Optional `icon.png` (card art) and `files/` (copied into the install only where the file doesn't
  exist yet, e.g. default settings).

```lua
-- Apps/<name>/app.lua
return {
    name = "My App",
    version = "1.0",          -- shown as "Update" when it differs from the installed one
    author = "Someone",
    description = "What it is.",
    download = "https://example.com/MyApp-portable.zip", -- .zip is unpacked (one top folder stripped), anything else saved as-is
    locate = { "reg:HKCU\\Software\\Vendor\\MyApp\\Path", "%ProgramFiles%\\MyApp" }, -- optional, see below
    exe = "MyApp.exe",        -- relative to the install folder
    args = "--fullscreen",
    icon = "https://example.com/icon.png", -- or a path inside the install; Apps/<name>/icon.png wins
}
```

Apps that can't (or shouldn't) be downloaded, like Steam, use `locate` and leave out `download`: a list of
registry values (`reg:HKCU\...\Value` / `reg:HKLM\...\Value`, HKLM also checks the 32-bit view) and paths
(`%ENV%` variables expanded), each naming the exe or the folder that holds `exe`. If one exists Saber only
*links* it (an APPS card pointing at that exe), and Remove only deletes the card. With both `locate` and
`download`, an existing install wins and the download is the fallback. Without a match and without `download`,
Saber reports that the app isn't installed on this PC.

| App | What it does |
|---|---|
| **Steam** | Links your installed Steam (registry / Program Files), opening with `-gamepadui`. Nothing is downloaded. |
| **QuiverLauncher** | Portable Quiver Launcher 3.5.1, set to start fullscreen with gamepad input (seeded `settings.json`). |

| Plugin | What it does | Online |
|---|---|---|
| **SaveVault** | Snapshots memory cards and save states (`libretro/saves`, PCSX2 memcards); restore any snapshot, optional auto-backup on disc insert, keeps the last N. | No |
| **PlayLog** | Logs every inserted game with a timestamp; shows recently played, most played and per-platform stats. | No |
| **GameWiki** | Shows the Wikipedia summary of inserted games (opensearch + REST summary API), cached for offline use. Text is CC BY-SA. | Yes |
