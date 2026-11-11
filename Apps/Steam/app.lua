-- Steam: never downloaded. Saber looks for the copy installed on this PC and only adds an APPS
-- card that starts it (in Big Picture / gamepad UI). Remove drops the card; Steam stays installed.
-- `locate` is tried in order; an entry may name steam.exe itself or the folder holding it.

return {
    name = "Steam",
    version = "1.0",
    author = "Saber",
    description = "Adds your installed Steam to APPS, opening in Big Picture mode. Nothing is downloaded.",
    locate = {
        "reg:HKCU/Software/Valve/Steam/SteamExe",
        "reg:HKLM/SOFTWARE/Valve/Steam/InstallPath",
        "%ProgramFiles(x86)%/Steam",
        "%ProgramFiles%/Steam",
    },
    exe = "steam.exe",
    args = "-gamepadui",
}
