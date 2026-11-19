-- Big Quiver Launcher: the Big Picture fork of Quiver Launcher 4
-- (github.com/OldRustyDusty/quiver-launcher-big-picture), a fullscreen, controller-first launcher.
-- An existing install (the fork's installer puts it in %LOCALAPPDATA%\Big Quiver Launcher) is just
-- linked. Otherwise Saber downloads the release's NSIS installer and runs it silently into
-- APP/apps/QuiverLauncher/app (per-user, no admin). `--bigpicture` opens straight into Big Picture.
-- Remove runs the fork's uninstaller first, so the Start menu entry and the Windows "Apps" entry go too.
-- Alpha software, built on the unreleased Quiver Launcher 4.

-- Fields are plain strings on purpose: the store reads them from the text before running the file.

return {
    name = "Big Quiver Launcher",
    version = "4.0.0-alpha.1-bigpicture.3",
    author = "OldRustyDusty (fork of Quiver Launcher by Thomas Georgiadis)",
    description = "Quiver Launcher with a Big Picture mode: browse, download and play games fullscreen "
        .. "with a controller. Unofficial fork, alpha.",
    locate = {
        "%LOCALAPPDATA%\\Big Quiver Launcher",
        "%ProgramFiles%\\Big Quiver Launcher",
    },
    download = "https://github.com/OldRustyDusty/quiver-launcher-big-picture/releases/download/v4.0.0-alpha.1-bigpicture.3/Big.Quiver.Launcher_4.0.0-alpha.1-bigpicture.3_x64-setup.exe",
    installer = "/S /D={dir}", -- NSIS: silent, into APP/apps/QuiverLauncher/app (/D must be last, unquoted)
    uninstall = "uninstall.exe /S _?={dir}", -- _?= runs it in place, so Saber can wait for it
    exe = "quiver-launcher.exe", -- the README says "Big Quiver Launcher.exe", the installer ships this
    args = "--bigpicture",
    -- official art, fetched from the fork's repo by Saber (not redistributed here)
    icon = "https://raw.githubusercontent.com/OldRustyDusty/quiver-launcher-big-picture/v4.0.0-alpha.1-bigpicture.3/apps/launcher/src-tauri/icons/128x128@2x.png",
    thumb = "https://raw.githubusercontent.com/OldRustyDusty/quiver-launcher-big-picture/v4.0.0-alpha.1-bigpicture.3/docs/bigpicture/images/home.webp",
}
