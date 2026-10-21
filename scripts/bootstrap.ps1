<#
.SYNOPSIS
Entry point script for kicking off a bootstrap procedure for WSL environment.

.DESCRIPTION
Starts the bootstrap process, isn't this clear?

#>


[CmdletBinding(DefaultParameterSetName = "Path")]
param(
  [Parameter(HelpMessage = "The URL of a chezmoi repository.")]
  [ValidateNotNullOrWhiteSpace()]
  [string]$DotfilesUrl,
  
  [Parameter(HelpMessage = "Do not initialize chezmoi in Windows and WSL.")]
  [switch]$SkipChezmoiInit,
  
  [Parameter(HelpMessage = "Disable configuration for the 1Password SSH agent.")]
  [switch]$NotUse1PasswordSshAgent,

  [Parameter(HelpMessage = "Skip the installation of the WSL distribution.")]
  [switch]$SkipInstallWslDistro,

  [Parameter(HelpMessage = "The name of the WSL distribution.")]
  [ValidateNotNullOrWhiteSpace()]
  [string]$DistroName = "ArchLinux",

  [Parameter(HelpMessage = "Do not install Docker Engine in WSL.")]
  [switch]$SkipInstallDocker,

  [Parameter(HelpMessage = "The user UID for the WSL distribution.")]
  [int]$Uid = 1000,

  [Parameter(HelpMessage = "The user name for the WSL distribution.")]
  [ValidateNotNullOrWhiteSpace()]
  [string]$UserName = "wsl",

  [Parameter(HelpMessage = "WSL user password.")]
  [ValidateNotNullOrWhiteSpace()]
  [SecureString]$UserPassword,

  [ValidateSet("bash", "zsh", "nu")]
  [string]$UserShell = "zsh",

  [Parameter(HelpMessage = "Git user name.")]
  [ValidateNotNullOrWhiteSpace()]
  [string]$GitUserName,
  
  [Parameter(HelpMessage = "Git user email.")]
  [ValidateNotNullOrWhiteSpace()]
  [string]$GitUserEmail,
  
  [Parameter(HelpMessage = "Git signing key.")]
  [ValidateNotNullOrWhiteSpace()]
  [string]$GitSignKey,

  [Parameter(HelpMessage = "Install developer tools in WSL.")]
  [switch]$InstallDevTools
)

# Persists the variable for the user and makes it available in the current process.
function Set-UserEnv {
  param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Name,

    [Parameter(Mandatory, Position = 1)]
    [string]$Value
  )
  [System.Environment]::SetEnvironmentVariable($Name, $Value, "User")
  [System.Environment]::SetEnvironmentVariable($Name, $Value, "Process")
}

function Resolve-FilePath {
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )
  $resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
  if (-not $resolved -or -not (Test-Path $resolved.Path -PathType Leaf)) {
    Write-Error "[✖] '$Path' does not exist or is not a file"
  }
  Write-Verbose "Resolved $Path to $($resolved.Path)"
  return $resolved.Path
}

function Expand-ArchiveInWSL {
  param(
    [Parameter(Mandatory)]
    [string]$ArchivePath
  )

  $fullPath = Resolve-FilePath $ArchivePath

  $script = @'
set -euo pipefail
umask 077
tempDir="$(mktemp -d /dev/shm/unpacked.XXXXXX)"
bsdtar -xf "$(wslpath -u "$1")" -C "$tempDir"
echo "$tempDir"
'@
  return wsl -d $DistroName -u root --exec bash -c $script _ $fullPath
}

