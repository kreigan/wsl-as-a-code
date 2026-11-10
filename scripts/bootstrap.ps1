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
  
  [Parameter(HelpMessage = "Skip running chezmoi in Windows.")]
  [switch]$SkipWinChezmoiInit,
  
  [Parameter(HelpMessage = "Skip running chezmoi in WSL.")]
  [switch]$SkipWslChezmoiInit,
  
  [Parameter(HelpMessage = "Enable configuration for the 1Password SSH agent.")]
  [switch]$Use1PasswordSshAgent,

  [Parameter(HelpMessage = "Skip the installation of the WSL distribution.")]
  [switch]$SkipInstallWslDistro,

  [Parameter(HelpMessage = "The name of the WSL distribution.")]
  [ValidateNotNullOrWhiteSpace()]
  [string]$DistroName = "ArchLinux",

  [Parameter(HelpMessage = "Use Docker Desktop instead of installing Docker Engine in WSL.")]
  [switch]$UseDockerDesktop,

  [Parameter(HelpMessage = "Customize the user UID for the WSL distribution.")]
  [int]$Uid,

  [Parameter(HelpMessage = "The user name for the WSL distribution.")]
  [ValidateNotNullOrWhiteSpace()]
  [string]$UserName = "wsl",

  [Parameter(HelpMessage = "WSL user password. Prompted securely if omitted.")]
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
    Write-Error "'$Path' does not exist or is not a file"
  }
  Write-Verbose "Resolved $Path to $($resolved.Path)"
  return $resolved.Path
}

# Top-level progress: one entry per bootstrap stage.
function Start-Step {
  param([Parameter(Mandatory)][string]$Name)

  $script:StepIndex++
  $script:StepName = $Name
  Write-Progress -Id 0 -Activity "WSL bootstrap" `
    -Status "Step $script:StepIndex of ${script:StepTotal}: $Name" `
    -PercentComplete (($script:StepIndex - 1) / $script:StepTotal * 100)
  Write-Host "$($PSStyle.Foreground.Cyan)[$script:StepIndex/$script:StepTotal]$($PSStyle.Reset) $Name"
}

function Complete-Step {
  param([string]$Message = "Done")
  Write-Host "$($PSStyle.Foreground.Green)  ✔$($PSStyle.Reset) $Message`n"
}

# Runs a noisy command, showing only its latest output line as progress.
# Full output goes to the verbose stream, and is dumped if the command fails.
function Invoke-Quiet {
  param([Parameter(Mandatory)][scriptblock]$Command)

  $lines = [System.Collections.Generic.List[string]]::new()
  try {
    & $Command 2>&1 | ForEach-Object {
      $line = "$_".Trim()
      if (-not $line) { return }
      $lines.Add($line)
      Write-Verbose $line
      Write-Progress -Id 1 -ParentId 0 -Activity $script:StepName -Status $line
    }
  }
  catch {
    $lines | ForEach-Object { Write-Host "$($PSStyle.Foreground.BrightBlack)  $_$($PSStyle.Reset)" }
    throw
  }
  finally {
    Write-Progress -Id 1 -Activity $script:StepName -Completed
  }
}

function Expand-ArchiveInWSL {
  param(
    [Parameter(Mandatory)]
    [string]$FullPath
  )

  $script = @'
set -euo pipefail
umask 077
tempDir="$(mktemp -d /dev/shm/unpacked.XXXXXX)"
bsdtar -xf "$(wslpath -u "$1")" -C "$tempDir"
echo "$tempDir"
'@
  return wsl -d $DistroName -u root --exec bash -c $script _ $FullPath
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
    Write-Verbose "Unpacked to $tmpWslPath"

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
    Write-Verbose "Stopping WSL distribution: $DistroName"
    wsl --terminate $DistroName
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

$script:StepIndex = 0
$script:StepName = ""
$script:StepTotal = 6
$script:StepTotal += $SkipWinChezmoiInit ? 0 : 1
$script:StepTotal += $SkipWslChezmoiInit ? 0 : 1
$script:StepTotal += $SkipInstallWslDistro ? 0 : 1

Start-Step "Checking prerequisites"

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
  Write-Error "'wsl' command not found. Is WSL installed?"
}

$ansibleArchivePath = Resolve-FilePath "ansible.tar.gz"

$SkipChezmoiInit = $SkipWinChezmoiInit -and $SkipWslChezmoiInit
if (-not $SkipChezmoiInit -and -not $DotfilesUrl) {
  $chezmoiArchivePath = Resolve-FilePath "dotfiles.zip"
}

