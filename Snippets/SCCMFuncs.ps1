### placeholder until I write a new clone apps UI script
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
				#Filter = "machineID = '$resID' and (DeploymentIntent = '2' and AppStatusType = '1' and not InstalledState = '1')"
				#Filter = "MachineName = '$Device' and (DeploymentIntent = '2' and AppStatusType = '1' and not InstalledState = '1')"
				Filter = "MachineID = '$resID' and ((EnforcementState = 1000 or EnforcementState = '1001') and InstalledState <> 1)"
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