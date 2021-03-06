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
    Export-StepTemplate.Tests

.SYNOPSIS
    Pester tests for Export-StepTemplate

#>

$ErrorActionPreference = "Stop";
Set-StrictMode -Version "Latest";

Describe "Export-StepTemplate" {

    BeforeEach {
        if( Test-Path "TestDrive:\test.ps1" )
        {
            Remove-Item "TestDrive:\test.ps1" -Force;
        }
    }

    Mock -CommandName "Read-StepTemplate" `
         -ModuleName  "OctopusStepTemplateCi" `
         -MockWith    { return "steptemplate"; };

    Mock -CommandName "ConvertTo-OctopusJson" `
         -ModuleName  "OctopusStepTemplateCi" `
         -MockWith    { return "steptemplate"; };

    Set-Content "TestDrive:\steptemplate.ps1" "steptemplate";

    It "Should convert the step template to json" {
        Export-StepTemplate -Path "TestDrive:\steptemplate.ps1" -ExportPath "TestDrive:\test.ps1" -Force;
        Assert-MockCalled -CommandName "ConvertTo-OctopusJson" -ModuleName "OctopusStepTemplateCi";
    }

    It "Should return a message to the user" {
        $result = Export-StepTemplate -Path "TestDrive:\steptemplate.ps1" -ExportPath "TestDrive:\test.ps1" -Force;
        $result | Should BeOfType [string];
    }

    Context "File" {

        It "Should export the steptemplate to a file" {
            Export-StepTemplate -Path "TestDrive:\steptemplate.ps1" -ExportPath "TestDrive:\test.ps1" -Force;
            if( (Get-Module "pester").Version -gt "3.4.0" )
            {
               "TestDrive:\test.ps1" | Should FileContentMatch "steptemplate";
            }
            else
            {
               "TestDrive:\test.ps1" | Should Contain "steptemplate";
            }
        }

        It "Should throw an exception if the file already exists" {
            Set-Content "TestDrive:\test.ps1" -Value "existing";
            {
                Export-StepTemplate -Path "TestDrive:\steptemplate.ps1" -ExportPath "TestDrive:\test.ps1";
            } | Should Throw;
        }

        It "Should overwrite the file if it already exists and -Force is specified" {
            Set-Content "TestDrive:\test.ps1" -Value "existing";
            Export-StepTemplate -Path "TestDrive:\steptemplate.ps1" -ExportPath "TestDrive:\test.ps1" -Force;
            if( (Get-Module "pester").Version -gt "3.4.0" )
            {
               "TestDrive:\test.ps1" | Should FileContentMatch "steptemplate";
            }
            else
            {
               "TestDrive:\test.ps1" | Should Contain "steptemplate";
            }
        }

    }

    Context "Clipboard" {

        It "Should export the steptemplate to the system clipboard" {
            Export-StepTemplate -Path "TestDrive:\steptemplate.ps1" -ExportToClipboard;
            [System.Windows.Forms.Clipboard]::GetText() | Should Be "steptemplate";
        }

    }

}