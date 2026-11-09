# Setup-Dev

Interactive PowerShell setup for a NUC-style, always-on Windows dev machine (built for Claude development).
Pick what you want from a checklist menu, press Enter, done.

By Lachlan Scott.

## Run it

Open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/lachlanscott22/Setup-Dev/main/Setup-Dev.ps1 | iex
```

It asks for Administrator rights and relaunches itself elevated.

Prefer to read it first (recommended, it changes system settings)?

```powershell
irm https://raw.githubusercontent.com/lachlanscott22/Setup-Dev/main/Setup-Dev.ps1 -OutFile Setup-Dev.ps1
notepad .\Setup-Dev.ps1
powershell -ExecutionPolicy Bypass -File .\Setup-Dev.ps1
```

## What it can do

Everything is a checkbox; type numbers to toggle, `A` for all, `N` for none, Enter to run.

| Group | Options |
|---|---|
| System | Restore point, rename computer (default `Development`), never sleep/hibernate, stop surprise update reboots, Explorer/long-path/Developer Mode tweaks, execution policy |
| Remote | Remote Desktop (with NLA), static IP (guided, with revert on failure), Tailscale, OpenSSH Server, Wake-on-LAN |
| Dev | VS Code, Git, Node LTS, Python, PowerShell 7, Windows Terminal, GitHub CLI, Claude Code CLI, Claude desktop app, VS Code extensions, Git config, SSH key, `C:\Dev` folder |
| Optional | WSL 2, Docker Desktop, utilities (7-Zip, PowerToys, ripgrep, jq...), `winget upgrade --all` |

The menu also shows live status (IP static/DHCP, RDP, Tailscale, sleep) so you can see what still needs doing.

## Requirements

- Windows 10/11 (Pro or higher for RDP) with PowerShell 5.1+
- `winget` (App Installer) for the install options

## Notes

- Safe to re-run; each step checks the current state first.
- A log is written to `%USERPROFILE%\DevNUC-Setup.log`.
- Pick a static IP outside your router's DHCP pool (or reserve it in the router).
- Don't port-forward RDP (3389) to the internet. Use Tailscale or a VPN.
- Review any script before running it as Administrator.

## License

MIT, see [LICENSE](LICENSE).
