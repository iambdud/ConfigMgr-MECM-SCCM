Function Sample-RunSpaceFunc{
	param($syncHash)
	#create the runspace:
	$Runspace = [runspacefactory]::CreateRunspace()
	$Runspace.ApartmentState = "STA"
	$Runspace.ThreadOptions = "ReuseThread"
	$Runspace.Open()
	# variables to share with the runspace:
	$Runspace.SessionStateProxy.SetVariable("syncHash",$syncHash)
	# for example, text from a textbox:
	$Runspace.SessionStateProxy.SetVariable("txtInput",$txtInput.Text)
	
	# code to be executed in the runspace:
	$code = {
		#code to update UI elements:
		$syncHash.Window.Dispatcher.invoke([action]{
			# update the txtOutput.Text on the UI:
			$syncHash.txtOutput.Text = $txtInput + " some new text"
		})
	}
	#execute the code:
	$PSinstance = [powershell]::Create().AddScript($code)
	$PSinstance.Runspace = $Runspace
	$job = $PSinstance.BeginInvoke()
}