Function logSomething {
	PARAM
    (
	[Parameter(Position=0, Mandatory=$True)] [string]$text
    )
	Try{
		#Write-Output "$(get-date) : $text" | Add-Content $logFile -ErrorAction SilentlyContinue
		Write-Host "$(get-date) : $text"
	}
	Catch{
		#throw $_.exception.message
	}
}

function New-TSEnv{
	# used in a Task Sequence to read/write TS environment variables
	Try{
		$TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
		return $TSEnv
	}
	Catch{
		return $null
	}
}

function Set-TSVar {
	# used in a task sequence to set a task sequence variable
    PARAM
    (
    [Parameter(Position=0, Mandatory=$True)] [string]$TSVar,
    [Parameter(Position=1)] [string]$value
    )
	Try{
		$TSEnv.Value($TSVar) = $value
	}
	Catch{
        #write-host "error: not running in a TS"
        #write-host "Error: $($_.exception.message)"
	}
}

function Get-TSVar {
	# used in a task sequence to get a task sequence variable
    param(
    [Parameter(Position=0, Mandatory=$True)] [string]$TSVar
    )
	Try{
		return $TSEnv.Value($TSVar)
	}
	Catch{
        #write-host "error: not running in a TS"
        #write-host "Error: $($_.exception.message)"
	}
}

function Get-DeployedApps{
	# used to get a list of applications that are deployed to the specified collection.
	# use the installableOnly switch to get apps that will be "installable" during a task sequence
	param(
    [Parameter(Mandatory=$True)] [string]$CollectionName,
	[Parameter(Mandatory=$false)] [switch]$installableOnly,
	[Parameter(Mandatory=$False)] [CimSession]$CimSession,
	[Parameter(Mandatory=$False)] [string]$SiteServer,
	[Parameter(Mandatory=$True)] [string]$SiteCode,
	[Parameter(Mandatory=$False)] [string]$SkipText,
	[Parameter(Mandatory=$False)] [PSCredential]$Credentials
    )
	try{
		$AppsToReturn = @()
		logSomething "Starting to get applications deployed to $CollectionName"
		#create a CimSession if necessary
		if(-not($CimSession)){
			logSomething "CimSession not found. Creating CimSession on $SiteServer"
			$thisCimSession = New-CimSession -ComputerName $SiteServer -Credential $Credentials
			$newCimSession = $true
		}
		else{
			$thisCimSession = $CimSession
		}
		logSomething "Getting deployed applications"
		$query = "select * from SMS_ApplicationAssignment where CollectionName = '$CollectionName' and DesiredConfigType = 1"
		$allDeployedApps = Get-CimInstance -CimSession $thisCimSession -namespace "root\sms\site_$SiteCode" -Query $query
		logSomething "-- Got $(($allDeployedApps | Measure-Object).count) applications"
		if($allDeployedApps){
			ForEach($app in $allDeployedApps){
				logSomething "Processing $($app.ApplicationName)"
				$CI_UID = $app.AssignedCI_UniqueID
				$CMApp = Get-CimInstance -CimSession $thisCimSession -namespace "root\sms\site_$SiteCode" -Class SMS_Application -Filter "CI_UniqueId='$($CI_UID)'"
				if($installableOnly){
					$installableApp = Get-AppInstallabilityInTS -CimSession $thisCimSession -CMApp $CMApp -SiteCode $SiteCode
					if($installableApp){
						$AppsToReturn += $installableApp
					}
				}
				else{
					$AppsToReturn += $CMApp
				}
			}
			# return the apps:
			return $AppsToReturn
		}
		else{
			# no apps deployed
			logSomething "WARNING: No applications deployed to $CollectionName"
			return $null
		}
	}
	catch{
		#catch errors
		logSomething "Error: $($_.exception.message)"
		return $null
	}
	finally{
		#dispose CimSession if necessary
		if($newCimSession){
			$thisCimSession | Remove-CimSession
		}
	}
}