if (-not $PSBoundParameters.ContainsKey("UserPassword")) {
  $UserPassword = Read-Host "Password for WSL user '$UserName'" -AsSecureString
}

if (-not $UserPassword -or $UserPassword.Length -eq 0) {
  throw "WSL user password cannot be empty."
}

# https://github.com/microsoft/WSL/issues/4607
$env:WSL_UTF8 = 1
$distroInstalled = $DistroName -in (wsl -l -q)
Write-Verbose "WSL distribution '$DistroName' already installed: $distroInstalled"

if (-not $SkipInstallWslDistro -and $distroInstalled) {
  Write-Error "WSL distribution '$DistroName' is already installed. Re-run with -SkipInstallWslDistro flag."
}
elseif ($SkipInstallWslDistro -and -not $distroInstalled) {
  Write-Error "WSL distribution '$DistroName' is not installed but -SkipInstallWslDistro is set."
}
Complete-Step "Files found, WSL available"

Start-Step "Setting XDG base directory variables"
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
Complete-Step

if (-not $SkipWinChezmoiInit -or -not $SkipWslChezmoiInit) {
  $stringPrompts = [ordered]@{}
  $boolPrompts = [ordered]@{}

  if ($GitUserName) { $stringPrompts["Git name for commits"] = $GitUserName }
  if ($GitUserEmail) { $stringPrompts["Git email address"] = $GitUserEmail }
  if ($InstallDevTools) { $boolPrompts["Install development tools [y/N]"] = $true }

  # Same arguments are used for Windows and WSL runs
  $chezmoiInitArgs = Get-ChezmoiInitArgs `
    -RepoUrl $DotfilesUrl `
    -StringPrompts $stringPrompts `
    -BoolPrompts $boolPrompts

    # log args suitable for copy-paste
  $displayArgs = $chezmoiInitArgs | ForEach-Object { $_ -match '\s' ? "'$_'" : $_ }
  Write-Verbose "chezmoi arguments: $($displayArgs -join ' ')`n"
}


########################
##  INSTALL PACKAGES  ##
########################


Start-Step "Installing Windows packages"

# w/a https://github.com/PowerShell/PSResourceGet/issues/1965
Get-PSResourceRepository | Out-Null

# Silence module discovery/import noise even when -Verbose is on
Set-PSResourceRepository -Name PSGallery -Trusted -Verbose:$false
Install-PSResource -Name Microsoft.WinGet.Client -Quiet -WarningAction SilentlyContinue -Verbose:$false
Import-Module Microsoft.WinGet.Client -Verbose:$false

$packages = @("twpayne.chezmoi")
if ($Use1PasswordSshAgent) {
  $packages += "AgileBits.1Password.CLI", "albertony.npiperelay"
}

foreach ($id in $packages) {
  if (Get-WinGetPackage -Id $id -Verbose:$false) {
    Write-Verbose "$id is already installed"
  } else {
    Write-Host "  Installing $id"
    Install-WinGetPackage -Id $id -Verbose:$false | Out-Null
  }
}

Write-Verbose "Refreshing PATH environment variable in the current process"
$env:Path = (
  [System.Environment]::GetEnvironmentVariable('Path', 'Machine'),
  [System.Environment]::GetEnvironmentVariable('Path', 'User')
) -join ';'
Complete-Step "Packages: $($packages -join ', ')"


##############################
##  RUN CHEZMOI IN WINDOWS  ##
##############################


if (-not $SkipWinChezmoiInit) {
  Start-Step "Initializing chezmoi in Windows"

  $chezmoiSourceDir = chezmoi source-path
  if ([string]::IsNullOrWhiteSpace($chezmoiSourceDir)) {
    Write-Error "chezmoi returned an empty source path"
  }
  Write-Verbose "chezmoi source directory: $chezmoiSourceDir"

  if (Get-ChildItem $chezmoiSourceDir -Force -Exclude '.git' -ErrorAction Ignore) {
    $confirm = Read-Host "chezmoi source directory '$chezmoiSourceDir' is not empty. Clear it? (y/N)"

    if ($confirm -imatch '^y(es)?$') {
      # Backup before purge
      $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
      $backupPath = Join-Path $env:TEMP "chezmoi_backup_$timestamp.zip"

      try {
        Compress-Archive -Path $chezmoiSourceDir -DestinationPath $backupPath -Force
        Write-Host "  Backup of the source directory: $backupPath"
      }
      catch {
        Write-Error "Failed to back up the chezmoi source directory: $_"
      }

      & chezmoi purge --force 2>&1
    
    } else {
      Write-Error "Aborted. The chezmoi source directory is not empty. Clear it before retrying."
    }
  }
  
  if ($chezmoiArchivePath) {
    Expand-Archive -LiteralPath $chezmoiArchivePath -DestinationPath $chezmoiSourceDir -Force
    New-Item -ItemType Directory -Path (Join-Path $chezmoiSourceDir ".git") | Out-Null
  }
  
  & chezmoi init @chezmoiInitArgs --apply 2>&1
  Complete-Step "chezmoi applied"
}


