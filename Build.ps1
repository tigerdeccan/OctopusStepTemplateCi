#requires -version 4

# ------------------------------------------------
# Octopus Deploy Step Template Tester and Uploader
# ------------------------------------------------
#
# Ver    Who                             When        What
# 1.00   Matt Richardson (DevOpsGuys)    14-08-15    Initial Version
# 1.01   Leslie Lintott                  03-09-15    Add support for script modules
# 1.02   Matt Richardson (DevOpsGuys)    18-09-15    Add teamcity log indenting
# 1.03   Matt Richardson (DevOpsGuys)    18-09-15    Fix bug where script template errors were not failing the build
# 1.04   Leslie Lintott                  18-09-15    Added check to see if its changed before uploading script module 
# 1.05   Matt Richardson (DevOpsGuys)    18-09-15    Enabled basic parsing on webrequests - dont need fancier parsing (which was failing on build server)
# 1.06   Matt Richardson (DevOpsGuys)    07-10-15    Adding tests for required fields on parameters
# 1.07   Matt Richardson (DevOpsGuys)    07-10-15    Correcting location of teamcity log blocks (was showing error after block closed)
# 1.08   Matt Richardson (DevOpsGuys)    28-10-15    Fixing regex that searches for variables to match the following one that extracts the variable name
# 1.09   Matt Richardson (DevOpsGuys)    24-11-15    Add validation to ensure a script module description is supplied
# 1.10   Matt Richardson (DevOpsGuys)    24-11-15    Set the script module description based on metadata in script module source file
# 1.11   Matt Richardson (DevOpsGuys)    30-11-15    Adding new test to ensure we dont overwrite passed in parameters
# 1.12   Matt Richardson (DevOpsGuys)    01-12-15    Write warning messages as teamcity build warnings
# 1.13   Matt Richardson (DevOpsGuys)    01-12-15    Output test results files into different folder
# 1.14   Matt Richardson (DevOpsGuys)    09-12-15    Show how many scripts uploaded in build status text
# 1.15   Matt Richardson (DevOpsGuys)    09-12-15    Refactoring script to clean it up a bit
# 1.16   Matt Richardson (DevOpsGuys)    14-01-16    Fix issue when there are more than 30 script modules - api was paging and the code wasn't handling it
# 1.17   Matt Richardson (DevOpsGuys)    02-02-16    Enable params to be passed into the script, rather than insisting on env vars
# 1.18   Matt Richardson (DevOpsGuys)    02-02-16    Allow suppression of pester output (disabled by default) so it can be turned off when using the teamcity report processing
# 1.19   Matt Richardson (DevOpsGuys)    02-02-16    Throw error on non-ascii characters
# 1.20   Matt Richardson (DevOpsGuys)    03-02-16    Update nunit results xml to specify test file name rather than all of them saying 'Pester'
# 1.21   Matt Richardson (DevOpsGuys)    04-02-16    Cache the existing step templates and script modules
# 1.22   Matt Richardson (DevOpsGuys)    10-02-16    Output the number of failed tests at the end of the runs to make it easier for local runs
# 1.23   Matt Richardson (DevOpsGuys)    10-02-16    Dont recurse when searching for variables - the only ones we care about are at the root level, not in functions
# 1.24   Matt Richardson (DevOpsGuys)    10-02-16    Refactor to remove duplication. Add logging of number of successful tests at the end of the run
# 
# ------------------------------------------------
# TODO
# * add some unit tests
# * make it a module?
# ------------------------------------------------

param (
    [string] $stepTemplates = "*.steptemplate.ps1",
    [string] $scriptModules = "*.scriptmodule.ps1",
    [switch] $uploadIfSuccessful = $false,
    [string] $octopusUri = $ENV:OctopusURI,
    [string] $octopusApiKey = $ENV:OctopusApikey,
    [switch] $suppressPesterOutput = $false
)

$script:allStepTemplates = $null
$script:allScriptModules = $null

