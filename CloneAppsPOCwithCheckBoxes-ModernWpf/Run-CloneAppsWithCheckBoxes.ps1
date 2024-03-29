# PowerShell GUI app to get a list of applications installed (according to SCCM) on a specified device and add each application to a BaseVar for installationg during a task sequence
# populate listbox with "installable" applications OR better if i can do a bunch of checkboxes (unchecked and grayed out if not "installable" with tooltip showing why? or hideable list of apps that are not "installable" with button to show/hide?)

Set-Location $PSScriptRoot
[IO.Directory]::SetCurrentDirectory($PSScriptRoot)

#region load xaml
#Add WPF and Windows Forms assemblies
try{
	Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase,system.windows.forms
	[Reflection.Assembly]::LoadFrom("$($PSScriptRoot)\assemblies\System.ValueTuple.dll") | Out-Null
	[reflection.Assembly]::LoadFrom("$($PSScriptRoot)\assemblies\ModernWpf.dll") | Out-Null
	[reflection.Assembly]::LoadFrom("$($PSScriptRoot)\assemblies\ModernWpf.Controls.dll") | Out-Null
}
catch{
	Throw "Failed to load Windows Presentation Framework assemblies."
}
#Required to load the XAML form and create the PowerShell Variables
$XamlPath = "$PSScriptRoot\xaml\MainForm.xaml"
[xml]$Global:xmlWPF = Get-Content -Path $XamlPath
$Global:xmlWPF.Window.RemoveAttribute('x:Class')
$Global:xmlWPF.Window.RemoveAttribute('mc:Ignorable')

#Create the XAML reader using a new XML node reader
$Global:xamGUI = [Windows.Markup.XamlReader]::Load((new-object System.Xml.XmlNodeReader $xmlWPF))

$namespace = @{ x = 'http://schemas.microsoft.com/winfx/2006/xaml' }
$xpath_formobjects = "//*[@*[contains(translate(name(.),'n','N'),'Name')]]"

# Create a variable for every named xaml element
Select-Xml $xmlWPF -Namespace $namespace -xpath $xpath_formobjects | ForEach-Object {
	$_.Node | ForEach-Object {
		Set-Variable -Name ($_.Name) -Value $xamGUI.FindName($_.Name) -Scope Global
	}
}

# if doing a responsive UI, you need a synchronized hashtable
$syncHash = [hashtable]::Synchronized(@{})
$syncHash.Window = $xamGUI
Select-Xml $xmlWPF -Namespace $namespace -xpath $xpath_formobjects | ForEach-Object {
	$_.Node | ForEach-Object {
        $syncHash.$($_.Name) = $syncHash.Window.FindName($_.Name)
	}
}
#endregion

Function logSomething {
	param(
		[Parameter(Position=0, Mandatory=$True)] [string]$text,
		[Parameter(Position=1, Mandatory=$False)] [switch]$updateUI
	)
	Try{
		if($updateUI){
			$tbStatus.Text = "$text"
		}
		Write-Output "$(get-date) : $text" | Add-Content $logFile -ErrorAction SilentlyContinue
	}
	Catch{}
}

#setup TS object
Try{
	$TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
	$SMSTSLog = $TSEnv.value("_SMSTSLogPath")
}
Catch{}

#close TS UI to show our window
Try{
	$TSProgressUI = new-object -comobject Microsoft.SMS.TSProgressUI
	$TSProgressUI.CloseProgressDialog()
}
Catch{}

#setup the log file
$LogFile = "$SMSTSLog\cloneApps.log"
if(!$SMSTSLog){
	$LogFile = "$PSScriptRoot\cloneApps.log"
}
$syncHash.logFile = $LogFile

logSomething "Starting script"

