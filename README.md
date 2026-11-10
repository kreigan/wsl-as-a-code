# WSL as a Code Setup

A lot of useful text should be here but I did not write it yet.

## Prerequisites

1. Windows with WSL installed
2. PowerShell 7.4+ ([doc](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows))

## Usage

1. Download the [latest release](https://github.com/kreigan/wsl-as-a-code/releases/latest/download/wsl-bootstrapper.zip)
and unzip it somewhere. Or use the script below that will put it in "wsl-bootstrapper" folder in your home.

```powershell
$dest = New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE 'wsl-bootstrapper') -Force
Invoke-WebRequest `
  -Uri 'https://github.com/kreigan/wsl-as-a-code/releases/latest/download/wsl-bootstrapper.zip' `
  -OutFile (Join-Path $dest 'wsl-bootstrapper.zip')
Expand-Archive -Path (Join-Path $dest 'wsl-bootstrapper.zip') -DestinationPath $dest -Force
Set-Location $dest
```

2. Run the script:

```powershell
Set-ExecutionPolicy Unrestricted -Scope Process
.\wsl-bootstrapper.ps1 [OPTIONS]
```

## Enabling Windows SSH agent forwarding manually after bootstrap

If you ran the bootstrap script without `-Use1PasswordSshAgent` flag but now want it,
you can link npiperelay manually and start the service. Just run this in your PowerShell:

```powershell
winget install AgileBits.1Password.CLI --scope user
winget install albertony.npiperelay --scope user

$env:NPIPERELAY_BIN = Get-Command npiperelay -ErrorAction Stop | Select-Object -ExpandProperty Source
$env:WSLENV = "NPIPERELAY_BIN/up:$env:WSLENV"
wsl bash -c @'
sudo ln -s "$NPIPERELAY_BIN" /usr/local/bin/npiperelay
sudo systemctl --global enable wsl-ssh-agent.service
systemctl --user start wsl-ssh-agent.service
'@
```
