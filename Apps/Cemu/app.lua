-- Cemu (Wii U emulator), official release zip from github.com/cemu-project/Cemu.
-- Unpacked into APP/apps/Cemu/app (the zip's Cemu_<version>/ folder is stripped). Not portable mode,
-- so keys, the MLC (installed games/updates) and saves stay in %APPDATA%\Cemu and survive Remove.
-- No big-picture UI: Cemu's game list is a normal window (mouse/keyboard). `-f` only fullscreens a
-- game started with `-g`, so it isn't passed here.
-- Fields are plain strings on purpose: the store reads them from the text before running the file.

return {
    name = "Cemu",
    version = "2.6",
    author = "Cemu team",
    description = "Wii U emulator. Game list window, no controller-first UI (set up controllers in Options > Input).",
    download = "https://github.com/cemu-project/Cemu/releases/download/v2.6/cemu-2.6-windows-x64.zip",
    exe = "Cemu.exe",
    args = "",
    icon = "https://raw.githubusercontent.com/cemu-project/Cemu/v2.6/src/resource/logo_icon.png",
}
