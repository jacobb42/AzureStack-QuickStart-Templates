#
# Copyright="?Microsoft Corporation. All rights reserved."
#

Configuration ConfigureVMIO {
    param (
        [string]$VMName,
        [Parameter(Mandatory)]
        [int32]$VMCount,
        [Parameter(Mandatory)]
        [string]$VMAdminUserName,
        [Parameter(Mandatory)]
        [string]$VMAdminPassword,
        [int32]$VMIoMaxLatency = 100,
        [Parameter(Mandatory)]
        [string]$Location,
        [Parameter(Mandatory)]
        [string]$AzureStorageAccount,
        [Parameter(Mandatory)]
        [string]$AzureStorageAccessKey,
        [Parameter(Mandatory)]
        [string]$AzureStorageEndpoint
    )

    netsh advfirewall set privateprofile state off
    $PSPath = $PSCommandPath

    # DSC Script Resource - VM io-storm
    Script VMIOAll {
        TestScript = { $false }

        GetScript = { return @{}}

        SetScript = {
			# Local file storage location
			$localPath = "$env:SystemDrive"

			# Log file
			$logFileName = "VMWorkloadControllerDSC.log"
			$logFilePath = "$localPath\$logFileName"

            $vmName = $using:VMName
            $vmCount = $using:VMCount
            # Needed for scheduled task to run with no logged-in user
            $vmAdminUserName = $using:VMAdminUserName
            $vmAdminPassword = $using:VMAdminPassword
            $vmIoMaxLatency = $using:VMIoMaxLatency
			$location = $using:Location
            $storageAccount = $using:AzureStorageAccount
            $storageKey = $using:AzureStorageAccessKey
            $storageEndpoint = $using:AzureStorageEndpoint
			$storageEndpoint = $storageEndpoint.ToLower()
            $psPath = $using:PSPath
			
			# Prepare storage context to upload results to Azure storage table
			if($storageEndpoint.Contains("blob")) {
				$storageEndpoint = $storageEndpoint.Substring($storageEndpoint.LastIndexOf("blob") + "blob".Length + 1)
				$storageEndpoint = $storageEndpoint.replace("/", "")
				# If storage endpoint have a port number remove portion after :3456 e.g. http://saiostorm.blob.azurestack.local:3456/
				if($storageEndpoint.Contains(":")) {
					$storageEndpoint = $storageEndpoint.Substring(0, $storageEndpoint.LastIndexOf(":"))
				}
			}
			
			"Storage endpoint given: $using:AzureStorageEndpoint Storage endpoint passed to script: $storageEndpoint" | Out-File $logFilePath -Encoding ASCII -Append

			# Create a scheduled task to execute controller script asynchronously
            $psScriptDir = Split-Path -Parent -Path $psPath
            $psScriptName = "VMIOWorkloadControllerScript.ps1"
            $psScriptPath = "$psScriptDir\$psScriptName"
            $action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "& $psScriptPath -vmName $vmName -vmCount $vmCount -vmIoMaxLatency $vmIoMaxLatency -location $location -azureStorageAccount $storageAccount -azureStorageAccessKey $storageKey -azureStorageEndpoint $storageEndpoint -Verbose"
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -DontStopOnIdleEnd -RestartCount 3 -RestartInterval 240 -ErrorAction Ignore
            Unregister-ScheduledTask -TaskName "VMIOController" -Confirm:0 -ErrorAction Ignore
            Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "VMIOController" -Description "VM iostorm" -User $vmAdminUserName -Password $vmAdminPassword -RunLevel Highest

			######################
			### AZURE RM SETUP ###
			######################
			# AzureStack
			if($location.Contains("local"))
			{
				# Ignore server certificate errors to avoid https://api.azurestack.local/ certificate error
				add-type @"
				using System.Net;
				using System.Security.Cryptography.X509Certificates;
				public class TrustAllCertsPolicy : ICertificatePolicy {
					public bool CheckValidationResult(
						ServicePoint srvPoint, X509Certificate certificate,
						WebRequest request, int certificateProblem) {
						return true;
					}
				}
"@
				[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
				Write-Warning -Message "CertificatePolicy set to ignore all server certificate errors"

		        # Download AzureStack Powershell SDK
                while (!$installFinished -and $count -lt 5) {
                    try {
                        Install-Module -Name AzureRM -RequiredVersion 1.2.6 -Scope AllUsers -ErrorAction Stop -Confirm:0
                        #Install-Module -Name Azure -Scope AllUsers -ErrorAction Stop -Confirm:0
                        $installFinished = $true
                    }
                    catch {
                        $count++
                        Start-Sleep -Seconds 10
                        Write-Warning "Could not install AzureRM module.  Trying again ($count / 5)"
                    }
                }
                Disable-AzureRmDataCollection       		
                		
				# Import Azure Resource Manager PS module if already present
				try {
					Write-Host "Importing Azure module"
					"Importing Azure module" | Out-File $logFilePath -Encoding ASCII -Append
					Import-Module Azure -ErrorAction Stop | Out-Null
				} catch [Exception] {
					Write-Warning "Cannot import Azure module. Cannot proceed further without Azure module. Exception: $_"
					"Cannot import Azure module. Cannot proceed further without Azure module. Exception: $_" | Out-File $logFilePath -Encoding ASCII -Append
					return
				}
			}
			# Azure Cloud
			else {
				# Import Azure Resource Manager PS module if already present
				try {
					Write-Host "Importing Azure module"
					"Importing Azure module" | Out-File $logFilePath -Encoding ASCII -Append
					Import-Module Azure -ErrorAction Stop | Out-Null
					Import-Module AzureRM.Compute -ErrorAction Stop | Out-Null
				}
				# Install Azure Resource Manager PS module
				catch {
					# Suppress prompts
					$ConfirmPreference = 'None'
					Write-Warning "Cannot import Azure module, proceeding with installation"
					"Cannot import Azure module, proceeding with installation" | Out-File $logFilePath -Encoding ASCII -Append

					# Install AzureRM
					try {
						Get-PackageProvider -Name nuget -ForceBootstrap –Force | Out-Null
						Install-Module Azure –repository PSGallery –Force -Confirm:0 | Out-Null
						Install-Module AzureRM.Compute –repository PSGallery –Force -Confirm:0 | Out-Null
					}
					catch {
						Write-Warning "Installation of Azure module failed."
						"Installation of Azure module failed." | Out-File $logFilePath -Encoding ASCII -Append
					}

					# Import AzureRM
					try {
						Import-Module Azure -ErrorAction Stop | Out-Null
						Import-Module AzureRM.Compute -ErrorAction Stop | Out-Null
						Import-Module AzureRM.Profile -ErrorAction Stop | Out-Null
					} catch {
						Write-Warning "Cannot import Azure module. Cannot proceed further without Azure module."
						"Cannot import Azure module. Cannot proceed further without Azure module." | Out-File $logFilePath -Encoding ASCII -Append
						return
					}
				}
			}
        }
    }
}