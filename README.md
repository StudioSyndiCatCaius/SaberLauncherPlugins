# Saber Launcher Plugins

Extra plugins and apps for Saber Launcher. Add this repo to `plugins/pluginrepos.txt` to install
them from Saber in Online Mode: PLUGINS > Y (GET PLUGINS) and APPS > Y (GET APPS).

- `Plugins/<name>/plugin.lua` (optional `icon.png`): one plugin. You can also copy the folder into `APP/plugins/`.
- `Apps/<name>/app.lua`: one app. Saber downloads it, unpacks it into `APP/apps/<name>/` and adds the APPS card
  right away. Optional `icon.png` (card art in the store and on APPS), `thumb.png` / `thumb.jpg` (screenshot shown
  in the store) and `files/` (copied into the install only where the file doesn't exist yet, e.g. default settings).
  Apps without an icon get a coloured tile with their initials.

```lua
-- Apps/<name>/app.lua
return {
    name = "My App",
    version = "1.0",          -- shown as "Update" when it differs from the installed one
    author = "Someone",
    description = "What it is.",
    download = "https://example.com/MyApp-portable.zip", -- .zip is unpacked (one top folder stripped), anything else saved as-is
    locate = { "reg:HKCU\\Software\\Vendor\\MyApp\\Path", "%ProgramFiles%\\MyApp" }, -- optional, see below
    installer = "/S /D={dir}", -- optional: the download is an installer, run silently into {dir} instead of unpacked
    uninstall = "uninstall.exe /S _?={dir}", -- optional: run before Remove deletes the folder
    exe = "MyApp.exe",        -- relative to the install folder
    args = "--fullscreen",
    icon = "https://example.com/icon.png", -- or a path inside the install; Apps/<name>/icon.png wins
    thumb = "https://example.com/screenshot.png", -- store preview; Apps/<name>/thumb.png (or .jpg) wins
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
| **Cemu** | Wii U emulator 2.6 (official zip). Normal game-list window; no controller-first UI. |
| **Xenia** | Xenia Canary (Xbox 360), pinned build `02d2cb5`. Opens games via File > Open; no controller-first UI. |
| **Xemu** | xemu 0.8.139 (original Xbox), starts fullscreen with controller-navigable menus. Needs your own BIOS/MCPX/HDD. |
| **Steam** | Links your installed Steam (registry / Program Files), opening with `-gamepadui`. Nothing is downloaded. |
| **QuiverLauncher** | Big Quiver Launcher (the Big Picture fork of Quiver 4, alpha): links an existing install, or installs it silently; opens with `--bigpicture`. |

| Plugin | What it does | Online |
|---|---|---|
| **SaveVault** | Snapshots memory cards and save states (`libretro/saves`, PCSX2 memcards); restore any snapshot, optional auto-backup on disc insert, keeps the last N. | No |
| **PlayLog** | Logs every inserted game with a timestamp; shows recently played, most played and per-platform stats. | No |
| **GameWiki** | Shows the Wikipedia summary of inserted games (opensearch + REST summary API), cached for offline use. Text is CC BY-SA. | Yes |

Keep `app.lua` fields as plain string literals: the store reads `name`, `version`, `description`, `download`, `icon` and
`thumb` from the text before it runs the file.

## Styles (Saber Styler)

The **Saber Styler** channel (`Channels/SaberStyler`, install it from the Channel Shop) downloads, previews
and applies looks for Saber. Its catalog is `Channels/SaberStyler/styles/` (other repos with the same folder
can be added to the channel's `sources.txt`). The channel's `info.toml` has `shop_exclude = "styles"`, so the
Channel Shop installs the channel without it; the Styler downloads each item on demand.

- `styles/themes/<Name>/`: a UI shader theme (the same files as Saber's `themes/<name>/`, see Saber's
  `themes/README.md`), installed into Saber's `themes/`. Optional `info.toml` (`name`, `description`,
  `author`, `version`) and art: `thumbnail.glsl` (Shadertoy-style, like a channel thumbnail) or `preview.png|jpg`.
- `styles/wallpapers/<file>`: a picture or a Shadertoy-style `.glsl` animated wallpaper. Optional `<stem>.toml`.
- `styles/music/<file>`: menu music (`mp3`, `ogg`, `wav`, `flac`). Optional `<stem>.toml` and a `<stem>.png|jpg` cover.

Updates are detected from the files themselves (git blob shas), so you don't need to bump a version. Themes,
wallpapers and music already on the PC that the Styler didn't install are never overwritten or removed.

Any channel can use `shop_exclude = "folder, other/folder"` in its `info.toml` to keep sub-folders out of the
Channel Shop install.

A channel with `private = true` in its `info.toml` isn't listed in the Channel Shop and can't be installed
from it (use it for work in progress).
