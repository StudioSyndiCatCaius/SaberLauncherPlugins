# Adding mods to ModHack

ModHack reads the `Channels/ModHack/mods/` folder of every repo in its `sources.txt`. To add a mod,
add a folder there and push. No index file to update.

```
mods/<platform>/<game>/
    gameids.txt          which games this is (required)
    game.ini             name, description (optional)
    thumbnail.png        game art, 16:9 (optional; also preview.* / cover.*)
    presets.ini          Mods-menu presets for its soft mods (optional, Saber's format)
    soft/<Mod>/          soft mods
    hard/<Mod>/          hard mods
```

`<platform>` is Saber's platform folder: `pc`, `ps1`, `ps2`, `psp`, `nes`, `snes`, `n64`, `gb`,
`gbc`, `gba`, `nds`, `3ds`, `gc`, `wii`, `md`, `sms`, `gg`, `pce`, `dc`, `a2600`, `ps3`. Folders
starting with `_` or `.` are ignored, so you can keep drafts there.

## gameids.txt

One ID per line (`#` lines are comments, case doesn't matter). A game in the player's library matches if
any of these equals a line:

- disc serial (`SCUS-94163`): discs, installed discs, `_Saber` games with `serial=`
- ROM file name without extension (`Super Mario World (USA)`)
- ROM CRC32 (`b19ed489`)
- the game's title or its folder name: how **PC** games are matched

Soft mods also use this file: it's copied to `APP/mods/<platform>/<Game>/gameids.txt`, which is how
Saber finds the mods when the game starts.

## The mod folder

Every file in the mod folder is part of the mod. These are special:

| File | |
|---|---|
| `mod.ini` | `name`, `author`, `version`, `description` (repeat the line for more paragraphs), `url`, `file`, `size`, `homepage`, `crc` |
| `install.lua` | optional install script (below) |
| `thumbnail.*` / `preview.*` | 16:9 art |

- `url`: an external download (most mods: the archive from the author's own site, GitHub release,
  etc.). Downloaded through Saber (resumable, shows a progress card). A `.zip` is unpacked; anything
  else is kept as-is.
- `file`: the downloaded file's name, when the URL doesn't end in one.
- `size`: download size in bytes, shown before installing.
- `homepage`: shown as an "Open web page" button (credit the author!).
- `crc`: hard mods: the CRC32 of the ROM the patch was made for. A mismatch warns before patching.

Changing any file in the mod folder (including `mod.ini`) shows the mod as **Update** for people who
installed it.

## Soft mods (`soft/<Mod>/`)

Kept apart from the game in `APP/mods/<platform>/<Game>/<Mod>/` and loaded by Saber when the game
starts; players turn them on and off from the game's **Mods** menu. This is Saber's own mod format
(`mod.lua`, see Saber's `docs/mods.md`). If the player already has a folder in `APP/mods/<platform>/`
whose `gameids.txt` lists the game, mods go into it, so Saber never loads two copies.

Install: ModHack copies the mod folder (minus `install.lua`) to the mod's folder. If `mod.ini` has a
`url` and there's no `install.lua`, the download (unpacked) is copied in as well. Remove deletes the
folder.

## Hard mods (`hard/<Mod>/`)

Change the game's own files: ROM hacks, files dropped into a PC game's folder. The game must be in the
player's library (GAMES tab). Before installing, ModHack warns and recommends a **full copy** of the
game under a new name (default `<Game> - <Mod>`), which then shows up in GAMES as its own game:

- loose ROM: `<name>.<ext>` next to the original (side cover copied too)
- `.cue` / `.gdi` / `.m3u` image: a folder `<name>/` with the image's files + `_Saber/saber.ini`
- `_Saber` folder game (PC games, installed discs): the whole folder, `title=` renamed, play records left out

Install with no `install.lua`: the mod's single `.ips` or `.bps` (from the download or the mod folder)
is applied to the game's ROM. BPS checks it's the right ROM and that the result is correct; a SNES ROM
with a 512-byte copier header is handled. Anything else needs an `install.lua`.

Remove: a copy is deleted. On the original, the files the mod backed up are put back.

## install.lua

Returns a table with `install(m)` and optionally `uninstall(m)`. Both run as a coroutine, so long
loops are fine; call `m.step()` in tight ones so Saber keeps drawing. Raise an error (`error("...")`)
to fail; the player sees the message and a copy made for the install is deleted.

```lua
-- hard/Restored Content/install.lua: a PC mod whose zip holds an "override" folder
return {
	install = function(m)
		local src = m.files .. "/override"
		for _, rel in ipairs(m.walk(src)) do
			local dest = m.game.root .. "/override/" .. rel
			m.backup(dest)                 -- only backs up on the original game, never on a copy
			m.copy(src .. "/" .. rel, dest)
		end
	end,
}
```

What `m` holds:

| Field | |
|---|---|
| `m.mod` | `{name, author, version, type, url, key}` |
| `m.repo` | the mod folder's files, downloaded |
| `m.files` | the `url` download, unpacked if it was a zip (empty without `url`) |
| `m.download` | path of the downloaded file itself (nil without `url`) |
| `m.game` | hard mods: the target game: `{title, platform, kind, root, rom, file, crc, serial, saber}` (`root == rom` for a loose ROM; `saber` = its `_Saber` folder) |
| `m.is_copy` | true when installing on a fresh copy |
| `m.mod_dir` | soft mods: the mod's folder in `APP/mods`, already holding the repo files |

| Helper | |
|---|---|
| `m.copy(from, to)` | file or whole folder (raises on failure) |
| `m.read(path)` / `m.write(path, data)` | whole files |
| `m.remove(path)` | file or folder (folders only below Saber's APP folder) |
| `m.walk(dir)` | every file below dir, relative paths |
| `m.exists(path)`, `m.is_dir(path)`, `m.size(path)` | |
| `m.unzip(zip, dest)` | |
| `m.ini_set(path, key, value)` | edit one line of an ini (e.g. a `_Saber/saber.ini`'s `exe=`) |
| `m.backup(path)` | save a game file before changing it; Remove restores it (no-op on a copy) |
| `m.patch(file, patch [, out])` | apply an `.ips` / `.bps` (backs `file` up first) |
| `m.patches([dir])` | the `.ips` / `.bps` files below dir (default `m.files`) |
| `m.fetch(url, path)` | download another file (waits) |
| `m.ask(text, {options})` | ask the player; returns the picked index or nil |
| `m.progress(frac, text)` | the progress line (`frac < 0` = busy) |
| `m.crc32(data)`, `m.step()`, `m.log(text)` | |

Not built in yet: xdelta / UPS patches, 7z / rar archives.