#credit to Dave Wyatt (https://github.com/dlwyatt) for the Get-VariableFromScriptFile piece of magic
function Get-VariableFromScriptFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateScript({
            if (-not (Test-Path -LiteralPath $_ -PathType Leaf))
            {
                throw "Path '$_' does not exist."
            }
            
            $item = Get-Item -LiteralPath $_
            if ($item -isnot [System.IO.FileInfo])
            {
                throw "Path '$_' does not refer to a file."
            }

            return $true
        })]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $VariableName,
        
        [bool] $ResolveVariable = $true
    )

    $tokens = $null
    $parseErrors = $null

    $_path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($_path, [ref] $tokens, [ref] $parseErrors)
    if ($parseErrors) {
        throw "File '$Path' contained parse errors: `r`n$($parseErrors | Out-String)"
    }

    $filter = {
        $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $args[0].Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $args[0].Left.VariablePath.UserPath -eq $VariableName
    }

    $SearchNestedScriptBlocks = $false
    $assignment = $ast.FindAll($filter, $SearchNestedScriptBlocks)

    if ($assignment) {
        $scriptBlock = [scriptblock]::Create($assignment.Right.Extent.Text)
        if ($ResolveVariable) {
            return & $scriptBlock
        }
        return $scriptBlock
    }
    else {
        throw "File '$Path' does not contain Step Template metadata variable '$VariableName'"
    }
}

function Remove-VariableFromScript {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $ScriptBody,

        [Parameter(Mandatory)]
        [string] $VariableName
    )

    $tokens = $null
    $parseErrors = $null

    $tempFile = [System.IO.Path]::GetTempFileName()
    Set-Content $tempFile $ScriptBody

    $_path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($tempFile)

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($_path, [ref] $tokens, [ref] $parseErrors)
    if ($parseErrors)
    {
        throw "File '$Path' contained parse errors: `r`n$($parseErrors | Out-String)"
    }

    $filter = {
        $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $args[0].Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $args[0].Left.VariablePath.UserPath -eq $VariableName
    }

    $assignment = $ast.Find($filter, $true)

    if ($assignment)
    {
        return $ScriptBody.Replace($assignment.Extent.Text, "")
    }
}

function Convert-PSObjectToHashTable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSObject] $PsObject
    )
    $result = @{}
    if (($PsObject.psobject.properties | select-object name) -ne $null) {
        foreach ($propL1 in $PsObject.psobject.properties.name)
        {
            $result[$propL1] = $PsObject.$propL1
        }
    }
    return $result
}

function Download-StepTemplate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $octopusURI,
        [Parameter(Mandatory)]
        [string] $apikey,
        [Parameter(Mandatory)]
        [string] $templateName
    )

    if ($script:allStepTemplates -eq $null) {
        $response = Invoke-WebRequest -Uri "$octopusURI/api/actiontemplates/all" -Headers @{"X-Octopus-ApiKey"=$apikey} -UseBasicParsing
        $script:allStepTemplates = ($response.Content | ConvertFrom-Json)
    }
    $oldTemplate = $null

    foreach($template in $script:allStepTemplates)
    {
        if ($templateName -eq $template.Name) {
            $oldTemplate = $template
        
            $oldtemplate.Properties = Convert-PSObjectToHashTable $template.Properties

            $parameters = $template.Parameters
            $oldtemplate.Parameters = @()
            foreach ($param in $parameters)
            {
                $newParam = Convert-PSObjectToHashTable $param
                $newParam.DisplaySettings = Convert-PSObjectToHashTable $newParam.DisplaySettings
                $oldtemplate.Parameters += $newParam
            }
        }
    }
    return $oldTemplate
}

function Get-ScriptBody {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $inputFile
    )
    $scriptBody = [IO.File]::ReadAllText($inputFile)
    #remove 'metadata' parameters
    if ($inputFile -match ".*\.scriptmodule\.ps1")
    {
        $scriptBody = Remove-VariableFromScript -ScriptBody $scriptBody -VariableName ScriptModuleName
        $scriptBody = Remove-VariableFromScript -ScriptBody $scriptBody -VariableName ScriptModuleDescription
    }
    elseif ($inputFile -match ".*\.steptemplate\.ps1")
    {
        $scriptBody = Remove-VariableFromScript -ScriptBody $scriptBody -VariableName StepTemplateName
        $scriptBody = Remove-VariableFromScript -ScriptBody $scriptBody -VariableName StepTemplateDescription
        $scriptBody = Remove-VariableFromScript -ScriptBody $scriptBody -VariableName StepTemplateParameters
    }
    $scriptBody = $scriptBody.TrimStart("`r", "`n")
    return $scriptBody
}

function Convert-ToJson {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $newTemplate
    )
    $json = ($newTemplate | ConvertTo-Json -depth 3)
    $json = $json.Replace("\u0027", "'") #fix escaped single quotes
    $json = $json -replace '\{\s*\}', '{}' #fix odd empty hashtable formatting (or easier comparison in beyond compare)
    return $json
}