##########################
##  INSTALL WSL DISTRO  ##
##########################


if (-not $SkipInstallWslDistro) {
  Start-Step "Installing WSL distribution '$DistroName'"
  Invoke-Quiet { wsl --install archlinux --no-launch --name $DistroName }
  wsl --set-default $DistroName
  Complete-Step
}


########################
##  BOOTSTRAP SYSTEM  ##
########################


Start-Step "Preparing '$DistroName' (keyring, python, ansible)"
$prepareBootstrapCmd = @'
set -euo pipefail
pacman-key --init
pacman-key --populate archlinux
pacman -Sy --noconfirm archlinux-keyring
pacman -Syu --noconfirm --needed python ansible sudo
'@
Invoke-Quiet { wsl -d $DistroName -u root --exec bash -c $prepareBootstrapCmd }
Complete-Step

$playbookEnv = @(
  "USERPROFILE/up",
  "APPDATA/up"
  "USERNAME",
  "OneDrive/up"
)

$playbookVars = @{ install_docker = $UseDockerDesktop ? "no" : "yes" }
if ($Uid) { $playbookVars["user_uid"] = $Uid }

if ($Use1PasswordSshAgent) {
  $env:BOOTSTRAP_NPIPERELAY_PATH = Get-Command npiperelay -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
  $env:BOOTSTRAP_OP_PATH = Get-Command op -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source

  $playbookEnv += @(
    "BOOTSTRAP_NPIPERELAY_PATH/up",
    "BOOTSTRAP_OP_PATH/up"
  )
}

Start-Step "Bootstrapping WSL system in '$DistroName'"
Invoke-AnsiblePlaybook "system" `
  -PlaybookVars $playbookVars `
  -PlaybookEnv $playbookEnv `
  -TerminateDistro

Complete-Step "System playbook finished"


######################
##  BOOTSTRAP USER  ##
######################


$playbookVars["user_name"] = $UserName
$playbookVars["user_shell"] = $UserShell
$playbookVars["user_password"] = [System.Net.NetworkCredential]::new('', $UserPassword).Password

Start-Step "Bootstrapping user '$UserName' in '$DistroName'"

try {
  Invoke-AnsiblePlaybook "user" `
    -PlaybookVars $playbookVars `
    -VarsToFile `
    -TerminateDistro
}
finally {
  $playbookVars["user_password"] = $null
}

Complete-Step "User playbook finished"


##########################
##  RUN CHEZMOI IN WSL  ##
##########################


if (-not $SkipWslChezmoiInit) {
  if (-not $DotfilesUrl) {
    $env:BOOTSTRAP_DOTFILES_PATH = $chezmoiArchivePath
    $env:WSLENV = "BOOTSTRAP_DOTFILES_PATH/up"
  }
  $chezmoiWslScript = @'
set -euo pipefail
if [ -n "${BOOTSTRAP_DOTFILES_PATH:-}" ]; then
  src="$(chezmoi source-path)"
  if find "$src" -mindepth 1 | read; then
    echo "$src is not empty, bootstrap will be aborted."
    echo "Make sure $src is empty and run the bootstrap again."
    exit 1
  fi
  mkdir -p "$src/.git"
  bsdtar -xf "$BOOTSTRAP_DOTFILES_PATH" -C "$src"
fi
exec chezmoi init "$@" --apply
'@

  Start-Step "Initializing chezmoi in WSL for '$UserName'"
  wsl -d $DistroName -u $UserName --exec bash -lc $chezmoiWslScript _ @chezmoiInitArgs
  Complete-Step "chezmoi applied"
}

Write-Progress -Id 0 -Activity "WSL bootstrap" -Completed
Write-Host "$($PSStyle.Foreground.Green)Bootstrap completed.$($PSStyle.Reset)"