function Get-AppInstallabilityInTS{
	# check if application will be installable inside a TS
	param(
	[Parameter(Mandatory=$True)] [CimSession]$CimSession,
	[Parameter(Mandatory=$True)] [string]$SiteCode,
	[Parameter(Mandatory=$True)] $CMApp,
	[Parameter(Mandatory=$False)] [string]$SkipText,
	[Parameter(Mandatory=$False)] [PSCredential]$Credentials
    )
	try{
		logSomething "Checking $($CMApp.Name) for installability"
		# check for SkipText
		if($SkipText){
			if($CMApp.LocalizedDescription -match '$SkipText'){
				logSomething "-- Skipped for matching our exclusion text"
				return $null
			}
		}
		$CMApp = $CMApp | Get-CimInstance -CimSession $CimSession
		# check for AutoInstall
		if($CMApp.AutoInstall -eq $true){
			# check if Expired
			if($CMApp.IsExpired -eq $false){
				logSomething "-- installability confirmed"
				return $CMApp
			}
			else{
				# app is retired
				logSomething "-- WARNING: application is expired (WARN)"
				return $null
			}
		}
		else{
			# not set to install in a TS
			logSomething "-- WARNING: application not set to be installed during a TS"
			return $null
		}
	}
	catch{
		logSomething "Error: $($_.exception.message)"
		return $null
	}
	finally{
		# nothing to do here
	}
}

function Clear-AppBaseVar{
	# used to clear an application base variable
	logSomething "Clearing $baseVar TS variables"
	$count = 1
	$done = $false
	While($done -eq $false) {
		if($TSEnv){
			$fNum = "{0:D2}" -f [int]$count
			$thisVar = "$baseVar" + $fNum
			logSomething "Processing $thisVar"
			if($TSEnv.Value($thisVar) -ne ""){
				$TSEnv.Value($thisVar) = ""
				logSomething "-- Successfully cleared"
				++$count
			}
			else{
				logSomething "-- Not found... end of list"
				#no more to clear
				$done = $true
			} 
		}
		Else{
			logSomething "Warning: could not locate TS environment"
			$done = $true
		}
	}
	logSomething "$baseVar TS variables successfully cleared. $($count -1) variables removed"
}

function Get-InstalledAppsForMachine {
	# used to get a list of applications that were successfully installed from software center for a given machine
	# can be used as a simple "cloning" function when run from within a task sequence
	param(
	[Parameter(Mandatory=$True)] $Device, #resourceid or name
	[Parameter(Mandatory=$False)] [CimSession]$CimSession,
	[Parameter(Mandatory=$False)] [string]$SiteServer,
	[Parameter(Mandatory=$False)] [string]$SiteCode,
	[Parameter(Mandatory=$False)] [PSCredential]$Credentials
    )
	try{
		if(-not($CimSession)){
			logSomething "CimSession not found. Creating CimSession on $SiteServer"
			$thisCimSession = New-CimSession -ComputerName $SiteServer -Credential $Credentials
			$newCimSession = $true
		}
		else{
			$thisCimSession = $CimSession
		}
		if($Device -isNot [int]){
			$query = "Select * from SMS_R_System where Name = '$($Device)'"
			$thisDevice = Get-CimInstance -CimSession $thisCimSession -Namespace "root/sms/site_$SiteCode" -query $query
			$resId = $thisDevice.ResourceId
		}
		else{
			$resId = $Device
		}

		if($resId){
			$query = @{
				CimSession = $thisCimSession
				NameSpace = "root\sms\site_$SiteCode"
				Class = "SMS_AppDeploymentAssetDetails"
				Filter = "machineID = '$resID' and (DeploymentIntent = '2' and AppStatusType = '1' and not InstalledState = '1')"
				#Filter = "MachineName = '$Device' and (DeploymentIntent = '2' and AppStatusType = '1' and not InstalledState = '1')"
			}
			$InstalledApps = Get-CimInstance @query
			return $InstalledApps
		}
		else{
			Write-Host "$Device not found in ConfigMgr"
		}
	}
	catch{
		$_.exception.message
	}
	finally{
		if($newCimSession){
			$thisCimSession | Remove-CimSession
		}
	}
}  