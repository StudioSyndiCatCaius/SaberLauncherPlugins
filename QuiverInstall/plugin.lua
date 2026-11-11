-- QuiverInstall: downloads the portable Quiver Launcher build from its GitHub releases,
-- extracts it into APP/apps/QuiverLauncher/ and registers it as a Saber App
-- (APP/apps/QuiverLauncher.toml). Saber scans apps at startup, so the card shows up after a restart.

local URL = "https://github.com/tgeorgiadis/quiver-launcher/releases/latest/download/QuiverLauncher-win-Portable.zip"
local APPS_DIR = SABER_DIR .. "/apps"
local INSTALL_DIR = APPS_DIR .. "/QuiverLauncher"
local TOML = APPS_DIR .. "/QuiverLauncher.toml"
local ZIP = "QuiverLauncher-win-Portable.zip" -- relative = plugin folder

local busy = false

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function win(path) return (path:gsub("/", "\\")) end

-- Finds the launcher exe: root of the install folder first, then any subfolder.
local function find_exe()
    local best
    for _, f in ipairs(List_Dir(INSTALL_DIR)) do
        if f:lower():match("%.exe$") then
            if f:lower():find("quiver") then return INSTALL_DIR .. "/" .. f end
            best = best or (INSTALL_DIR .. "/" .. f)
        end
    end
    if best then return best end
    local p = io.popen('dir /b /s "' .. win(INSTALL_DIR) .. '\\*.exe" 2>nul')
    if not p then return nil end
    for line in p:lines() do
        local l = line:lower()
        if not l:find("unins") and not l:find("crashpad") and not l:find("update") then
            if l:find("quiver") then best = line break end
            best = best or line
        end
    end
    p:close()
    return best and best:gsub("\\", "/") or nil
end

local function write_toml(exe)
    local f = io.open(TOML, "wb")
    if not f then return false end
    f:write('name="Quiver Launcher"\n')
    f:write('exe="' .. exe .. '"\n')
    f:write('exe_args=""\n')
    f:close()
    return true
end

local function installed()
    return exists(TOML) and find_exe() ~= nil
end

local function install()
    if busy then return "Already installing..." end
    if not Online() then return "Turn on Online Mode first (Settings > Online Mode)" end
    busy = true
    local done, ok_result, err_text = false, nil, nil
    Http_Download(URL, ZIP, function(ok, err, status)
        if not ok then
            done, ok_result, err_text = true, false, "Download failed: " .. tostring(err or status)
            return
        end
        local uok, uerr = Unzip(ZIP, INSTALL_DIR)
        os.remove(PLUGIN_DIR .. "/" .. ZIP)
        if not uok then
            done, ok_result, err_text = true, false, "Extract failed: " .. tostring(uerr)
            return
        end
        local exe = find_exe()
        if not exe then
            done, ok_result, err_text = true, false, "No .exe found in the download"
            return
        end
        if not write_toml(exe) then
            done, ok_result, err_text = true, false, "Couldn't write " .. TOML
            return
        end
        saber.log("QuiverInstall: installed " .. exe)
        done, ok_result = true, true
    end)
    Dialog_Process("Downloading Quiver Launcher...", function()
        if done then return 1 end
        return 0.5
    end, function(cancelled)
        busy = false
        if cancelled and not done then
            Dialog_Info("The download continues in the background.", { "OK" }, function() end)
        elseif ok_result then
            Dialog_Info("Quiver Launcher installed.\nRestart Saber to see it on the APPS tab.", { "OK" }, function() end)
        else
            Dialog_Info(err_text or "Install failed", { "OK" }, function() end)
        end
    end)
    return "Installing Quiver Launcher..."
end

local function uninstall()
    os.remove(TOML)
    os.execute('rmdir /s /q "' .. win(INSTALL_DIR) .. '" 2>nul')
    return "Quiver Launcher removed (restart Saber to update APPS)"
end

return {
    name = "Quiver Install",
    version = "1.0",
    author = "Saber",
    description = "Downloads the portable Quiver Launcher and adds it as a Saber App.",
    actions = {
        install = {
            name = "Install / Update Quiver Launcher",
            description = "Download the latest portable release into APP/apps/QuiverLauncher.",
            online = true,
            Do = install,
        },
        uninstall = {
            name = "Remove Quiver Launcher",
            description = "Delete the app folder and its APPS entry.",
            Do = function()
                if not installed() and not exists(TOML) then return "Not installed" end
                Dialog_Info("Remove Quiver Launcher?", { "Remove", "Cancel" }, function(i)
                    if i == 1 then saber.log(uninstall()) end
                end)
                return "Confirm removal..."
            end,
        },
    },
}
