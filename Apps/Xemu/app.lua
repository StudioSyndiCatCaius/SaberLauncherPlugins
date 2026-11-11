-- xemu (original Xbox emulator), official release from github.com/xemu-project/xemu.
-- Starts fullscreen (-full-screen); its menus work with a controller (Guide / Back opens them), so
-- it's the most couch-friendly of the emulator apps. Not portable mode: config, the BIOS/MCPX/HDD
-- paths you set and the EEPROM stay in %APPDATA%\xemu and survive Remove. xemu needs the user's own
-- Xbox BIOS, MCPX boot ROM and HDD image (set them on first start).
-- Fields are plain strings on purpose: the store reads them from the text before running the file.

return {
    name = "xemu",
    version = "0.8.139",
    author = "xemu project",
    description = "Original Xbox emulator. Fullscreen, controller-navigable menus. Needs your own BIOS, MCPX ROM and HDD image.",
    download = "https://github.com/xemu-project/xemu/releases/download/v0.8.139/xemu-0.8.139-windows-x86_64.zip",
    exe = "xemu.exe",
    args = "-full-screen",
    icon = "https://raw.githubusercontent.com/xemu-project/xemu/v0.8.139/ui/icons/xemu_256x256.png",
    thumb = "https://raw.githubusercontent.com/xemu-project/xemu-website/HEAD/resources/screenshots/0.jpg",
}