function Clone-Template {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $oldTemplate,
        [Parameter(Mandatory)]
        [string] $inputFile
    )

    #take a copy of the template
    $newTemplate = $oldTemplate.PsObject.Copy()
    $newTemplate.Properties = $oldTemplate.Properties.PsObject.Copy()

    $newTemplate.Version = $oldTemplate.Version + 1

    $newTemplate.Properties["Octopus.Action.Script.ScriptBody"] = Get-ScriptBody -inputFile $inputFile
    $newTemplate.Description = Get-VariableFromScriptFile -Path $inputFile -VariableName StepTemplateDescription;

    [Array]$parameters = Get-VariableFromScriptFile -Path $InputFile -VariableName StepTemplateParameters

    $newTemplate.Parameters = $parameters;
    $newTemplate.PsObject.Properties.Remove('Links')
    return $newTemplate
}

function Create-Template {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $InputFile
    )

    
    [Array]$parameters = Get-VariableFromScriptFile -Path $InputFile -VariableName StepTemplateParameters

    $properties = @{
        'Name' = Get-VariableFromScriptFile -Path $InputFile -VariableName StepTemplateName;
        'Description' = Get-VariableFromScriptFile -Path $InputFile -VariableName StepTemplateDescription;
        'ActionType' = 'Octopus.Script';
        'Properties' = @{
            'Octopus.Action.Script.ScriptBody' = Get-ScriptBody -inputFile $InputFile;
            'Octopus.Action.Script.Syntax' = 'PowerShell'
            };
        'Parameters' = $parameters;
        'SensitiveProperties' = @{};
        '$Meta' = @{'Type' = 'ActionTemplate'}
    }

    $newTemplate = New-Object -TypeName PSObject -Property $properties

    return $newTemplate
}

#Compare-Hashtable borrowed from http://stackoverflow.com/a/7060358
function Compare-Hashtable {
  param (
    [Hashtable]$ReferenceObject,
    [Hashtable]$DifferenceObject,
    [switch]$IncludeEqual
  )
  # Creates a result object.
  function result( [string]$side ) {
    New-Object PSObject -Property @{
      'InputPath'= "$path$key";
      'SideIndicator' = $side;
      'ReferenceValue' = $refValue;
      'DifferenceValue' = $difValue;
    }
  }

  # Recursively compares two hashtables.
  function core-compare( [string]$path, [Hashtable]$ref, [Hashtable]$dif ) {
    # Hold on to keys from the other object that are not in the reference.
    $nonrefKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $dif.Keys | foreach { [void]$nonrefKeys.Add( $_ ) }

    # Test each key in the reference with that in the other object.
    foreach( $key in $ref.Keys ) {
      [void]$nonrefKeys.Remove( $key )
      $refValue = $ref.$key
      $difValue = $dif.$key

      if( -not $dif.ContainsKey( $key ) ) {
        result '<='
      }
      elseif( $refValue -is [hashtable] -and $difValue -is [hashtable] ) {
        core-compare "$path$key." $refValue $difValue
      }
      elseif( $refValue -ne $difValue ) {
        result '<>'
      }
      elseif( $IncludeEqual ) {
        result '=='
      }
    }

    # Show all keys in the other object not in the reference.
    $refValue = $null
    foreach( $key in $nonrefKeys ) {
      $difValue = $dif.$key
      result '=>'
    }
  }

  core-compare '' $ReferenceObject $DifferenceObject
}

function Are-TemplatesDifferent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $oldtemplate,
        [Parameter(Mandatory)]
        $newTemplate
    )
    #id - wont change
    #name - wont change
    #actiontype - wont change
    #version - will be incremented, shouldn't be checked

    #description
    if ($oldtemplate.Description -ne $newTemplate.Description) { 
        return $true 
    }
    #Properties['Octopus.Action.Script.Syntax']
    if ($oldtemplate.Properties['Octopus.Action.Script.Syntax'] -ne $newTemplate.Properties['Octopus.Action.Script.Syntax']) { 
        return $true
    }
    #Properties['Octopus.Action.Script.ScriptBody']
    if ($oldtemplate.Properties['Octopus.Action.Script.ScriptBody'] -ne $newTemplate.Properties['Octopus.Action.Script.ScriptBody']) { 
        return $true 
    }
    #Parameters - check we have the same number of them, with the same names
    if (($oldTemplate.Parameters -eq $null) -or ($newTemplate.Parameters -eq $null)) {
        if ($oldtemplate.Parameters -ne $newTemplate.Parameters) {
            return $false
        }
    } else {
        if (($oldTemplate.Parameters.Name -join ',') -ne ($newTemplate.Parameters.Name -join ',')) {
            return $true
        }
    }

    #loop through the params, and compare each hastable (recursively)
    foreach($oldParam in $oldtemplate.Parameters)
    {
        $newParam =  ($newTemplate.Parameters | where { $_.Name -eq $oldParam.Name })
        $result = Compare-Hashtable -ReferenceObject $oldParam -DifferenceObject $newParam
        if ($result) { 
            return $true 
        }
    }

    return $false
}

