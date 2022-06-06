# Defines shared/standard properties for synaps builds across all repos
Properties {
    $SolutionRoot = $psake.context.originalDirectory
    $OutputRoot = Join-Path $SolutionRoot "BuildOutput"
    $BuiltPackages = Join-Path $OutputRoot "BuiltPackages"
    $TestOutputPath = Join-Path $OutputRoot "TestResults"
    $TestOutputFilePath = Join-Path $TestOutputPath "Results.xml"
}

# Defines all of the shared build tasks
## Top level "scriptblockless" tasks
Task tf_provider_setup -depends login_ps_az, configure_instance_value

Task login_ps_az -depends login_ps_az_service_principal, login_ps_az_as_user, set_az_subscription -precondition {
    Assert( $null -ne $env:ARM_TENANT_ID ) "ARM_TENANT_ID value required to login via az cli"
    Assert( $null -ne $env:ARM_SUBSCRIPTION_ID ) "ARM_SUBSCRIPTION_ID value required to login via az cli"
    return $true
}

## Tasks with "implementation"
Task psdepend_init_setup -requiredVariables @("PSDependConfiguration") {
    Write-Output "Installing dependencies:`n$(Import-PowerShellDataFile $PSDependConfiguration | ConvertTo-Json)"
    Invoke-PSDepend -Path $PSDependConfiguration -Install -Force
}

Task login_ps_az_service_principal -precondition { $true -eq $env:SYNAPS_CI_PIPELINE } {
    Assert ( $null -ne $env:ARM_CLIENT_SECRET ) "ARM_CLIENT_SECRET env var value required"
    Assert ( $null -ne $env:ARM_CLIENT_ID ) "ARM_CLIENT_ID env var value required"
    if (!(Get-AzContext)) {
        $connect_as_sp = @{
            Credential       = New-Object pscredential `
                -ArgumentList @($env:ARM_CLIENT_ID, (ConvertTo-SecureString $env:ARM_CLIENT_SECRET -AsPlainText -Force))
            Subscription     = $env:ARM_SUBSCRIPTION_ID
            Tenant           = $env:ARM_TENANT_ID
            ServicePrincipal = $true
        }
        Connect-AzAccount @connect_as_sp
    }

    # Now login with az cli
    try {
        $context = Exec { az account show 2> $null } | ConvertFrom-Json
    }
    catch {}

    if ($null -eq $context) {
        Exec { az login --service-principal --tenant $env:ARM_TENANT_ID -u $env:ARM_CLIENT_ID -p $env:ARM_CLIENT_SECRET --allow-no-subscriptions } | Out-Null
    }
}

Task login_ps_az_as_user -precondition { -not $env:SYNAPS_CI_PIPELINE -or $false -eq $env:SYNAPS_CI_PIPELINE } {
    if (!(Get-AzContext | Where-Object Tenant -Match $env:ARM_TENANT_ID)) {
        Connect-AzAccount -Subscription $env:ARM_SUBSCRIPTION_ID
    }

    # Now login with az cli
    try {
        $context = Exec { az account show 2> $null } | ConvertFrom-Json
    }
    catch {}

    if ($null -eq $context) {
        Exec { az login --tenant $env:ARM_TENANT_ID --allow-no-subscriptions } | Out-Null
    }
}

Task set_az_subscription {
    Exec { az account set --subscription $env:ARM_SUBSCRIPTION_ID }
}

Task login_az_container_registry -depends login_ps_az {
    Assert ( $null -ne $env:CONTAINER_REGISTRY_NAME ) "CONTAINER_REGISTRY_NAME env var value required"
    Connect-AzContainerRegistry -Name (Get-AzContainerRegistry | Where-Object Name -EQ $env:CONTAINER_REGISTRY_NAME).Name
}

Task transform_configuration_templates -depends set_configuration_defaults -requiredVariables @("TFInputVarTemplate", "TFInputVarFilePath") {
    Get-Content $TFInputVarTemplate | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) } | Set-Content $TFInputVarFilePath -Force
}


Task configure_instance_value {
    if ($env:SYNAPS_CI_PIPELINE) {
        Assert ( $null -ne $env:INSTANCE ) "INSTANCE env var value required"
    }
    else {
        if (-not $env:INSTANCE) {
            $env:INSTANCE = (Read-Host "Enter instance ID (Recommend first letter of firstname and lastname, i.e. John Smith = js)").ToLower()
        }
        else {
            Write-Output "Instance value set to $env:INSTANCE"
        }
    }
}

Task tf_fmt {
    Exec { terraform fmt -recursive }
}

Task set_backend_configuration {
    if (
        ($Instance -eq "ci" -and $env:INSTANCE -ne "ci") -or
        ($Instance -eq "dev" -and $env:INSTANCE -ne "dev")
    ) {
        Write-Output "Updating backend-config key value to $Solution.$Instance.$env:INSTANCE.tfstate"
        Properties {
            CustomBackendConfig = "-backend-config=`"key=$Solution.$Instance.$env:INSTANCE.tfstate`""
        }
    }
}

Task tf_init -depends tf_provider_setup, transform_configuration_templates, set_backend_configuration -requiredVariables @("TFWorkingDirectory") {
    Exec { terraform init $CustomBackendConfig -reconfigure } -workingDirectory $TFWorkingDirectory
}

Task tf_plan -depends tf_init {
    Exec { terraform plan -out $TFPlanOutputPath } -workingDirectory $TFWorkingDirectory
}

Task tf_apply -depends tf_init, tf_plan {
    Exec { terraform apply --auto-approve $TFPlanOutputPath } -workingDirectory $TFWorkingDirectory
}

Task tf_output -depends tf_init {
    Exec { terraform output --json | Set-Content $TFOutputPath } -workingDirectory $TFWorkingDirectory
}

Task tf_destroy -depends tf_init {
    Exec { terraform destroy --auto-approve } -workingDirectory $TFWorkingDirectory
}

Task run_docker_tfsec -precondition { -not $env:SYNAPS_CI_PIPELINE -or $false -eq $env:SYNAPS_CI_PIPELINE } -requiredVariables @("SolutionRoot") {
    Assert { $null -ne (Get-Command docker -ErrorAction SilentlyContinue) } "Docker must be installed to run tfsec locally"
    Exec { docker run --rm -it -v "$SolutionRoot`:/src" aquasec/tfsec /src }
}