$syncHash.BaseVar = "BaseVar"
if($TSEnv){
	$syncHash.SiteServer = $TSEnv.Value("SiteServer")
	$syncHash.SiteCode = $TSEnv.Value("SiteCode")
	$syncHash.Namespace = "Root\SMS\Site_$($syncHash.SiteCode)"
	$syncHash.SkipText = $TSEnv.Value("SkipText")
	# get credentials from TS variables:
	$syncHash.QueryUser = $TSEnv.Value("QueryUser")
	$syncHash.QueryPassword = $TSEnv.Value("QueryPassword")
	$syncHash.QueryPassword = $syncHash.QueryPassword | ConvertTo-SecureString -AsPlainText -Force -ErrorAction SilentlyContinue
	$syncHash.Credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $syncHash.QueryUser,$syncHash.QueryPassword
}
else{
	$syncHash.SiteServer = "cm01.corp.bdud.org"
	$syncHash.SiteCode = "PS1"
	$syncHash.Namespace = "Root\SMS\Site_$($syncHash.SiteCode)"
	$syncHash.SkipText = "NO_CLONE"
}

$MainWindow.DataContext = $syncHash

logSomething "SiteServer: $($syncHash.SiteServer)"
logSomething "SiteCode: $($syncHash.SiteCode)"
logSomething "SkipText: $($syncHash.SkipText)"
logSomething "QueryUser: $($syncHash.QueryUser)"
logSomething "QueryPassword: *****"