function Invoke-AnsiblePlaybook {
  param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PlaybookName,

    [hashtable]$PlaybookVars,
    [string[]]$PlaybookEnv,

    [switch]$VarsToFile,
    [switch]$TerminateDistro
  )
  
  $varsJson = $PlaybookVars | ConvertTo-Json -Compress
  
  try {
    if ($VarsToFile) {
      Write-Verbose "Creating temporary file for Ansible playbook variables."
      $varsFileCmd = 'umask 077; f=$(mktemp /dev/shm/ansible-vars.XXXXXX) && cat > "$f" && echo "$f"'
      $varsFile = $varsJson | wsl -d $DistroName -u root --exec bash -c $varsFileCmd
      Write-Verbose "Temporary Ansible variables file created at: $varsFile"
    }
    
    Write-Verbose "Unpacking Ansible archive to a temporary folder in WSL"
    $tmpWslPath = Expand-ArchiveInWSL $ansibleArchivePath

    $cmd = 'cd "{0}" && ansible-playbook -i localhost, --connection=local ''{1}.yml'' -e ''{2}''' -f @(
      $tmpWslPath,
      $PlaybookName,
      ($VarsToFile ? "@$varsFile" : $varsJson)
    )

    $prevWslEnv = $env:WSLENV
    $env:WSLENV = $PlaybookEnv -join ':'
    Write-Verbose "WSLENV='$env:WSLENV'"
    Write-Verbose "Executing: $cmd`n"
    wsl -d $DistroName -u root --exec bash -c $cmd _
  }
  finally {
    if ($varsFile) { wsl -d $DistroName -u root -- rm -f -- "$varsFile" }
    $env:WSLENV = $prevWslEnv
  }

  if ($TerminateDistro) {
    Write-Host "[→] Stopping WSL distribution: $DistroName"
    wsl --terminate $DistroName
    Write-Host "[✔] WSL distribution stopped."
  }
}

function Get-ChezmoiInitArgs {
  param(
    [string]$RepoUrl,
    [System.Collections.IDictionary]$StringPrompts = @{},
    [System.Collections.IDictionary]$BoolPrompts = @{}
  )

  # chezmoi parses --promptXXX pairs as CSV; a field must be quoted in full
  $toCsv = {
    param($Pairs)
    ($Pairs | ForEach-Object {
      $field = "$($_.Key)=$($_.Value)"
      if ($field -match '[,"\r\n]') { '"{0}"' -f ($field -replace '"', '""') } else { $field }
    }) -join ","
  }

  $initArgs = @()
  if ($RepoUrl) { $initArgs += $RepoUrl }
  if ($StringPrompts.Count) { $initArgs += "--promptString", (& $toCsv $StringPrompts.GetEnumerator()) }
  if ($BoolPrompts.Count) {
    $bools = [ordered]@{}
    foreach ($key in $BoolPrompts.Keys) { $bools[$key] = "$($BoolPrompts[$key])".ToLower() }
    $initArgs += "--promptBool", (& $toCsv $bools.GetEnumerator())
  }
  return $initArgs
}


#
# SCRIPT STARTS HERE
#


#Requires -Version 7.4

# Exit on errors
$PSNativeCommandUseErrorActionPreference = $true
$ErrorActionPreference = "Stop"

Write-Host "[→] Started bootstrap script`n"

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
  Write-Error "[✖] 'wsl' command not found. Is WSL installed?"
}  

$ansibleArchivePath = Resolve-FilePath "ansible.tar.gz"
if (-not $SkipChezmoiInit -and -not $DotfilesUrl) {
  $chezmoiArchivePath = Resolve-FilePath "dotfiles.zip"
}

Write-Host "[✔] All file paths are valid."

# https://github.com/microsoft/WSL/issues/4607
$env:WSL_UTF8 = 1
$distroInstalled = $DistroName -in (wsl -l -q)
Write-Verbose "WSL distribution already installed: $distroInstalled"

if (-not $SkipInstallWslDistro -and $distroInstalled) {
  Write-Error "[✖] WSL distribution '$DistroName' is already installed. Re-run with -SkipInstallWslDistro flag."
}
elseif ($SkipInstallWslDistro -and -not $distroInstalled) {
  Write-Error "[✖] WSL distribution '$DistroName' is not installed but -SkipInstallWslDistro is set."
}

Write-Host "[→] Setting up user env variables for XDG base directories"
$xdgDefaults = @{
  XDG_CONFIG_HOME = Join-Path $HOME ".config"
  XDG_DATA_HOME   = Join-Path $HOME ".local" "share"
  XDG_CACHE_HOME  = Join-Path $HOME ".cache"
  XDG_STATE_HOME  = Join-Path $HOME ".local" "state"
}

