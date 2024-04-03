
# Welcome to my SCCM/MECM scratch space.
Here you will find code samples, snippets, etc of things I've used/compiled over my years of managing SCCM (and Windows in general).

## Using Task Sequences to dynamically install applications
SCCM OSD Task Sequences contain a powerful feature that lets you install applications using a base variable. Below are 2 examples of how I've used this feature to install apps dynamically using task sequences.
1. [Application Profiles](#dynamically-install-profile-applications)
2. [Application Cloning](#clone-applications-installed-on-another-pc)

## Dynamically install "Profile Applications"
This method uses a script to query SCCM and get a list of applications that are deployed to a "Profile" collection. It adds each application to a TS variable and installs the applications one by one. You can use this during initial imaging of a device or you can use it as a standalone Software Center installation.

#### Script configuration
- The script should not require any modification. It will retrieve everything it needs using Task Sequence variables (below)
#### Collection setup
- Create a collection (Device or User) and deploy applications to it
- Typically, this collection will not contain any members
- Typically, the applications are deployed to the collection as "Available" to help minimize the risk of unintentionally installing applications if members are added
#### Task Sequence configuration
- **Set Variables** - the main script will retrieve these variables during execution. Alternatively, you can get credentials from some other credential store (vault, etc)
	 - QueryUser - the service account that will be used to connect the SMS provider (as always, give this account the least privileges required: WinRM rights, SCCM rights)
	 - QueryPassword - the password for the service account (set as a secret value)
	 - SiteServer - the site server running the SMS provider
	 - SiteCode - the Site Code
	 - CollectionName - The name of the collection for the "profile"
	 - (Optional) SkipText - Text that can be used to "skip" an application from being installed during the TS
		 - Simply add something like "SKIPPED" to the description of the application in SCCM
 - **Get Application List**
	 - Use a "Run PowerShell Script" step
	 - Copy/Paste the script into the editor
	 - Depending on your settings, change the execution policy as needed
 - **Install Applications**
	 - Add a condition: Task Sequence Variable "BaseVar" exists
	 - Install applications according to the BaseVar dynamic variable list
#### Script execution flow
- Gather the variables from the TS variables
- Query SCCM to get the list of applications deployed to the specified collection
- For each app, check for "installability"
	- Not a "skipped app"
	- Configured to be allowed to install during a task sequence
	- Not expired
- If "installable" add the application to a variable. 
	- BaseVar01 = \<application name 1\>, BaseVar02 = \<application name 2\>, etc.
#### Task Sequence flow
- Set Variables
- Get Application List
	- Set TS variables for each application
- Install Applications
	- If applications were found, install the list of applications

### User Experience:
#### Software Center:
<img width="507" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/e518f17b-7389-4720-a39c-46daf502f042">

#### Set Variables:
<img width="511" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/0af428bd-cb91-414f-8c10-c0b3c0909fe9">

#### Get Application List:
<img width="511" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/233f1e6b-1c7a-4007-9e22-c458935196aa">

#### Install Applications:
<img width="511" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/9b7333d9-a47a-4da9-ad96-a895c8f57518">

	
## "Clone" applications installed on another PC
This method uses a UI to choose applications to install. The UI allows the user to select the PC they want to use as the source machine as well as select the applications they wish to install on the new machine.

#### Script configuration
- The script should not require any modification. It will retrieve everything it needs using Task Sequence variables (below)
#### Script package
- In order to display the CloneApps UI to the user, this script requires ServiceUI from the MDT toolkit.
- The package will consist of these files:
```bash
├── assemblies
	│ ModernWpf.Controls.dll
	│ ModernWpf.dll
	│ System.ValueTuple.dll
├── resources
	│ icon.ico
├── xaml
	│ MainForm.xaml
│ Run-CloneApps.ps1
│ ServiceUI.exe
```
#### Task Sequence configuration
- **Set Variables** - the main script will retrieve these variables during execution. Alternatively, you can get credentials from some other credential store (vault, etc)
	 - QueryUser - the service account that will be used to connect the SMS provider (as always, give this account the least privileges required: WinRM rights, SCCM rights)
	 - QueryPassword - the password for the service account (set as a secret value)
	 - SiteServer - the site server running the SMS provider
	 - SiteCode - the Site Code
	 - CollectionName - The name of the collection for the "profile"
	 - (Optional) SkipText - Text that can be used to "skip" an application from being installed during the TS
		 - Simply add something like "SKIPPED" to the description of the application in SCCM
		 
 - **Get Application List**
	 - Use a "Run Command Line" step
	 - Command line:
		 ```bash
		 ServiceUI.exe -process:explorer.exe %SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File Run-CloneApps.ps1
		 ```
	 - Choose the package that contains the script and other files
	 
 - **Install Applications**
	 - Add a condition: Task Sequence Variable "BaseVar" exists
	 - Install applications according to the BaseVar dynamic variable list
	 
#### Script execution flow
- Gather the variables from the TS variables
- Present the UI to the user
- Lookup installed apps for the provided PC
- User selects 1 or more applications
- For each selected app, check for "installability"
	- Not a "skipped app"
	- Configured to be allowed to install during a task sequence
	- Not expired
- If "installable" add the application to a variable. 
	- BaseVar01 = \<application name 1\>, BaseVar02 = \<application name 2\>, etc.
#### Task Sequence flow
- Set Variables
- Run Clone Apps UI
	- Set TS variables for each selected application
- Install Applications
	- If applications were selected, install the list of applications
 
### User Experience:
#### Software Center:
<img width="517" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/3ff3a2d2-86ed-4b54-bdf2-fa95d24e481c">

#### Set Variables:
<img width="512" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/a99f8f74-635a-4dbe-b848-d8e51abdc169">

#### Run CloneApps:
<img width="512" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/c9e4d235-0be5-4f62-bb11-fc75c73012d3">

#### Clone Apps UI:
<img width="359" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/fcb74724-95fd-4316-954d-0cb6fdb0d684">
<img width="359" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/1fc2c0ea-81cb-47bf-a75b-8d2700685350">

#### Install Applications:
<img width="512" alt="image" src="https://github.com/iambdud/ConfigMgr-MECM-SCCM/assets/9096898/87440f25-0e68-412a-b59b-8fdf0874b23b">