function Invoke-Initialize{
    param($syncHash)
	$Runspace = [runspacefactory]::CreateRunspace()
	$Runspace.ApartmentState = "STA"
	$Runspace.ThreadOptions = "ReuseThread"
	$Runspace.Open()
	$Runspace.SessionStateProxy.SetVariable("syncHash",$syncHash)
	$Runspace.SessionStateProxy.SetVariable("logFile",$LogFile)

	$code = {
		Function logSomething {
			param(
				[Parameter(Position=0, Mandatory=$True)] [string]$text,
				[Parameter(Position=1, Mandatory=$False)] [switch]$updateUI
			)
			Try{
				if($updateUI){
					$syncHash.Window.Dispatcher.invoke([action]{$syncHash.tbStatus.Text = "$text"})
				}
				Write-Output "$(get-date) : $text" | Add-Content $logFile -ErrorAction SilentlyContinue
			}
			Catch{}
		}

		logSomething "Beginning initialization" -updateUI
		logSomething "Creating CimSession on $($syncHash.SiteServer)" -updateUI
		try{
			# excluded apps lookup:
			$excCount = 0
			$syncHash.CimSession = New-CimSession -ComputerName $syncHash.SiteServer -Credential $syncHash.Credentials -ErrorAction Stop
			logSomething "Beginning excluded apps lookup" -updateUI
			$excApps = Get-CimInstance -CimSession $syncHash.CimSession -Namespace $syncHash.Namespace -Class SMS_Application -Filter "IsLatest='True' and LocalizedDescription like '%$($syncHash.SkipText)%'"
			Foreach($app in $excApps){
				#add the name to excluded apps
				logSomething "$($app.LocalizedDisplayName) has been added to the list of excluded apps"
				Write-Output "$(get-date) : $($app.LocalizedDisplayName) has been added to the list of excluded apps" | Add-Content $LogFile
				$syncHash.excludedApps += $app.LocalizedDisplayName
				$excCount++
			}
			logSomething "Excluded App lookup complete. $($excCount) apps will be excluded." -updateUI
			# primary device lookup:
			# get currently logged on user:
			try{
				logSomething "Beginning device lookup" -updateUI
				$CurrentUser = (Get-Process -IncludeUserName -Name explorer | Select-Object UserName -Unique).UserName
				logSomething "Current User: $($CurrentUser)"
				if($CurrentUser){
					logSomething "Getting devices for $CurrentUser"
					$query = ("SELECT * FROM SMS_UserMachineRelationship WHERE UniqueUserName IN ('$($CurrentUser)' ) AND IsActive = 1").replace('\','\\')
					$UDAs = Get-CimInstance -CimSession $synchash.CimSession -Namespace $syncHash.Namespace -query $query
					logSomething "Found $(($UDAs | Measure-Object).count) devices." -updateUI
					if($UDAs){
						# add to ListBox
						foreach($device in $UDAs){
							logSomething "-- $($device.ResourceName) :: $($device.ResourceId)"
							$syncHash.Window.Dispatcher.invoke([action]{
								$syncHash.lstDevices.Items.Add([pscustomobject]@{
									'Name' = $device.ResourceName;
									'ResourceId' = $device.ResourceId
								})
							})
						}
						# enable the listbox and select the first item, enable chkManual, enable btnNext:
						$syncHash.Window.Dispatcher.invoke([action]{
							$syncHash.lstDevices.DisplayMemberPath = "Name"
							$syncHash.lstDevices.SelectedValuePath = "ResourceId"
							$syncHash.lstDevices.IsEnabled = $true
							$syncHash.lstDevices.SelectedIndex = 0
							$syncHash.chkManual.IsEnabled = $true
							$syncHash.btnNext.IsEnabled = $true
						})
						logSomething "Select a device and click Next to being app lookup." -updateUI
					}
				}
			}
			catch{
				logSomething "Error looking up devices. Enter a computer name." -updateUI
				logSomething "$($_.Exception.Message)"
				$syncHash.NoDevices = $true
				# hide listbox, check the manual box, set focus on textbox
				$syncHash.Window.Dispatcher.invoke([action]{
					$syncHash.lstDevices.IsEnabled = $false
					$syncHash.chkManual.IsEnabled = $false
					$syncHash.chkManual.IsChecked = $true
					$syncHash.txtComp.Focus()
					$syncHash.btnNext.IsEnabled = $true
				})
			}
		}
		catch{
			logSomething "Error. Check the log" -updateUI
			logSomething "$($_.Exception.Message)"
		}
		$Runspace.Close()
		$Runspace.Dispose()
	}
	$PSinstance = [powershell]::Create().AddScript($Code)
	$PSinstance.Runspace = $Runspace
	$job = $PSinstance.BeginInvoke()
}

function Invoke-AppLookup{
	param($syncHash)
	$Runspace = [runspacefactory]::CreateRunspace()
	$Runspace.ApartmentState = "STA"
	$Runspace.ThreadOptions = "ReuseThread"
	$Runspace.Open()
	$Runspace.SessionStateProxy.SetVariable("syncHash",$syncHash)
	$Runspace.SessionStateProxy.SetVariable("logFile",$LogFile)
	$Runspace.SessionStateProxy.SetVariable("chkManual",$chkManual.IsChecked)
	$Runspace.SessionStateProxy.SetVariable("srcCompName",$txtComp.Text)
	$Runspace.SessionStateProxy.SetVariable("srcCompFromList",$lstDevices.SelectedItem)

	$code = {
		Function logSomething {
			param(
				[Parameter(Position=0, Mandatory=$True)] [string]$text,
				[Parameter(Position=1, Mandatory=$False)] [switch]$updateUI
			)
			Try{
				if($updateUI){
					$syncHash.Window.Dispatcher.invoke([action]{$syncHash.tbStatus.Text = "$text"})
				}
				Write-Output "$(get-date) : $text" | Add-Content $logFile -ErrorAction SilentlyContinue
			}
			Catch{}
		}
		function AddCheckBox{
			param($appName)
			$checkBox = New-Object System.Windows.Controls.CheckBox
			$checkBox.Content = $thisApp.LocalizedDisplayName
			$checkBox.Margin = New-Object System.Windows.Thickness(5,0,15,0)  # Set margin
			$checkBox.IsChecked = $true
			$syncHash.CheckboxContainer.Children.Add($checkBox)
		}
		# if $syncHash.chkManual.IsChecked, lookup resource id
		if($chkManual){
			logSomething "Beginning application lookup for $srcCompName" -updateUI
			logSomething "Getting ResourceId"
			$resId = (Get-CimInstance -CimSession $syncHash.CimSession -Namespace $syncHash.Namespace -ClassName "SMS_R_System" -Filter "Name = '$($srcCompName)'").ResourceId
			logSomething "ResourceId: $($resId)"
		}
		# else, use resourceId from $syncHash.SelectedItem.ResourceId
		else{
			logSomething "Beginning application lookup for $($srcCompFromList.Name) :: $($srcCompFromList.ResourceId)" -updateUI
			$resID = $srcCompFromList.ResourceId
		}
		if($resID){
			logSomething "Getting list of applications" -updateUI
			$query = @{
				CimSession = $syncHash.CimSession
				NameSpace = $syncHash.Namespace
				Class = "SMS_AppDeploymentAssetDetails"
				#Filter = "machineID = '$resID' and (DeploymentIntent = '2' and AppStatusType = '1' and not InstalledState = '1')"
				Filter = "MachineID = '$resID' and ((EnforcementState = 1000 or EnforcementState = '1001') and InstalledState <> 1)"
			}
			$InstalledApps = Get-CimInstance @query
			logSomething "Found $(($InstalledApps | Measure-Object).count) applications"
			$count = 1
			if($InstalledApps){
				# remove "excluded" apps
				$matchedExcludedApps = $installedApps | Where-Object AppName -In $syncHash.excludedApps | Sort-Object -Property AppName
				$installedApps = $installedApps | Where-Object AppName -NotIn $syncHash.excludedApps | Sort-Object -Property AppName
				if($matchedExcludedApps){
					logSomething "The following apps were found but match our exclusion rule:"
					foreach($MEA in $matchedExcludedApps){
						logSomething " -- $($MEA.appname)"
					}
				}
				# remove duplicates
				$installedApps = $installedApps | Select-Object AppName -Unique | ForEach-Object {$installedApps | Where-Object AppName -eq $_.AppName | Sort-Object AppName | Select-Object -First 1}

				# check "installability" of each app
				foreach($app in $InstalledApps){
					logSomething "Checking $($app.AppName)"
					$CMApp = Get-CimInstance -CimSession $syncHash.CimSession -namespace $syncHash.Namespace -Class SMS_Application -Filter "LocalizedDisplayName='$($app.appname)' and IsLatest='True'"
					try{
						$thisApp = $CMApp | Get-CimInstance -CimSession $syncHash.CimSession
						# check for AutoInstall
						if(([xml]$thisApp.SDMPackageXML).AppMgmtDigest.Application.AutoInstall -eq "true"){
							# check if Expired
							if($thisApp.IsExpired -eq $false){
								logSomething "-- Added"
								$syncHash.Window.Dispatcher.invoke([action]{
									AddCheckBox $thisApp.LocalizedDisplayName
								})
								$count++
							}
							else{
								# app is retired
								logSomething "-- Skipped: application is expired (WARN)"
							}
						}
						else{
							# not set to install in a TS
							logSomething "-- Skipped: application not set to be installed during a TS (WARN)"
						}
					}
					catch{
						logSomething "Error: $($_.exception.message)"
						return $null
					}
				}
				
				logSomething "$($count - 1) applications were added to the list"
				if($count -eq 1){
					logSomething "Warning: No installable applications found for $srcMachine. Click Back to try another." -updateUI
				}
				else{
					if($count -gt 100){
						logSomething "$($count - 1) app(s) found. Be sure the select 99 or fewer applications" -updateUI
					}
					Else{
						logSomething "$($count - 1) app(s) found. Select applications and click Done." -updateUI
					}
					
				}
				# enable buttons and focus list
				$syncHash.Window.Dispatcher.invoke([action]{
					#$syncHash.MainWindow.DataContext = $syncHash
					$syncHash.btnNext.Content = "Done"
					$syncHash.btnNext.IsEnabled = $true
					$syncHash.btnBack.IsEnabled = $true
					$syncHash.btnAll.IsEnabled = $true
					$syncHash.btnNone.IsEnabled = $true
					$syncHash.grdCheckBoxContainer.IsEnabled = $true
				})
			}
			# no apps found
			else{
				logSomething "No applications found. Please try another device" -updateUI
				$syncHash.Window.Dispatcher.invoke([action]{
					$syncHash.btnNext.Content = "Next"
					$syncHash.btnNext.IsEnabled = $true
					$syncHash.btnBack.IsEnabled = $true
					$syncHash.btnAll.IsEnabled = $false
					$syncHash.btnNone.IsEnabled = $false
					$syncHash.chkManual.IsEnabled = $true
					$syncHash.grdCheckBoxContainer.IsEnabled = $false
				})
			}
			
		}
		# manual lookup, computer not found:
		else{
			logSomething "Device not found. Please try another computer name" -updateUI
				$syncHash.Window.Dispatcher.invoke([action]{
					$syncHash.btnNext.Content = "Next"
					$syncHash.btnNext.IsEnabled = $true
					$syncHash.btnBack.IsEnabled = $false
					$syncHash.btnAll.IsEnabled = $false
					$syncHash.btnNone.IsEnabled = $false
					$syncHash.lstDevices.IsEnabled = $true
					$syncHash.txtComp.IsEnabled = $true
					$syncHash.grdCheckBoxContainer.IsEnabled = $false
					$syncHash.txtComp.Focus()
					if(!$syncHash.NoDevices){
						$syncHash.chkManual.IsEnabled = $true
					}
				})
		}
	}
	$PSinstance = [powershell]::Create().AddScript($Code)
	$PSinstance.Runspace = $Runspace
	$job = $PSinstance.BeginInvoke()
}

function Invoke-BuildBaseVariable{
	param($syncHash,$SelectedApps)
	$Runspace = [runspacefactory]::CreateRunspace()
	$Runspace.ApartmentState = "STA"
	$Runspace.ThreadOptions = "ReuseThread"
	$Runspace.Open()
	$Runspace.SessionStateProxy.SetVariable("syncHash",$syncHash)
	$Runspace.SessionStateProxy.SetVariable("logFile",$LogFile)
	$Runspace.SessionStateProxy.SetVariable("selectedApps",$selectedApps)
	$Runspace.SessionStateProxy.SetVariable("TSEnv",$TSEnv)

	$code = {
		Function logSomething {
			param(
				[Parameter(Position=0, Mandatory=$True)] [string]$text,
				[Parameter(Position=1, Mandatory=$False)] [switch]$updateUI
			)
			Try{
				if($updateUI){
					$syncHash.Window.Dispatcher.invoke([action]{$syncHash.tbStatus.Text = "$text"})
				}
				Write-Output "$(get-date) : $text" | Add-Content $logFile -ErrorAction SilentlyContinue
			}
			Catch{}
		}
		$count = 1
		logSomething "Finalizing..." -updateUI
		logSomething "Adding variables for $($selectedApps.Count) apps"
		if($selectedApps.Count -gt 99){
			logSomething "Warning... more than 99 apps were selected. We will stop at 99. Anything after that will not be installed..."
		}
		foreach($sApp in $selectedApps){
			if($count -gt 99){
				logSomething "Warning: $sApp : skipped (max of 99 applications reached)" -updateUI
				continue
			}
			$fNum = "{0:D2}" -f [int]$count
			$TSVariableName = $syncHash.BaseVar + $fNum
			logSomething "Adding: $TSVariableName :  $sApp" -updateUI
			if($TSEnv){
				$tsenv.Value($TSVariableName) = $sApp
			}
			$count++
		}
		logSomething "Done" -updateUI
		[Environment]::Exit(0)
		$Runspace.Close()
		$Runspace.Dispose()
	}
	$PSinstance = [powershell]::Create().AddScript($Code)
	$PSinstance.Runspace = $Runspace
	$job = $PSinstance.BeginInvoke()
}

# do stuff on load:
$MainWindow.add_Loaded({
    #change app icon by replacing .\resources\icon.ico
    $MainWindow.Icon = "$PSScriptRoot\resources\icon.ico"
	Invoke-Initialize -syncHash $syncHash
})

# do stuff when clicking button
$btnNext.add_Click({
	if($btnNext.Content -eq "Next"){
		$btnNext.IsEnabled = $false
		$lstDevices.IsEnabled = $false
		$chkManual.IsEnabled = $false
		$txtComp.IsEnabled = $false
		$grdCheckBoxContainer.IsEnabled = $false
		if($chkManual.IsChecked){
			if($txtComp.Text -ne ""){
				Invoke-AppLookup -syncHash $syncHash
			}
			else{
				$tbStatus.Text = "Please enter a computer name"
				$btnNext.IsEnabled = $true
				$lstDevices.IsEnabled = $true
				$chkManual.IsEnabled = $true
				$txtComp.IsEnabled = $true
				$grdCheckBoxContainer.IsEnabled = $true
			}
		}
		else{
			Invoke-AppLookup -syncHash $syncHash
		}
	}
	else{
		# add to TS var and close
		$selectedApps = @()
		foreach ($checkBox in $CheckboxContainer.Children) {
			if ($checkBox.IsChecked) {
				$selectedApps += $checkBox.Content
			}
		}
		if($selectedApps.Count -gt 0){
			$btnNext.IsEnabled = $false
			$btnBack.IsEnabled = $false
			$btnAll.IsEnabled = $false
			$btnNone.IsEnabled = $false
			$lstDevices.IsEnabled = $false
			$chkManual.IsEnabled = $false
			$txtComp.IsEnabled = $false
			$grdCheckBoxContainer.IsEnabled = $false
			Invoke-BuildBaseVariable -syncHash $syncHash -selectedApps $selectedApps
		}
		else{
			logSomething "Please select at least 1 application." -updateUI
		}
			
	}
})

$btnBack.add_Click({
	$txtComp.IsEnabled = $true
	$btnNext.IsEnabled = $true
	$btnBack.IsEnabled = $false
	$btnAll.IsEnabled = $false
	$btnNone.IsEnabled = $false
	$CheckboxContainer.Children.Clear()
	$btnNext.Content = "Next"
	$tbStatus.Text = "Resetting..."
	# if we hid the dropdown because no devices, don't unhide it
	if($syncHash.NoDevices){

	}
	else{
		$lstDevices.IsEnabled = $true
		$chkManual.IsEnabled = $true
	}
})

$btnAll.add_Click({
    foreach ($checkBox in $CheckboxContainer.Children) {
		$checkBox.IsChecked = $true
    }
})

$btnNone.add_Click({
    foreach ($checkBox in $CheckboxContainer.Children) {
		$checkBox.IsChecked = $false
    }
})

$txtComp.Add_KeyUp({
	if($_.Key -eq 'Return'){
        if($txtComp.Text -ne ""){
			$txtComp.IsEnabled = $false
            $btnNext.IsEnabled = $false
			$chkManual.IsEnabled = $false
			$grdCheckBoxContainer.IsEnabled = $false
			Invoke-AppLookup -syncHash $syncHash
        }
		else{
			$tbStatus.Text = "Please enter a computer name"
		}
	}
})

# list change
$lstDevices.add_SelectionChanged({
	logSomething "Device selection change: $($lstDevices.SelectedItem.Name) :: $($lstDevices.SelectedItem.ResourceId)"
})

# region show/hide the textbox
$chkManual.add_Checked({
	$txtComp.Visibility = "Visible"
	$txtComp.IsEnabled = $true
	$lstDevices.Visibility = "Collapsed"
	$txtComp.Focus()
})

$chkManual.add_UnChecked({
	$txtComp.Visibility = "Collapsed"
	$lstDevices.Visibility = "Visible"
})
#endregion

# click cancel to close:
$btnCancel.add_Click({
	$result = [System.Windows.Forms.MessageBox]::Show(
        "Are you sure you want to cancel?",
        "Confirmation",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
		$xamGUI.Close() | out-null
    }
})

#Launch the window
$xamGUI.ShowDialog() | out-null