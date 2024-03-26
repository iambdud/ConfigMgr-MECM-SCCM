
#region load xaml
#Add WPF and Windows Forms assemblies
try{
	Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase,system.windows.forms
}
catch{
	Throw "Failed to load Windows Presentation Framework assemblies."
}
#Required to load the XAML form and create the PowerShell Variables
$XamlPath = '.\xaml\MainForm.xaml'
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

# function to add to list:
function AddToList ($text){
    $lstResults.Items.Add($text)
    $tbStatus.Text = "$($text) added to the List"
}

# do stuff on load:
$MainWindow.add_Loaded({
    #change app icon by replacing .\resources\icon.ico
    $MainWindow.Icon = "$PSScriptRoot\resources\icon.ico"
    $txtInput.Focus()
})

# do stuff when clicking button
$btnGo.add_Click({
    if($txtInput.Text -ne ""){
        AddToList($txtInput.Text)
        $txtInput.Text = ""
        $txtInput.Focus()
    }
})

$txtInput.Add_KeyUp({
	if($_.Key -eq 'Return'){
        if($txtInput.Text -ne ""){
		    AddToList($txtInput.Text)
            $txtInput.Text = ""
            $txtInput.Focus()
        }
	}
})

# click cancel to close:
$btnCancel.add_Click({
    $xamGUI.Close() | out-null
})

#Launch the window
$xamGUI.ShowDialog() | out-null