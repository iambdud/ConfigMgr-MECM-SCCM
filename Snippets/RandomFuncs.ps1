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

function splitTrim{
	[CmdletBinding()]
	Param
    (
		[Parameter(ValueFromPipeline)] $input
	)
	return ($input -split '\n').trim()
}