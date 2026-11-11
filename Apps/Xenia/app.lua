-- Xenia Canary (Xbox 360 emulator), the actively developed build, from
-- github.com/xenia-canary/xenia-canary-releases (release tag = commit). Not portable mode, so content,
-- saves and config stay in Documents\Xenia and survive Remove (create portable.txt next to the exe
-- to keep them in the app folder instead).
-- No big-picture UI: without a game it opens an empty window (File > Open). Canary updates often; this
-- recipe is pinned so Saber's Update badge is accurate.
-- Fields are plain strings on purpose: the store reads them from the text before running the file.

return {
    name = "Xenia Canary",
    version = "02d2cb5",
    author = "Xenia Canary team",
    description = "Xbox 360 emulator (experimental Canary build). Opens a game with File > Open; no controller-first menus.",
    download = "https://github.com/xenia-canary/xenia-canary-releases/releases/download/02d2cb5/xenia_canary_windows_.zip",
    exe = "xenia_canary.exe",
    args = "",
    icon = "https://raw.githubusercontent.com/xenia-canary/xenia-canary/canary_experimental/assets/icon/256.png",
}