function Are-ScriptModulesDifferent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $oldmodule,
        [Parameter(Mandatory)]
        $newmodule
    )

    if ($oldmodule -ne $newmodule)
    {
        return $true
    }

    return $false
}

function Update-XPathValue() {
    [cmdletbinding()]
    param (
        [string] $fileName = $(throw "fileName is a required parameter"),
        [string] $xpath = $(throw "xpath is a required parameter"),
        [string] $value = $(throw "value is a required parameter")
    )

    Write-Verbose "Updating '$fileName' using xpath '$xpath' to '$value'"

    if (!(Test-Path $fileName)) { throw "File '$filename' not found" }

    $doc = [xml](Get-Content $fileName)
    $nodes = $doc.SelectNodes($xpath)
    
    if ($nodes.Count -eq 0) {
        throw "Element or attribute not found using xpath '$xpath'"
    }
    foreach ($node in $nodes) {
        if ($node -ne $null) {
            if ($node.NodeType -eq "Element") {
                    $node.InnerXml = $value
                }
            else {
                $node.Value = $value
            }
        }
    }
    $doc.save($fileName)
}

function Run-Tests {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $inputFile,
        [ref] $failedTestCount,
        [ref] $passedTestCount,
        $script,
        $suffix = ""
    )

    $success = $true

    $testResultsFile = (Split-Path $inputFile) + "\..\.BuildOutput\" +  ((Split-Path $inputFile -Leaf).Replace(".ps1", "$suffix.TestResults.xml"))
    $testResult = Invoke-Pester -Script $script -PassThru -OutputFile $testResultsFile -OutputFormat NUnitXml -Quiet:$suppressPesterOutput
    
    #update the test-suit name so that teamcity displays it better. otherwise, all test suites are called "Pester"
    Update-XPathValue -fileName $testResultsFile -xpath '//test-results/test-suite/@name' -value (Split-Path $inputFile -Leaf)

    #tell teamcity to import the test results. Cant use the xml report processor feature of TeamCity, due to aysnc issues around updating the test suite name
    write-host "##teamcity[importData type='nunit' path='$testResultsFile' verbose='true']"

    if (-not ($testResult.PSObject.Properties['FailedCount'])) {
        write-error "Test file '$testFile' is not a valid Pester test file."
        return $false
    }

    if ($testResult.FailedCount -gt 0) {
        $success = $false
    }
    $failedTestCount.Value = $failedTestCount.Value + $testResult.FailedCount
    $passedTestCount.Value = $passedTestCount.Value + $testResult.PassedCount
    
    return $success
}

function Run-AllTests {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $inputFile,
        [ref] $failedTestCount,
        [ref] $passedTestCount
    )
    $testFile = $inputFile.Replace(".ps1", ".Tests.ps1")

    if (-not (Test-Path -LiteralPath $testFile -PathType Leaf)) {
        write-error "Test file '$testFile' does not exist."
        return $false
    }
            
    $item = Get-Item -LiteralPath $testFile
    if ($item -isnot [System.IO.FileInfo]) {
        write-error "Test file '$testFile' is not a file."
        return $false
    }

    $success = Run-Tests $inputFile -failedTestCount $failedTestCount -passedTestCount $passedTestCount -script $testFile
    $result = Run-Tests $inputFile -failedTestCount $failedTestCount -passedTestCount $passedTestCount  -suffix ".generic" -script @{ Path = "$PSScriptRoot\generic-tests.ps1"; Parameters = @{ Sut = $inputFile } }
    $success = $success -and $result

    if ($inputFile -match ".*\.scriptmodule\.ps1") {
        $result = Run-Tests $inputFile -failedTestCount $failedTestCount -passedTestCount $passedTestCount -suffix ".script-module-generic" -script @{ Path = "$PSScriptRoot\script-module-generic-tests.ps1"; Parameters = @{ Sut = $inputFile } }
    }
    else  {
        $result = Run-Tests $inputFile -failedTestCount $failedTestCount -passedTestCount $passedTestCount -suffix ".step-template-generic.TestResults" -script @{ Path = "$PSScriptRoot\step-template-generic-tests.ps1"; Parameters = @{ Sut = $inputFile } }
    }
    $success = $success -and $result
    return $success
}

