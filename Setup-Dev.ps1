<#
.SYNOPSIS
    Interactive setup for a NUC-style always-on Windows dev machine (Claude development).

.NOTES
    By Lachlan Scott. Script written with Claude (Anthropic).

.DESCRIPTION
    Shows a checklist menu. Toggle items by number, press Enter to run the selected ones.
    Safe to re-run: every step checks current state first. A log is written to
    %USERPROFILE%\DevNUC-Setup.log

    Run from a file:
        powershell -ExecutionPolicy Bypass -File .\Setup-Dev.ps1
    Run straight from GitHub:
        irm https://raw.githubusercontent.com/lachlanscott22/Setup-Dev/main/Setup-Dev.ps1 | iex
#>

#Requires -Version 5.1

# ---------------------------------------------------------------- self-elevate
$RawUrl = 'https://raw.githubusercontent.com/lachlanscott22/Setup-Dev/main/Setup-Dev.ps1'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Restarting as Administrator..." -ForegroundColor Yellow
    $self = $PSCommandPath
    if (-not $self) {
        # Started via "irm | iex": there is no file on disk, so fetch a copy to run elevated
        $self = Join-Path $env:TEMP 'Setup-Dev.ps1'
        Invoke-RestMethod -Uri $RawUrl -OutFile $self
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$self`""
    return
}

$ErrorActionPreference = 'Continue'
$script:RebootNeeded = $false
$LogFile = Join-Path $env:USERPROFILE 'DevNUC-Setup.log'
Start-Transcript -Path $LogFile -Append | Out-Null

# ---------------------------------------------------------------- helpers
function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "    [x]  $m" -ForegroundColor Red }

function Ask-YesNo($prompt, [bool]$default = $true) {
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = (Read-Host "$prompt $hint").Trim().ToLower()
        if ($a -eq '') { return $default }
        if ($a -in 'y','yes') { return $true }
        if ($a -in 'n','no')  { return $false }
    }
}

function Ask-Value($prompt, $default) {
    $suffix = if ($default) { " [$default]" } else { '' }
    $a = (Read-Host "$prompt$suffix").Trim()
    if ($a -eq '') { return $default }
    return $a
}

function Test-Winget { [bool](Get-Command winget -ErrorAction SilentlyContinue) }

function Install-WingetPackage($id, $name, $extra = @()) {
    if (-not (Test-Winget)) { Write-Fail "winget not found (install 'App Installer' from the Store)."; return }
    $installed = winget list --id $id --exact --accept-source-agreements 2>$null | Select-String -SimpleMatch $id
    if ($installed) { Write-Ok "$name already installed"; return }
    Write-Host "    Installing $name..."
    winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements @extra
    if ($LASTEXITCODE -eq 0) { Write-Ok "$name installed" } else { Write-Fail "$name failed (exit $LASTEXITCODE)" }
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}

function Set-RegValue($path, $name, $value, $type = 'DWord') {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name $name -Value $value -Type $type -Force
}

function Test-IPv4($s) { $ip = $null; [System.Net.IPAddress]::TryParse($s, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork' }

# ---------------------------------------------------------------- actions
function Do-RestorePoint {
    Write-Step "Creating a restore point"
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        # Windows limits restore points to one per 24h by default; lift that for this run
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description 'Before DevNUC setup' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Ok "Restore point created"
    } catch { Write-Warn2 "Could not create restore point: $($_.Exception.Message)" }
}

function Do-Rename {
    Write-Step "Computer name"
    $new = $null
    while ($true) {
        $new = Ask-Value "What should this computer be called? (current: $env:COMPUTERNAME)" 'Development'
        if ($new -match '^[A-Za-z0-9-]{1,15}$' -and $new -notmatch '^\d+$') { break }
        Write-Fail "Invalid name (letters, digits, hyphen; max 15 chars; not all digits)."
    }
    if ($new -ieq $env:COMPUTERNAME) { Write-Ok "Already named $new"; return }
    Rename-Computer -NewName $new -Force
    $script:RebootNeeded = $true
    Write-Ok "Renamed to $new (applies after reboot)"
}

function Do-Power {
    Write-Step "Power settings: never sleep"
    # Prefer High performance if present, otherwise tune the active plan
    $hp = powercfg /list | Select-String 'High performance' | ForEach-Object { ($_ -split '\s+')[3] } | Select-Object -First 1
    if ($hp) { powercfg /setactive $hp; Write-Ok "High performance plan active" }
    else     { Write-Warn2 "No High performance plan; tuning the active plan instead" }

    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change hibernate-timeout-dc 0
    powercfg /change disk-timeout-ac 0
    powercfg /change disk-timeout-dc 0
    powercfg /change monitor-timeout-ac 0     # screen stays on; remove this line if you prefer display off
    powercfg /change monitor-timeout-dc 0
    powercfg /hibernate off                    # also disables Fast Startup
    # Lid close / power button do nothing (laptop-style NUCs)
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    # USB selective suspend off (keeps USB devices / dongles alive)
    powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
    powercfg /setactive SCHEME_CURRENT
    Write-Ok "Sleep, hibernate, disk and display timeouts disabled; Fast Startup off"

    # Stop NIC from powering down so RDP/Tailscale stay reachable
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object {
        try { Disable-NetAdapterPowerManagement -Name $_.Name -NoRestart -ErrorAction Stop; Write-Ok "NIC power saving off: $($_.Name)" } catch {}
    }
}

function Do-RDP {
    Write-Step "Enabling Remote Desktop"
    $os = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($os -match 'Home') { Write-Fail "$os cannot host RDP. Upgrade to Pro first."; return }
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
    Set-Service TermService -StartupType Automatic
    Start-Service TermService -ErrorAction SilentlyContinue
    # Network Level Authentication on (more secure)
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1
    Write-Ok "RDP enabled with NLA, firewall rule on"
    Write-Warn2 "The account you log in with needs a password (blank passwords can't RDP)."
    Write-Warn2 "Do NOT port-forward 3389 on your router. Use Tailscale or a VPN instead."
}

function Do-StaticIP {
    Write-Step "Static IP address"
    $cfgs = @(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' })
    if (-not $cfgs) { Write-Fail "No connected adapter with a gateway found."; return }
    $cfg = $cfgs[0]
    if ($cfgs.Count -gt 1) {
        for ($i=0; $i -lt $cfgs.Count; $i++) { Write-Host "    [$($i+1)] $($cfgs[$i].InterfaceAlias)  $($cfgs[$i].IPv4Address.IPAddress)" }
        $n = [int](Ask-Value "Which adapter" 1)
        if ($n -ge 1 -and $n -le $cfgs.Count) { $cfg = $cfgs[$n-1] }
    }
    $curIP   = $cfg.IPv4Address.IPAddress
    $curPfx  = $cfg.IPv4Address.PrefixLength
    $curGw   = $cfg.IPv4DefaultGateway.NextHop
    $curDns  = ($cfg.DNSServer | Where-Object AddressFamily -eq 2 | Select-Object -First 1).ServerAddresses -join ','
    Write-Host "    Current: $curIP/$curPfx  gw $curGw  dns $curDns  ($($cfg.InterfaceAlias))"
    Write-Warn2 "Pick an address OUTSIDE your router's DHCP pool (or reserve it in the router) to avoid conflicts."

    $ip  = Ask-Value "Static IP"       $curIP
    $pfx = Ask-Value "Prefix length (24 = 255.255.255.0)" $curPfx
    $gw  = Ask-Value "Gateway"         $curGw
    $dns = Ask-Value "DNS servers (comma separated)" ($(if ($curDns) { $curDns } else { '1.1.1.1,8.8.8.8' }))
    $dnsList = $dns -split '\s*,\s*' | Where-Object { $_ }

    if (-not (Test-IPv4 $ip) -or -not (Test-IPv4 $gw) -or ($dnsList | Where-Object { -not (Test-IPv4 $_) })) { Write-Fail "Invalid address entered. Aborting."; return }
    if ([int]$pfx -lt 8 -or [int]$pfx -gt 30) { Write-Fail "Prefix must be 8-30."; return }

    if ($ip -ne $curIP) {
        # quick conflict check
        if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            if (-not (Ask-YesNo "$ip responds to ping (may be in use). Continue anyway?" $false)) { return }
        }
    }
    if (-not (Ask-YesNo "Apply $ip/$pfx gw $gw dns $dns on '$($cfg.InterfaceAlias)'? (a remote session may drop briefly)" $true)) { return }

    $idx = $cfg.InterfaceIndex
    try {
        Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -ErrorAction Stop
        Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $idx -IPAddress $ip -PrefixLength ([int]$pfx) -DefaultGateway $gw -ErrorAction Stop | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dnsList
        Write-Ok "Static IP set: $ip"
    } catch {
        Write-Fail "Failed: $($_.Exception.Message) - reverting to DHCP"
        Set-NetIPInterface -InterfaceIndex $idx -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses
    }
}

function Do-Tailscale {
    Write-Step "Tailscale"
    Install-WingetPackage 'Tailscale.Tailscale' 'Tailscale'
    Refresh-Path
    $ts = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $ts) { $p = "$env:ProgramFiles\Tailscale\tailscale.exe"; if (Test-Path $p) { $ts = $p } }
    if ($ts -and (Ask-YesNo "Sign in to Tailscale now? (opens a browser login)" $true)) {
        & $ts up --unattended
        Write-Ok "Tailscale IP: $(& $ts ip -4 2>$null)"
        Write-Host "    --unattended keeps it connected when nobody is logged in."
    }
}

function Do-Core {
    Write-Step "Core dev tools"
    Install-WingetPackage 'Microsoft.VisualStudioCode' 'Visual Studio Code' @('--override','/VERYSILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,addtopath')
    Install-WingetPackage 'Git.Git' 'Git for Windows'
    Install-WingetPackage 'Microsoft.PowerShell' 'PowerShell 7'
    Install-WingetPackage 'Microsoft.WindowsTerminal' 'Windows Terminal'
    Install-WingetPackage 'OpenJS.NodeJS.LTS' 'Node.js LTS'
    Install-WingetPackage 'Python.Python.3.12' 'Python 3.12'
    Install-WingetPackage 'GitHub.cli' 'GitHub CLI'
    Refresh-Path
}

function Do-ClaudeCode {
    Write-Step "Claude Code (CLI)"
    Refresh-Path
    if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Ok "Claude Code already installed"; return }
    try {
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
        Refresh-Path
        Write-Ok "Claude Code installed. Run 'claude' in a project folder to log in."
    } catch {
        Write-Warn2 "Native installer failed; trying npm..."
        if (Get-Command npm -ErrorAction SilentlyContinue) { npm install -g '@anthropic-ai/claude-code' } else { Write-Fail "Install Node.js first." }
    }
}

function Do-ClaudeDesktop { Write-Step "Claude desktop app"; Install-WingetPackage 'Anthropic.Claude' 'Claude Desktop' }

function Do-VSCodeExt {
    Write-Step "VS Code extensions"
    Refresh-Path
    $code = Get-Command code -ErrorAction SilentlyContinue
    if (-not $code) { $p = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"; if (Test-Path $p) { $code = $p } }
    if (-not $code) { Write-Fail "VS Code CLI not found. Install VS Code first."; return }
    $exts = 'anthropic.claude-code','ms-vscode.powershell','eamodio.gitlens','ms-vscode-remote.remote-ssh',
            'esbenp.prettier-vscode','dbaeumer.vscode-eslint','ms-python.python','editorconfig.editorconfig',
            'github.vscode-pull-request-github'
    $have = & $code --list-extensions 2>$null
    foreach ($e in $exts) {
        if ($have -contains $e) { Write-Ok "$e (present)"; continue }
        & $code --install-extension $e --force 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok $e } else { Write-Fail $e }
    }
}

function Do-GitConfig {
    Write-Step "Git configuration"
    Refresh-Path
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Fail "Git not installed."; return }
    $n = Ask-Value "Git user.name"  (git config --global user.name)
    $e = Ask-Value "Git user.email" (git config --global user.email)
    if ($n) { git config --global user.name $n }
    if ($e) { git config --global user.email $e }
    git config --global init.defaultBranch main
    git config --global core.autocrlf true
    git config --global pull.rebase false
    git config --global credential.helper manager
    git config --global core.longpaths true
    Write-Ok "Git configured"
}

function Do-SSHKey {
    Write-Step "SSH key"
    $key = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
    if (Test-Path $key) { Write-Ok "Key already exists: $key"; return }
    New-Item -ItemType Directory -Force -Path (Split-Path $key) | Out-Null
    $email = Ask-Value "Comment for key (email)" "$env:USERNAME@$env:COMPUTERNAME"
    ssh-keygen -t ed25519 -C $email -f $key -N '""'
    Write-Ok "Created. Public key:"; Get-Content "$key.pub"
    Write-Host "    Add it at https://github.com/settings/keys"
}

function Do-WSL {
    Write-Step "WSL 2"
    wsl --install --no-distribution 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok "WSL enabled. After reboot run: wsl --install -d Ubuntu"; $script:RebootNeeded = $true }
    else { Write-Warn2 "WSL setup returned $LASTEXITCODE (may already be installed)." }
}

function Do-Docker {
    Write-Step "Docker Desktop"
    Install-WingetPackage 'Docker.DockerDesktop' 'Docker Desktop'
    Write-Warn2 "Needs WSL 2 (select that option too) and a reboot."
    $script:RebootNeeded = $true
}

function Do-OpenSSH {
    Write-Step "OpenSSH Server (SSH into the NUC)"
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (22)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    Write-Ok "sshd running on port 22"
}

function Do-Explorer {
    Write-Step "Explorer & Windows developer tweaks"
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-RegValue $adv 'HideFileExt' 0
    Set-RegValue $adv 'Hidden' 1
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense' 1
    Write-Ok "File extensions + hidden files shown, long paths on, Developer Mode on"
}

function Do-PSPolicy {
    Write-Step "PowerShell execution policy"
    Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-Ok "RemoteSigned"
}

function Do-UpdatePolicy {
    Write-Step "Windows Update: no surprise reboots"
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    Set-RegValue $au 'NoAutoRebootWithLoggedOnUsers' 1
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursStart' 6
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursEnd' 23
    Write-Ok "No auto-reboot while logged in; active hours 06:00-23:00 (still install updates manually/regularly!)"
}

function Do-DevFolder {
    Write-Step "Dev folder"
    $p = Ask-Value "Folder" 'C:\Dev'
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    Write-Ok "Created $p"
    if (Ask-YesNo "Add Defender exclusion for $p (faster builds, slightly less safe)?" $false) {
        Add-MpPreference -ExclusionPath $p; Write-Ok "Excluded"
    }
}

function Do-WoL {
    Write-Step "Wake-on-LAN (NIC side)"
    Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | ForEach-Object {
        foreach ($prop in 'Wake on Magic Packet','Wake on Pattern Match') {
            try { Set-NetAdapterAdvancedProperty -Name $_.Name -DisplayName $prop -DisplayValue 'Enabled' -ErrorAction Stop; Write-Ok "$($_.Name): $prop" } catch {}
        }
    }
    Write-Warn2 "Also enable WoL and 'Restore on AC power loss = Power On' in the NUC BIOS."
}

function Do-Utils {
    Write-Step "Handy utilities"
    Install-WingetPackage '7zip.7zip' '7-Zip'
    Install-WingetPackage 'Microsoft.Sysinternals.ProcessExplorer' 'Process Explorer'
    Install-WingetPackage 'Microsoft.PowerToys' 'PowerToys'
    Install-WingetPackage 'jqlang.jq' 'jq'
    Install-WingetPackage 'BurntSushi.ripgrep.MSVC' 'ripgrep'
    Install-WingetPackage 'WinDirStat.WinDirStat' 'WinDirStat'
}

function Do-WingetUpgrade {
    Write-Step "Upgrading all installed packages"
    winget upgrade --all --silent --accept-package-agreements --accept-source-agreements
}

# ---------------------------------------------------------------- menu definition
$Items = @(
    @{ Cat='System';   Name='Create a restore point first';                  On=$true;  Run={Do-RestorePoint} }
    @{ Cat='System';   Name='Rename computer (default: Development)';       On=$true; Run={Do-Rename} }
    @{ Cat='System';   Name='Power: never sleep/hibernate, NIC stays awake'; On=$true;  Run={Do-Power} }
    @{ Cat='System';   Name='Windows Update: prevent surprise reboots';      On=$true;  Run={Do-UpdatePolicy} }
    @{ Cat='System';   Name='Explorer tweaks, long paths, Developer Mode';   On=$true;  Run={Do-Explorer} }
    @{ Cat='System';   Name='PowerShell execution policy -> RemoteSigned';   On=$true;  Run={Do-PSPolicy} }
    @{ Cat='Remote';   Name='Enable Remote Desktop (RDP)';                   On=$true;  Run={Do-RDP} }
    @{ Cat='Remote';   Name='Set static IP address';                         On=$true;  Run={Do-StaticIP} }
    @{ Cat='Remote';   Name='Install + sign in to Tailscale';                On=$false; Run={Do-Tailscale} }
    @{ Cat='Remote';   Name='OpenSSH Server (ssh into the NUC)';             On=$false; Run={Do-OpenSSH} }
    @{ Cat='Remote';   Name='Wake-on-LAN (NIC settings)';                    On=$false; Run={Do-WoL} }
    @{ Cat='Dev';      Name='VS Code, Git, Node LTS, Python, PS7, Terminal, gh'; On=$true; Run={Do-Core} }
    @{ Cat='Dev';      Name='Claude Code CLI';                               On=$true;  Run={Do-ClaudeCode} }
    @{ Cat='Dev';      Name='Claude desktop app';                            On=$true;  Run={Do-ClaudeDesktop} }
    @{ Cat='Dev';      Name='VS Code extensions (Claude Code, GitLens, ...)'; On=$true; Run={Do-VSCodeExt} }
    @{ Cat='Dev';      Name='Configure Git (name, email, sane defaults)';    On=$true;  Run={Do-GitConfig} }
    @{ Cat='Dev';      Name='Generate SSH key (ed25519)';                    On=$false; Run={Do-SSHKey} }
    @{ Cat='Dev';      Name='Create C:\Dev project folder';                  On=$true;  Run={Do-DevFolder} }
    @{ Cat='Optional'; Name='WSL 2';                                         On=$false; Run={Do-WSL} }
    @{ Cat='Optional'; Name='Docker Desktop';                                On=$false; Run={Do-Docker} }
    @{ Cat='Optional'; Name='Utilities: 7-Zip, PowerToys, ripgrep, jq, ...'; On=$false; Run={Do-Utils} }
    @{ Cat='Optional'; Name='Upgrade all winget packages at the end';        On=$false; Run={Do-WingetUpgrade} }
)

function Set-ConsoleSize {
    # Works in classic conhost; silently ignored where the host won't allow resizing
    try {
        $raw = $Host.UI.RawUI
        if ($raw.BufferSize.Width -lt 120) {
            $raw.BufferSize = New-Object System.Management.Automation.Host.Size(120, [math]::Max($raw.BufferSize.Height, 3000))
        }
        $h = [math]::Min(40, $raw.MaxPhysicalWindowSize.Height)
        $raw.WindowSize = New-Object System.Management.Automation.Host.Size(120, $h)
    } catch {}
}

function Get-SysInfo {
    # Neofetch-style facts shown beside the menu. Collected once at start-up.
    $info = New-Object System.Collections.ArrayList
    function Add-Info($label, $value, $color = 'White') { [void]$info.Add(@{ L = $label; V = [string]$value; C = $color }) }
    function Clip($s, $n = 34) { if ($s.Length -gt $n) { $s.Substring(0, $n - 1) + '~' } else { $s } }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Add-Info 'OS'     (Clip (($os.Caption -replace 'Microsoft ', '') + " ($($os.Version))"))
        $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name -replace '\s+', ' ' -replace '\((R|TM)\)', ''
        Add-Info 'CPU'    (Clip $cpu)
        $tot = $os.TotalVisibleMemorySize / 1MB
        $use = $tot - ($os.FreePhysicalMemory / 1MB)
        Add-Info 'RAM'    ('{0:N1} / {1:N1} GB' -f $use, $tot)
        $up = (Get-Date) - $os.LastBootUpTime
        Add-Info 'Uptime' ('{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes)
    } catch {}
    try {
        $d = Get-PSDrive -Name C
        Add-Info 'Disk'   ('{0:N0} GB free of {1:N0} GB' -f ($d.Free / 1GB), (($d.Used + $d.Free) / 1GB))
    } catch {}
    try {
        $nic = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
        if ($nic) {
            $dhcp = (Get-NetIPInterface -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4).Dhcp
            $ipv4 = $nic.IPv4Address.IPAddress
            if ($dhcp -eq 'Enabled') { Add-Info 'IP' "$ipv4 (DHCP)" 'Yellow' } else { Add-Info 'IP' "$ipv4 (static)" 'Green' }
        } else { Add-Info 'IP' 'not connected' 'Red' }
    } catch {}
    try {
        $deny = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections).fDenyTSConnections
        if ($deny -eq 0) { Add-Info 'RDP' 'enabled' 'Green' } else { Add-Info 'RDP' 'disabled' 'Yellow' }
    } catch {}
    try {
        $ts = (Get-Command tailscale -ErrorAction SilentlyContinue) -or (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")
        if ($ts) { Add-Info 'Tailscale' 'installed' 'Green' } else { Add-Info 'Tailscale' 'not installed' 'Yellow' }
    } catch {}
    try {
        $sleep = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'Current AC Power Setting Index: (0x[0-9a-f]+)').Matches.Groups[1].Value
        if ($sleep -and [Convert]::ToInt32($sleep, 16) -eq 0) { Add-Info 'Sleep' 'never' 'Green' } else { Add-Info 'Sleep' 'enabled' 'Yellow' }
    } catch {}
    return $info
}

Write-Host "Gathering system info..." -ForegroundColor DarkGray
Set-ConsoleSize
$script:SysInfo = Get-SysInfo

# Logo (Claude Code style app icon, block art). '#' = filled, ' ' = empty.
$script:Logo = @(
    ' ################################## ',
    '####################################',
    '####################################',
    '####################################',
    '####################################',
    '######    ##########################',
    '#######    #########################',
    '#########    #######################',
    '###########    #####################',
    '############    ####################',
    '###########    #####################',
    '#########    #######################',
    '#######    #######           #######',
    '#######   #######             ######',
    '####################################',
    '####################################',
    '####################################',
    ' ################################## '
) | ForEach-Object { $_ -replace '#', [string][char]0x2588 }
function Show-Menu {
    Clear-Host
    $B   = [string][char]0x2588
    $bar = [string][char]0x2502
    $left  = New-Object System.Collections.ArrayList
    $right = New-Object System.Collections.ArrayList

    # ---------------- left column: the menu
    [void]$left.Add(@(@{ T = '  NUC Dev Machine Setup'; C = 'Cyan' }, @{ T = '  | by Lachlan Scott'; C = 'DarkGray' }))
    [void]$left.Add(@{ T = '  ' + ('-' * 58); C = 'DarkGray' })
    $lastCat = ''
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $it = $Items[$i]
        if ($it.Cat -ne $lastCat) { [void]$left.Add(@{ T = "  -- $($it.Cat) --"; C = 'DarkCyan' }); $lastCat = $it.Cat }
        $box = if ($it.On) { '[x]' } else { '[ ]' }
        $bc  = if ($it.On) { 'Green' } else { 'DarkGray' }
        $nc  = if ($it.On) { 'White' } else { 'Gray' }
        [void]$left.Add(@(
            @{ T = ('{0,4}. ' -f ($i + 1)); C = 'Yellow' },
            @{ T = "$box "; C = $bc },
            @{ T = $it.Name; C = $nc }))
    }
    [void]$left.Add(@{ T = ''; C = 'Gray' })
    [void]$left.Add(@(@{ T = '  Type numbers to toggle (3 8 9)  '; C = 'Gray' }, @{ T = 'A'; C = 'Yellow' }, @{ T = '=all '; C = 'Gray' },
                      @{ T = 'N'; C = 'Yellow' }, @{ T = '=none '; C = 'Gray' }, @{ T = 'Enter'; C = 'Green' }, @{ T = '=RUN '; C = 'Gray' },
                      @{ T = 'Q'; C = 'Yellow' }, @{ T = '=quit'; C = 'Gray' }))

    # ---------------- right column: logo + system info
    foreach ($row in $script:Logo) { [void]$right.Add(@{ T = $row; C = 'DarkYellow' }) }
    [void]$right.Add(@{ T = ''; C = 'Gray' })
    [void]$right.Add(@(@{ T = $env:USERNAME; C = 'Cyan' }, @{ T = '@'; C = 'White' }, @{ T = $env:COMPUTERNAME; C = 'Cyan' }))
    [void]$right.Add(@{ T = ('-' * ($env:USERNAME.Length + $env:COMPUTERNAME.Length + 1)); C = 'DarkGray' })
    foreach ($row in $script:SysInfo) {
        [void]$right.Add(@(@{ T = ($row.L + ': '); C = 'Yellow' }, @{ T = $row.V; C = $row.C }))
    }
    [void]$right.Add(@{ T = ''; C = 'Gray' })
    foreach ($palette in @(
            @('DarkRed', 'DarkYellow', 'DarkGreen', 'DarkCyan', 'DarkBlue', 'DarkMagenta', 'DarkGray', 'Gray'),
            @('Red', 'Yellow', 'Green', 'Cyan', 'Blue', 'Magenta', 'White', 'Gray'))) {
        [void]$right.Add(@($palette | ForEach-Object { @{ T = ($B * 3); C = $_ } }))
    }

    # ---------------- render side by side
    $wide = $true
    try { $wide = $Host.UI.RawUI.WindowSize.Width -ge 112 } catch {}
    $LW   = 64
    $rows = if ($wide) { [math]::Max($left.Count, $right.Count) } else { $left.Count }
    for ($r = 0; $r -lt $rows; $r++) {
        $len = 0
        if ($r -lt $left.Count) {
            foreach ($s in @($left[$r])) { Write-Host $s.T -ForegroundColor $s.C -NoNewline; $len += $s.T.Length }
        }
        if ($wide) {
            Write-Host (' ' * [math]::Max(0, $LW - $len)) -NoNewline
            Write-Host "$bar  " -ForegroundColor DarkGray -NoNewline
            if ($r -lt $right.Count) {
                foreach ($s in @($right[$r])) { Write-Host $s.T -ForegroundColor $s.C -NoNewline }
            }
        }
        Write-Host ''
    }
}

# ---------------------------------------------------------------- main loop
if (-not (Test-Winget)) { Write-Warn2 "winget missing - install-based options will fail. Update 'App Installer' from the Microsoft Store." ; Start-Sleep 2 }

while ($true) {
    Show-Menu
    $in = (Read-Host "`n>").Trim()
    if ($in -eq '') { break }
    switch -Regex ($in.ToLower()) {
        '^q$' { Stop-Transcript | Out-Null; return }
        '^a$' { $Items | ForEach-Object { $_.On = $true }; continue }
        '^n$' { $Items | ForEach-Object { $_.On = $false }; continue }
        default {
            foreach ($tok in ($in -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
                $n = [int]$tok
                if ($n -ge 1 -and $n -le $Items.Count) { $Items[$n-1].On = -not $Items[$n-1].On }
            }
        }
    }
}

$selected = @($Items | Where-Object { $_.On })
if (-not $selected) { Write-Host "Nothing selected."; Stop-Transcript | Out-Null; return }

Clear-Host
Write-Host "Running $($selected.Count) task(s)...`n" -ForegroundColor Cyan
$results = @()
foreach ($it in $selected) {
    try { & $it.Run; $results += "OK    $($it.Name)" }
    catch { Write-Fail $_.Exception.Message; $results += "FAIL  $($it.Name)" }
}

Write-Host "`n================ Summary ================" -ForegroundColor Cyan
$results | ForEach-Object { Write-Host $_ -ForegroundColor $(if ($_ -like 'OK*') {'Green'} else {'Red'}) }
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169\.254)\.' } | Select-Object -First 1).IPAddress
Write-Host "`nConnect via RDP:  mstsc /v:$ip     (user: $env:USERNAME)"
Write-Host "Log file: $LogFile"
Stop-Transcript | Out-Null

if ($script:RebootNeeded -and (Ask-YesNo "`nA reboot is needed to finish. Restart now?" $false)) { Restart-Computer -Force }
Read-Host "`nPress Enter to close"
