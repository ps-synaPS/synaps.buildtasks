Properties {
    $Solution = "synaps.buildtasks"
    $SolutionRoot = $psake.context.originalDirectory
    $ModuleDocsRoot = Join-Path $SolutionRoot (Join-Path "Source" "en-US")
    $OutputRoot = Join-Path $SolutionRoot "BuildOutput"
    $BuiltPackages = Join-Path $OutputRoot "BuiltPackages"
    $TestOutputPath = Join-Path $OutputRoot "TestResults"
    $TestOutputFilePath = Join-Path $TestOutputPath "Results.xml"
    $SourcePathRoot = Join-Path $SolutionRoot "Source"
    $Psd1File = Join-Path $SourcePathRoot "$Solution.psd1"

    # Local PS Repo Config
    $LocalPSRepoName = "$Solution-local-dev-repo"
    $LocalPSRepoPath = Join-Path $OutputRoot "LocalPSRepo"
}

Task compose -depends build, test
Task publish -depends publish_module

BuildSetup {
    $script:ModuleName = (Import-PowerShellDataFile $Psd1File).RootModule.replace(".psm1", "")
    $script:PublishLocation = Join-Path $OutputRoot $ModuleName
    $script:ModuleOutput = Join-Path $OutputRoot $ModuleName
}

Task init {
    Find-Module PSDepend -RequiredVersion 0.3.8 | Install-Module -Scope CurrentUser -Confirm:$False -Force | Import-Module

    $dependencies = @{
        PSDependOptions    = @{
            Target = "CurrentUser"
        }
        'Pester'           = '5.1.1'
        'ModuleBuilder'    = '2.0.0'
        'PSScriptAnalyzer' = '1.19.1'
    }
    Write-Output "Installing dependencies:`n$($dependencies | ConvertTo-Json)"
    Invoke-PSDepend $dependencies -Install -Force
    New-Item -Path $OutputRoot -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
}

Task build -depends clean {
    New-Item -Path $ModuleDocsRoot -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
    Build-Module -SourcePath $SourcePathRoot -OutputDirectory $ModuleOutput -SemVer $Version
}

Task test -depends "static-script-analysis" {
    Remove-Module $Solution -ErrorAction SilentlyContinue
    New-Item $TestOutputPath -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
    $c = New-PesterContainer -Path Tests -Data @{ ModulePath = $PublishLocation; ModuleName = $Solution; Version = $Version }
    Invoke-Pester -Container $c -Output Detailed -PassThru | ConvertTo-NUnitReport -AsString | Out-File $TestOutputFilePath
}

Task "static-script-analysis" {
    # See https://github.com/PowerShell/PSScriptAnalyzer/issues/636
    Invoke-ScriptAnalyzer -Path "Source" -ExcludeRule @('PSUseDeclaredVarsMoreThanAssignments', 'PSAvoidUsingEmptyCatchBlock', 'PSAvoidUsingConvertToSecureStringWithPlainText') -Recurse -ReportSummary
}

Task clean {
    Get-ChildItem $OutputRoot | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

Task publish_module {
    if ($env:ci_pipeline) {
        Assert($null -ne $env:PSGALLERY_API_KEY)
        $Publish_Args = @{
            Name            = $Solution
            Path            = $PublishLocation
            Repository      = "PSGallery"
            NuGetApiKey     = $env:PSGALLERY_API_KEY
            AllowPrerelease = $true
        }
    }
    else {
        if ($null -eq (Get-PSRepository -Name $LocalPSRepoName -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Name $LocalPSRepoName `
                -SourceLocation $LocalPSRepoPath `
                -PublishLocation $LocalPSRepoPath
        }

        if ($env:PSModulePath -split ";" -notcontains $LocalPSRepoPath) {
            $env:PSModulePath += $LocalPSRepoPath
        }

        $Publish_Args = @{
            Path       = $PublishLocation
            Repository = $LocalPSRepoName
        }
    }
    $Publish_Args
    Publish-Module @Publish_Args
}