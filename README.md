# Saber Launcher Plugins

Extra plugins for Saber Launcher. Each top-level folder is one plugin
(`<name>/plugin.lua`, optional `icon.png`). Copy a folder into `APP/plugins/`, or add this repo to
`plugins/pluginrepos.txt` to install them from Saber in Online Mode.

| Plugin | What it does | Online |
|---|---|---|
| **SaveVault** | Snapshots memory cards and save states (`libretro/saves`, PCSX2 memcards); restore any snapshot, optional auto-backup on disc insert, keeps the last N. | No |
| **PlayLog** | Logs every inserted game with a timestamp; shows recently played, most played and per-platform stats. | No |
| **GameWiki** | Shows the Wikipedia summary of inserted games (opensearch + REST summary API), cached for offline use. Text is CC BY-SA. | Yes |
