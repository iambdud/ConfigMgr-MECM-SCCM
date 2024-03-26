function splitTrim{
	[CmdletBinding()]
	Param
    (
		[Parameter(ValueFromPipeline)] $input
	)
	return ($input -split '\n').trim()
}