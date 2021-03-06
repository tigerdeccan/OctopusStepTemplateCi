<#
Copyright 2016 ASOS.com Limited

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
#>

<#
.NAME
    Invoke-PesterForTeamCity

.SYNOPSIS
    Invokes Pester's tests, handles the results file and teamcity integration to link the results file into team city and returns the passed & failed tests count  
#>
function Invoke-PesterForTeamCity
{

    param
    (
        $TestName,
        $Script,
        $TestResultsFile,
        [switch]$SuppressPesterOutput
    )

    $ErrorActionPreference = "Stop";
    $ProgressPreference = "SilentlyContinue";
    Set-StrictMode -Version "Latest";

    $pesterModule = Get-Module "pester";
    if( $null -eq $pesterModule )
    {
        Import-Module -Name "pester" -ErrorAction "Stop";
        $pesterModule = Get-Module "pester";
    }

    $parameters = @{
        "Script"       = $Script
        "OutputFile"   = $TestResultsFile
        "OutputFormat" = "NUnitXml"
        "PassThru"     = $true;
    };

    if( $SuppressPesterOutput )
    {
        if( $pesterModule.Version -gt "3.4.0" )
        {
            $parameters.Add("Show", "None");
        }
        else
        {
            $parameters.Add("Quiet", $true);
        }
    }

    $testResults = Invoke-Pester @parameters;

    # see https://github.com/pester/Pester/issues/1060
    $testResults = $testResults | select-object -Last 1;

    # update the test-suite name so that teamcity displays it better. otherwise, all test suites are called "Pester"
    Update-XPathValue -Path $TestResultsFile -XPath '//test-results/test-suite/@name' -Value $TestName

    # tell teamcity to import the test results. Cant use the xml report processor feature of TeamCity, due to aysnc issues around updating the test suite name
    Write-TeamCityImportDataMessage -Type  "nunit" `
                                    -Path $TestResultsFile `
                                    -VerboseMessage;

    $result = New-Object -TypeName PSObject -Property @{
        "Passed" = $testResults.PassedCount
        "Failed" = $testResults.FailedCount
    };

    return $result;

}