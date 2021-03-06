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
   Get-LiteralValueFromAstNode.Tests

.SYNOPSIS
    Pester tests for Get-LiteralValueFromAstNode
#>

$ErrorActionPreference = "Stop";
Set-StrictMode -Version "Latest";

InModuleScope "OctopusStepTemplateCi" {

    Describe "Get-LiteralValueFromAstNode" {

        # [System.Management.Automation.Language.StringConstantExpressionAst] tests

        It "Should return the value when the InputObject is an empty string" {
            $commandExpression = { "" }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be "";
        }

        It "Should return the value when the InputObject is a simple string" {
            $commandExpression = { "my string" }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be "my string";
        }

        # [System.Management.Automation.Language.ConstantExpressionAst] tests

        It "Should return the value when the InputObject is a positive integer" {
            $commandExpression = { 100 }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be 100;
        }

        It "Should return the value when the InputObject is a negative integer" {
            $commandExpression = { -100 }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be -100;
        }

        # [System.Management.Automation.Language.ExpandableStringExpressionAst] tests

        It "Should return the value when the InputObject is an expandable string" {
            $commandExpression = { "[$null|$true|$false]" }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be "[|True|False]";
        }

        # [System.Management.Automation.Language.VariableExpressionAst] tests

        It "Should return the value when the InputObject is `$null" {
            $commandExpression = { $null }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be $null;
        }

        It "Should return the value when the InputObject is `$true" {
            $commandExpression = { $true }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be $true;
        }

        It "Should return the value when the InputObject is `$false" {
            $commandExpression = { $false }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be $false;
        }

        It "Should throw when the InputObject is not a constant variable" {
            $myVariable = 100;
            {
                $commandExpression = { $myVariable }.Ast.EndBlock.Statements[0].PipelineElements[0];
                $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            } | Should Throw "Only variables that reference constant values can be evaluated (e.g. `$true, `$false, `$null).";
        }

        # [System.Management.Automation.Language.BinaryExpressionAst] tests

        It "Should return the value when the InputObject is an integer addition" {
            $commandExpression = { 100 + 200 }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be 300;
        }

        It "Should return the value when the InputObject is a string concatenation" {
            $commandExpression = { "my" + " " + "string" }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            $actual | Should Be "my string";
        }

        It "Should throw when the InputObject is an unsupported operation" {
            {
                $commandExpression = { 100 - 50 }.Ast.EndBlock.Statements[0].PipelineElements[0];
                $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            } | Should Throw "Operator not supported.";
        }

        # [System.Management.Automation.Language.CommandExpressionAst] tests

        # [System.Management.Automation.Language.ArrayExpressionAst] tests

        It "Should return the value when the InputObject is an empty array" {
            $commandExpression = { @() }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            @(,$actual) | Should Not Be $null;
            @(,$actual) | Should BeOfType [array];
            $actual.Length | Should Be 0;
        }

        It "Should return the value when the InputObject is an array with a single item" {
            $commandExpression = { @( 100 ) }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            @(,$actual) | Should Not Be $null;
            @(,$actual) | Should BeOfType [array];
            $actual.Length | Should Be 1;
            $actual[0] | Should Be 100;
        }

        It "Should return the value when the InputObject is an array with multiple items" {
            $commandExpression = { @( $null, 100, "my string" ) }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            @(,$actual) | Should Not Be $null;
            @(,$actual) | Should BeOfType [array];
            $actual.Length | Should Be 3;
            $actual[0] | Should Be $null;
            $actual[1] | Should Be 100;
            $actual[2] | Should Be "my string";
        }

        It "Should return the value when the InputObject is an array with missing commas" {
            $commandExpression = { @(
                $null,
                100 # <-- look no comma!
                "my string"
            ) }.Ast.EndBlock.Statements.PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            @(,$actual) | Should Not Be $null;
            @(,$actual) | Should BeOfType [array];
            $actual.Length | Should Be 3;
            $actual[0] | Should Be $null;
            $actual[1] | Should Be 100;
            $actual[2] | Should Be "my string";
        }

        # [System.Management.Automation.Language.ArrayLiteralAst] tests

        # [System.Management.Automation.Language.HashtableAst] tests

        It "Should return the value when the InputObject is an empty hashtable" {
            $commandExpression = { @{} }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            @(,$actual) | Should Not Be $null;
            @(,$actual) | Should BeOfType [hashtable];
            $actual.Count | Should Be 0;
        }

        It "Should return the value when the InputObject is a hashtable with a single item" {
            $commandExpression = { @{ "myKey" = 100 } }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            @(,$actual) | Should Not Be $null;
            @(,$actual) | Should BeOfType [hashtable];
            $actual.Count | Should Be 1;
            $actual["myKey"] | Should Be 100;
        }

        It "Should return the value when the InputObject is a hashtable with multiple items" {
            $commandExpression = { @{ "myKey1" = $null; "myKey2" = 100; "myKey3" = "my string" } }.Ast.EndBlock.Statements[0].PipelineElements[0];
            $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            @(,$actual) | Should Not Be $null;
            @(,$actual) | Should BeOfType [hashtable];
            $actual.Count | Should Be 3;
            $actual["myKey1"] | Should Be $null;
            $actual["myKey2"] | Should Be 100;
            $actual["myKey3"] | Should Be "my string";
        }

        # unsupported node type tests

        It "Should throw when the InputObject is a command node" {
            {
                $commandExpression = { write-host "my message" }.Ast.EndBlock.Statements[0].PipelineElements[0];
                $actual = Get-LiteralValueFromAstNode -Node $commandExpression;
            } | Should Throw "Ast nodes of type [System.Management.Automation.Language.CommandAst] are not supported.";
        }

    }

}