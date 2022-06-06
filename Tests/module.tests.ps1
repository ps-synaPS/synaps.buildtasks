param(
    $ModuleName,
    $ModulePath,
    $Version
)

BeforeDiscovery {
    Get-Module $ModuleName | Remove-Module -Force -ErrorAction Ignore
    Import-Module -Name $ModulePath -Verbose:$false -ErrorAction Stop
}

Describe "Module Contents" {
    It "Should include a psakeFile.ps1" {
        Write-Host (Join-Path $ModulePath $Version "psakeFile.ps1")
        Test-Path (Join-Path $ModulePath $Version "psakeFile.ps1") | Should -Be $true
    }
}