function Upload-ScriptModuleIfChanged {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $inputFile,
        [Parameter(Mandatory)]
        [string] $octopusURI,
        [Parameter(Mandatory)]
        [string] $apikey
    )

    $header = @{ "X-Octopus-ApiKey" = $apikey }

    #Module Name and Powershell Script
    $ModuleName = Get-VariableFromScriptFile -Path $InputFile -VariableName ScriptModuleName
    $ModuleDescription = Get-VariableFromScriptFile -Path $InputFile -VariableName ScriptModuleDescription
    $ModuleScript = Get-ScriptBody -inputFile $inputFile

    #Getting if module already exists, and if it doesnt, create it
    if ($script:allScriptModules -eq $null) {
        $script:allScriptModules = Invoke-WebRequest "$octopusURI/api/LibraryVariableSets/all" -Method GET -Headers $header -UseBasicParsing | select -ExpandProperty content | ConvertFrom-Json
    }
    $ScriptModule = $script:allScriptModules | ?{$_.name -eq $ModuleName}

    If($ScriptModule -eq $null) {
        write-host "VariableSet for script module '$ModuleName' does not exist, creating"
        $SMBody = [PSCustomObject]@{
            ContentType = "ScriptModule"
            Name = $ModuleName
            Description = $ModuleDescription
        } | ConvertTo-Json

        $Scriptmodule = Invoke-WebRequest $octopusURI/api/LibraryVariableSets -Method POST -Body $SMBody -Headers $header -UseBasicParsing | select -ExpandProperty content | ConvertFrom-Json    
    }
    elseif ($ScriptModule.Description -ne $ModuleDescription) {
        write-host "Script module '$ModuleName' has different metadata. Updating."
        $ScriptModule.Description = $ModuleDescription
        $response = Invoke-WebRequest $octopusURI/$($Scriptmodule.Links.Self) -Method PUT -Body ($ScriptModule | ConvertTo-Json -Depth 3) -Headers $header -UseBasicParsing
    }

    #Getting the library variable set asociated with the module
    $Variables = Invoke-WebRequest $octopusURI/$($Scriptmodule.Links.Variables) -Headers $header -UseBasicParsing | select -ExpandProperty content | ConvertFrom-Json

    #Creating/updating the variable that holds the Powershell script
    If($Variables.Variables.Count -eq 0)
    {
        write-host "Script module '$ModuleName' does not exist, creating"
        $Variable = [PSCustomObject]@{   
            Name = "Octopus.Script.Module[$Modulename]"    
            Value = $ModuleScript #Powershell script goes here
        }

        $Variables.Variables += $Variable

        $VSBody = $Variables | ConvertTo-Json -Depth 3

        #Updating the library variable set
        $response = Invoke-WebRequest $octopusURI/$($Scriptmodule.Links.Variables) -Headers $header -Body $VSBody -Method PUT -UseBasicParsing | select -ExpandProperty content | ConvertFrom-Json
        return $true
    }
    else {
        if (Are-ScriptModulesDifferent $Variables.Variables[0].value $ModuleScript)
        {
            write-host "Script module $ModuleName has changed, updating"

            $Variables.Variables[0].value = $ModuleScript #Updating powershell script
            $VSBody = $Variables | ConvertTo-Json -Depth 3 

            #Updating the library variable set
            $response = Invoke-WebRequest $octopusURI/$($Scriptmodule.Links.Variables) -Headers $header -Body $VSBody -Method PUT -UseBasicParsing | select -ExpandProperty content | ConvertFrom-Json
            return $true
        }  
    }
    return $false
}