foreach ($var in $xdgDefaults.Keys) {
  if (-not [System.Environment]::GetEnvironmentVariable($var, "User")) {
    $val = $xdgDefaults[$var]
    Write-Verbose "Setting user environment variable '$var' to '$val'"
    Set-UserEnv $var $val
  }
}
Write-Host "[✔] User environment variables for XDG base directories are set."


########################
##  INSTALL PACKAGES  ##
########################


Write-Host "[→] Installing the required Windows packages`n"

Set-PSResourceRepository -Name PSGallery -Trusted
Install-PSResource -Name Microsoft.WinGet.Client -Quiet -WarningAction SilentlyContinue
Import-Module Microsoft.WinGet.Client > $null

Write-Verbose "Checking if chezmoi is installed"
if (-not (Get-WinGetPackage -Id twpayne.chezmoi)) {
  Install-WinGetPackage -Id twpayne.chezmoi
}

if (-not $NotUse1PasswordSshAgent) {
  Write-Verbose "Checking if 1Password CLI is installed"
  if (-not (Get-WinGetPackage -Id AgileBits.1Password.CLI)) {
    Install-WinGetPackage -Id AgileBits.1Password.CLI
  }

  Write-Verbose "Checking if npiperelay is installed"
  if (-not (Get-WinGetPackage -Id albertony.npiperelay)) {
    Install-WinGetPackage -Id albertony.npiperelay
  }
}  

Write-Host "[✔] Required packages are installed."

Write-Verbose "Refreshing PATH environment variable in the current process"
$env:Path = (
  [System.Environment]::GetEnvironmentVariable('Path', 'Machine'),
  [System.Environment]::GetEnvironmentVariable('Path', 'User')
) -join ';'


##############################
##  RUN CHEZMOI IN WINDOWS  ##
##############################


if (-not $SkipChezmoiInit) {
  Write-Host "[→] Running chezmoi initialization in Windows`n"

  $chezmoiSourceDir = chezmoi source-path
  if ([string]::IsNullOrWhiteSpace($chezmoiSourceDir)) {
    Write-Error "[✖] chezmoi returned an empty source path"
  }
  Write-Verbose "chezmoi source directory: $chezmoiSourceDir"

  Write-Host "[→] Checking if chezmoi source directory is empty"
  if (Get-ChildItem $chezmoiSourceDir -Force -Exclude '.git' -ErrorAction Ignore) {
    $confirm = Read-Host "chezmoi source directory '$chezmoiSourceDir' is not empty. Clear it? (y/N)"

    if ($confirm -imatch '^y(es)?$') {
      # Backup before purge
      $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
      $backupPath = Join-Path $env:TEMP "chezmoi_backup_$timestamp.zip"

      try {
        Compress-Archive -Path $chezmoiSourceDir -DestinationPath $backupPath -Force
        Write-Host "[✔] chezmoi source folder backup created: $backupPath"
      }
      catch {
        Write-Error "[✖] Failed to create chezmoi source folder backup: $_"
      }

      & chezmoi purge --force 2>&1
    
    } else {
      Write-Error "[✖] Aborted. chezmoi source folder is not empty. Clear it before retrying."
    }
  }

  $stringPrompts = [ordered]@{}
  $boolPrompts = [ordered]@{}

  if ($GitUserName) { $stringPrompts["Git name for commits"] = $GitUserName }
  if ($GitUserEmail) { $stringPrompts["Git email address"] = $GitUserEmail }
  if ($InstallDevTools) { $boolPrompts["Install development tools? [y/N]"] = $true }
  if ($GitSignKey) {
    $boolPrompts["Enable Git commit signing? [y/N]"] = $true
    $stringPrompts["Git signing key"] = $GitSignKey
  }

  # Same arguments are used for Windows and WSL runs
  $chezmoiInitArgs = Get-ChezmoiInitArgs `
    -RepoUrl $DotfilesUrl `
    -StringPrompts $stringPrompts `
    -BoolPrompts $boolPrompts

  # log args suitable for copy-paste
  $displayArgs = $chezmoiInitArgs | ForEach-Object { $_ -match '\s' ? "'$_'" : $_ }
  Write-Verbose "Initializing chezmoi with arguments: $($displayArgs -join ' ')`n"

  if ($chezmoiArchivePath) {
    Expand-Archive -LiteralPath $chezmoiArchivePath -DestinationPath $chezmoiSourceDir -Force
    New-Item -ItemType Directory -Path (Join-Path $chezmoiSourceDir ".git") | Out-Null
  }

  & chezmoi init --apply @chezmoiInitArgs 2>&1
  Write-Host "`n[✔] chezmoi initialization completed.`n"
}


