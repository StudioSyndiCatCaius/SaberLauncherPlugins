-- Quiver Launcher (portable build) as a Saber App.
-- Saber downloads `download`, unpacks it into APP/apps/QuiverLauncher/ and adds an APPS card that
-- starts `exe`. files/settings.json is copied in on the first install only (never over the user's
-- own settings): it makes Quiver start fullscreen with gamepad input on, so it's usable from the
-- couch. (Quiver 3 has no command-line switch for that; anything starting with "-" makes it run
-- its CLI instead, and --kiosk hides Exit, so the app could not hand control back to Saber.)

return {
    name = "Quiver Launcher",
    version = "3.5.1",
    author = "Thomas Georgiadis",
    description = "Library launcher for apps and games from GitHub, GitLab and your own folders. "
        .. "Starts fullscreen with controller support.",
    download = "https://github.com/tgeorgiadis/quiver-launcher/releases/download/v3.5.1/QuiverLauncher-win-Portable.zip",
    exe = "QuiverLauncher.exe",
    args = "",
    -- official icon, fetched from the Quiver repo at install time (not redistributed here)
    icon = "https://raw.githubusercontent.com/tgeorgiadis/quiver-launcher/v3.5.1/Assets/quiver-icon.png",
}