function Upload-StepTemplateIfChanged {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $inputFile,
        [Parameter(Mandatory)]
        [string] $octopusURI,
        [Parameter(Mandatory)]
        [string] $apikey
    )
    $templateName = Get-VariableFromScriptFile -Path $InputFile -VariableName StepTemplateName
    $oldTemplate = Download-StepTemplate -octopusURI $octopusURI -apikey $apikey -templateName $templateName

    try
    {
        if ($oldTemplate -ne $null) {
            Write-Verbose "Template '$($oldtemplate.Id)' ('$templateName') already exists on Octopus Deploy server (at version $($oldTemplate.Version))"
            $newTemplate = Clone-Template $oldTemplate $inputFile
            $json = Convert-ToJson -newTemplate $newTemplate

            if (Are-TemplatesDifferent $oldtemplate $newTemplate) {
                write-Verbose "Template has changed"
                write-host "Uploading template '$templateName'"
                $response = Invoke-WebRequest -Uri "$octopusURI/api/actiontemplates/$($newTemplate.Id)" -method PUT -body $json -Headers @{"X-Octopus-ApiKey"=$apikey} -UseBasicParsing
                $updatedTemplate = ($response.content | ConvertFrom-Json)
                write-Verbose "Template '$($oldtemplate.Id)' updated to version $($updatedTemplate.version)"
                return $true
            } 
            else {
                write-Verbose "Template '$templateName' has not changed - skipping upload"
            }
        }
        else {
            write-Verbose "Template '$templateName' was not found on Octopus Deploy server"

            $newTemplate = Create-Template -InputFile $inputFile
            $json = Convert-ToJson -newTemplate $newTemplate

            write-host "Uploading new template '$templateName'"
            $response = Invoke-WebRequest -Uri "$octopusURI/api/actiontemplates" -method POST -body $json -Headers @{"X-Octopus-ApiKey"=$apikey} -UseBasicParsing    
        
            $updatedTemplate = ($response.content | ConvertFrom-Json)
            write-Verbose "Template '$templateName' uploaded with id '$($updatedTemplate.id)'"
            return $true
        }
    }
    catch [Microsoft.PowerShell.Commands.WriteErrorException]
    {
        Write-Output $_
        exit 1
    }
    return $false
}

function Reset-BuildOutputDirectory {
    $err=@()
    if (Test-Path "$PSScriptRoot\.BuildOutput") {
        Remove-Item "$PSScriptRoot\.BuildOutput\*" -Force -Recurse -ErrorAction SilentlyContinue -ErrorVariable err | Out-null
    } else {
        New-Item "$PSScriptRoot\.BuildOutput" -type directory -ErrorAction SilentlyContinue -ErrorVariable err | Out-null
    }
    if ($err.Count -gt 0) {
        throw "Unable to clean '$PSScriptRoot\.BuildOutput' directory"
    }
}

function Process-Scripts {
    Param(
        [string]$directory,
        [string]$filter,
        [string]$type,
        [scriptblock]$uploadFunction,
        [ref]$uploadedCount,
        [ref]$failedTestCount,
        [ref]$passedTestCount
    )

    foreach ($inputFile in (Get-ChildItem $directory -filter $filter))
    {
        #Write-Host "##teamcity[blockOpened name='$type : $inputFile']"

        $result = Run-AllTests $inputFile.FullName -failedTestCount $failedTestCount -passedTestCount $passedTestCount

        if ($result -and $uploadIfSuccessful) {
            if (Invoke-Command -ScriptBlock $uploadFunction -ArgumentList $inputFile.FullName, $octopusUri, $octopusApikey) {
                $uploadedCount.Value = $uploadedCount.Value + 1
            }
        }
        #Write-Host "##teamcity[blockClosed name='$type : $inputFile']"
    }
}

function Main {
    try {
        Reset-BuildOutputDirectory

        $uploadedCount = 0
        $failedTestCount = 0
        $passedTestCount = 0

        Process-Scripts -directory "$PSScriptRoot\StepTemplates" `
                        -filter $stepTemplates `
                        -type "Step Template" `
                        -uploadFunction  (Get-ChildItem Function:\Upload-StepTemplateIfChanged).ScriptBlock `
                        -uploadedCount ([ref]$uploadedCount) `
                        -failedTestCount ([ref]$failedTestCount) `
                        -passedTestCount ([ref]$passedTestCount)

        Process-Scripts -directory "$PSScriptRoot\ScriptModules" `
                        -filter $scriptModules `
                        -type "Script Module" `
                        -uploadFunction  (Get-ChildItem Function:\Upload-ScriptModuleIfChanged).ScriptBlock `
                        -uploadedCount ([ref]$uploadedCount) `
                        -failedTestCount ([ref]$failedTestCount) `
                        -passedTestCount ([ref]$passedTestCount)

        Write-Host "##teamcity[buildStatus text='{build.status.text}. Scripts uploaded: $uploadedCount']"

        Write-Host "$passedTestCount tests passed. $failedTestCount tests failed"
        exit 0
    }
    catch [System.Exception] {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        exit 1
    }
}

############################

Set-StrictMode -Version Latest
Main