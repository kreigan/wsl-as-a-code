param(
  [string]$ToolsDir = (Join-Path $HOME 'bin'),
  [string]$OpVersion = '2.39.0',
  [string]$NpiperelayVersion = '0.1.0'
)

function Add-UserPath {
  param(
    [Parameter(Mandatory)]
    [string]$PathEntry
  )
  $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = @($userPath -split ';' | Where-Object { $_ })
  if ($entries -notcontains $PathEntry) {
    $entries += $PathEntry
    [System.Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
  }
}

function Install-FromZip {
  param(
    [Parameter(Mandatory)]
    [string]$Uri,

    [Parameter(Mandatory)]
    [string]$InstallDir,

    [Parameter(Mandatory)]
    [string[]]$BinaryNames
  )

  $zipFile = Join-Path $env:TEMP ([IO.Path]::GetRandomFileName() + '.zip')
  $extractDir = Join-Path $env:TEMP ([IO.Path]::GetRandomFileName())

  try {
    Invoke-WebRequest -Uri $Uri -OutFile $zipFile
    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force

    foreach ($name in $BinaryNames) {
      # archive layout may nest the binary in a subfolder, so search recursively
      $binary = Get-ChildItem -Path $extractDir -Filter $name -Recurse -File | Select-Object -First 1
      if (-not $binary) {
        Write-Error "Could not find '$name' in archive downloaded from $Uri" -ErrorAction Stop
      }
      Copy-Item -Path $binary.FullName -Destination (Join-Path $InstallDir $name) -Force
    }
  }
  finally {
    Remove-Item -Path $zipFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Install-1PasswordCli {
  param(
    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$InstallDir
  )

  $arch = (Get-CimInstance Win32_OperatingSystem).OSArchitecture
  switch ($arch) {
    '64-bit' { $opArch = 'amd64'; break }
    '32-bit' { $opArch = '386'; break }
    Default { Write-Error "Sorry, your operating system architecture '$arch' is unsupported" -ErrorAction Stop }
  }
  Install-FromZip `
    -Uri "https://cache.agilebits.com/dist/1P/op2/pkg/v$Version/op_windows_${opArch}_v$Version.zip" `
    -InstallDir $InstallDir `
    -BinaryNames @('op.exe')
}

function Install-Npiperelay {
  param(
    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$InstallDir
  )

  Install-FromZip `
    -Uri "https://github.com/jstarks/npiperelay/releases/download/v$Version/npiperelay_windows_amd64.zip" `
    -InstallDir $InstallDir `
    -BinaryNames @('npiperelay.exe')
}

#
# Bootstrap
#

New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
Add-UserPath $ToolsDir

if (-not (Test-Path (Join-Path $ToolsDir 'op.exe'))) {
  Write-Host "Installing 1Password CLI $($OpVersion)..."

  Install-1PasswordCli -Version $OpVersion -InstallDir $ToolsDir
}

if (-not (Test-Path (Join-Path $ToolsDir 'npiperelay.exe'))) {
  Write-Host "Installing npiperelay $($NpiperelayVersion)..."

  Install-Npiperelay -Version $NpiperelayVersion -InstallDir $ToolsDir
}