##########################
##  INSTALL WSL DISTRO  ##
##########################


if (-not $SkipInstallWslDistro) {
  Write-Host "[→] Installing WSL distribution"
  & wsl --install archlinux --no-launch --name $DistroName 2>&1
  & wsl --set-default $DistroName 2>&1
}


########################
##  BOOTSTRAP SYSTEM  ##
########################


Write-Host "[→] Preparing to bootstrap WSL distribution '$DistroName'"
$prepareBootstrapCmd = @'
set -euo pipefail
pacman-key --init > /dev/null 2>&1
pacman-key --populate archlinux > /dev/null 2>&1
pacman -Sy --noconfirm archlinux-keyring > /dev/null 2>&1
pacman -Sy --noconfirm --needed python ansible sudo
'@
wsl -d $DistroName -u root --exec bash -c $prepareBootstrapCmd

$playbookEnv = @(
  "USERPROFILE/up",
  "APPDATA/up"
  "USERNAME",
  "OneDrive/up"
)

if (-not $NotUse1PasswordSshAgent) {
  $env:BOOTSTRAP_NPIPERELAY_PATH = Get-Command npiperelay -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
  $env:BOOTSTRAP_OP_PATH = Get-Command op -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source

  $playbookEnv += @(
    "BOOTSTRAP_NPIPERELAY_PATH/up",
    "BOOTSTRAP_OP_PATH/up"
  )
}

Write-Host "[→] Bootstrapping WSL system in '$DistroName'"
Invoke-AnsiblePlaybook "system" `
  -PlaybookVars @{ "install_docker" = $SkipInstallDocker ? "no" : "yes" } `
  -PlaybookEnv $playbookEnv `
  -TerminateDistro

Write-Host "[✔] WSL system successfully bootstrapped.`n"


######################
##  BOOTSTRAP USER  ##
######################


$playbookVars = @{
  user_uid   = $Uid
  user_name  = $UserName
  user_shell = $UserShell
}

if ($UserPassword) {
  $playbookVars["user_password"] = [System.Net.NetworkCredential]::new('', $UserPassword).Password
}

Write-Host "[→] Bootstrapping user '$UserName' in '$DistroName'`n"

try {
  Invoke-AnsiblePlaybook "user" `
    -PlaybookVars $playbookVars `
    -VarsToFile `
    -TerminateDistro
}
finally {
  $playbookVars["user_password"] = $null
}

Write-Host "[✔] WSL user successfully bootstrapped.`n"


##########################
##  RUN CHEZMOI IN WSL  ##
##########################


if (-not $SkipChezmoiInit) {
  if (-not $DotfilesUrl) {
    $env:BOOTSTRAP_DOTFILES_PATH = $chezmoiArchivePath
    $env:WSLENV = "BOOTSTRAP_DOTFILES_PATH/up"
  }
  $chezmoiWslScript = @'
set -euo pipefail
if [ -n "${BOOTSTRAP_DOTFILES_PATH:-}" ]; then
  src="$(chezmoi source-path)"
  if find "$src" -mindepth 1 | read; then
    echo "$src is not empty, bootstrap aborted."
    exit 1
  fi
  mkdir -p "$src/.git"
  bsdtar -xf "$BOOTSTRAP_DOTFILES_PATH" -C "$src"
fi
exec chezmoi init --apply "$@"
'@

  Write-Host "[→] Initializing chezmoi for '$UserName' in '$DistroName'`n"
  wsl -d $DistroName -u $UserName --exec bash -lc $chezmoiWslScript _ @chezmoiInitArgs
  Write-Host "[✔] chezmoi initialization in WSL completed.`n"
}
