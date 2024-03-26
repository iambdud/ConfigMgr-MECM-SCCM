# used in a task sequence to get a list of applications deployed to a collection and add them to a base variable to install during a TS
	
#region functions
Function logSomething {
	PARAM
    (
	[Parameter(Position=0, Mandatory=$True)] [string]$text
    )
	Try{
		Write-Output "$(get-date) : $text" | Add-Content $logFile -ErrorAction SilentlyContinue
		#Write-Host "$(get-date) : $text"
	}
	Catch{
		#throw $_.exception.message
	}
}

function Get-DeployedApps{
	# used to get a list of applications that are deployed to the specified collection.
	# use the SkipText switch to eclude apps that have $SkipText in their description
	param(
    [Parameter(Mandatory=$True)] [string]$CollectionName,
	[Parameter(Mandatory=$True)] [string]$SiteServer,
	[Parameter(Mandatory=$True)] [string]$SiteCode,
	[Parameter(Mandatory=$True)] [PSCredential]$Credentials,
	[Parameter(Mandatory=$False)] [switch]$installableOnly,
	[Parameter(Mandatory=$False)] [string]$SkipText
    )
	try{
		$AppsToReturn = @()
		logSomething "Getting applications deployed to $CollectionName"
		#create a CimSession		
		logSomething "Creating CimSession on $SiteServer for $($Credentials.UserName)"
		$thisCimSession = New-CimSession -ComputerName $SiteServer -Credential $Credentials -ErrorAction Stop
		logSomething "-- CimSession created: $($thisCimSession)"
		logSomething "Getting the deployed applications"
		$query = "select * from SMS_ApplicationAssignment where CollectionName = '$CollectionName' and DesiredConfigType = 1"
		$allDeployedApps = Get-CimInstance -CimSession $thisCimSession -namespace "root\sms\site_$SiteCode" -Query $query
		logSomething "-- Got $(($allDeployedApps | Measure-Object).count) applications"
		if($allDeployedApps){
			ForEach($app in $allDeployedApps){
				logSomething "Processing $($app.ApplicationName)"
				$CI_UID = $app.AssignedCI_UniqueID
				$CMApp = Get-CimInstance -CimSession $thisCimSession -namespace "root\sms\site_$SiteCode" -Class SMS_Application -Filter "CI_UniqueId='$($CI_UID)'"
				$installableApp = Get-AppInstallabilityInTS -CimSession $thisCimSession -CMApp $CMApp -SkipText $SkipText
				if($installableApp){
					$AppsToReturn += $installableApp
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
		if($thisCimSession){
			$thisCimSession | Remove-CimSession
		}
	}
}

function Get-AppInstallabilityInTS{
	# check if application will be installable inside a TS
	param(
	[Parameter(Mandatory=$True)] [CimSession]$CimSession,
	[Parameter(Mandatory=$True)] $CMApp,
	[Parameter(Mandatory=$False)] [string]$SkipText
    )
	try{
		logSomething "Checking installability"
		# check for SkipText
		if($SkipText){
			if($CMApp.LocalizedDescription -match '$SkipText'){
				logSomething "-- Skipped for matching our exclusion text"
				return $null
			}
		}
		$CMApp = $CMApp | Get-CimInstance -CimSession $CimSession
		# check for AutoInstall
		if(([xml]$CMApp.SDMPackageXML).AppMgmtDigest.Application.AutoInstall -eq "true"){
			# check if Expired
			if($CMApp.IsExpired -eq $false){
				logSomething "-- PASS"
				return $CMApp
			}
			else{
				# app is retired
				logSomething "-- FAIL: application is expired (WARN)"
				return $null
			}
		}
		else{
			# not set to install in a TS
			logSomething "-- FAIL: application not set to be installed during a TS"
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
	param(
    [Parameter(Position=0, Mandatory=$True)] [string]$baseVar
    )
	logSomething "Clearing base variable: $baseVar"
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

#endregion

# setup the TSEnv:
Try{
	$TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
	$SMSTSLog = $TSEnv.value("_SMSTSLogPath")
}
Catch{
	# no TS env... bail
	environment::Exit[1]
}

# setup the log file:
$LogFile = "$SMSTSLog\getDeployedApps.log"

logSomething "Starting script"
logSomething "Gathering variables"

$BaseVar = "BaseVar"
$SiteServer = $TSEnv.Value("SiteServer")
$SiteCode = $TSEnv.Value("SiteCode")
$CollectionName = $TSEnv.Value("CollectionName")
$SkipText = $TSEnv.Value("SkipText")
# get credentials from TS variables:
$SvcAccount = $TSEnv.Value("QueryUser")
$SvcAccountPassword = $TSEnv.Value("QueryPassword")
$SvcAccountPassword = $SvcAccountPassword | ConvertTo-SecureString -AsPlainText -Force -ErrorAction SilentlyContinue
$Credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $SvcAccount,$SvcAccountPassword

# clear existing $baseVar
Clear-AppBaseVar -baseVar $baseVar

# get the "installable" applications deployed to $CollectionName
$deployedApps = Get-DeployedApps -CollectionName $CollectionName -SiteServer $SiteServer -SiteCode $SiteCode -Credentials $Credentials -installableOnly -SkipText $SkipText

# add each app name to $baseVar[XX]
if($deployedApps){
	logSomething "Adding applications to $BaseVar"
	$count = 1
	foreach ($app in $deployedApps){
		$fNum = "{0:D2}" -f [int]$count
		$TSVariableName = $baseVar + $fNum 
		logSomething "-- $TSVariableName = $($app.LocalizedDisplayName)"
		$TSEnv.Value($TSVariableName) = $app.LocalizedDisplayName
		$count++
	}
}
else{
	logSomething "Warning: No applications found"
}

logSomething "-------- Complete --------"