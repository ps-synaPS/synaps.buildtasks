[cmdletbinding()]
param(
    $TaskList = "compose",
    $Version = "0.0.1"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Module psake -ListAvailable -ErrorAction SilentlyContinue)) {
    Install-Module -Name psake -RequiredVersion 4.9.0 -Force
}

Invoke-psake -taskList $TaskList -parameters @{ Version = $Version; } -Verbose:$VerbosePreference

if ($psake.build_success -eq $false) { exit 1 } else { exit 0 }
