<#
.SYNOPSIS
  Recursively copies the DLL closure required to run a Windows executable
  into the directory that contains the executable.

.DESCRIPTION
  Dependencies are discovered with `llvm-readobj --coff-imports`. DLLs
  already sitting next to the executable are treated as build products and
  left in place. Other dependencies are copied only when their base name
  appears on a built-in allow-list of Swift / Foundation / libdispatch /
  MSVC runtime DLLs. Anything else (Windows system DLLs) is ignored. An
  allow-listed DLL that cannot be located on PATH is a hard error.

  Logic adapted from swift-bundler's GenericWindowsBundler.swift.

.PARAMETER Executable
  Absolute path to the .exe whose DLL closure should be bundled.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Executable
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Executable)) {
    throw "Parameter 'Executable' is required."
}
if (-not (Test-Path -LiteralPath $Executable)) {
    throw "Executable not found: $Executable"
}

$bundleDir = (Resolve-Path -LiteralPath (Get-Item -LiteralPath $Executable).DirectoryName).Path

# Allow-listed DLL base-names (with `.dll`). Mirrors swift-bundler's
# GenericWindowsBundler: Swift runtime, Foundation, libdispatch, MSVC
# runtime. The set is case-insensitive to match Windows filename semantics.
$allowList = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
@(
    'swiftCore', 'swiftCRT', 'swiftDispatch', 'swiftDistributed',
    'swiftObservation', 'swiftRegexBuilder', 'swiftRemoteMirror',
    'swiftSwiftOnoneSupport', 'swiftSynchronization', 'swiftWinSDK',
    'Foundation', 'FoundationXML', 'FoundationNetworking',
    'FoundationEssentials', 'FoundationInternationalization',
    'BlocksRuntime', '_FoundationICU', '_InternalSwiftScan',
    '_InternalSwiftStaticMirror', 'swift_Concurrency', 'swift_RegexParser',
    'swift_StringProcessing', 'swift_Differentiation',
    'concrt140', 'msvcp140', 'msvcp140_1', 'msvcp140_2',
    'msvcp140_atomic_wait', 'msvcp140_codecvt_ids',
    'vccorlib140', 'vcruntime140', 'vcruntime140_1', 'vcruntime140_threads',
    'dispatch'
) | ForEach-Object { [void]$allowList.Add("$_.dll") }

$pathDirs = ($env:Path -split ';') | Where-Object { $_ -ne '' }
$visited = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# Returns the source path to bundle for a DLL named $Name, or $null when
# the DLL is a Windows system DLL we deliberately ignore. Throws when an
# allow-listed DLL cannot be located on PATH.
function Resolve-Dll {
    param([Parameter(Mandatory)][string]$Name)

    # A DLL sitting next to the executable is a build product and is
    # always bundled (it is already in the right place).
    $local = Join-Path $bundleDir $Name
    if (Test-Path -LiteralPath $local) { return $local }

    if (-not $allowList.Contains($Name)) { return $null }

    foreach ($dir in $pathDirs) {
        $candidate = Join-Path $dir $Name
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    throw "Could not locate allow-listed DLL '$Name' on PATH."
}

# Returns the list of DLL names imported by $Module, parsed from
# `llvm-readobj --coff-imports`. Throws on any unexpected output.
function Get-DllDependency {
    param([Parameter(Mandatory)][string]$Module)

    $stderrFile = New-TemporaryFile
    try {
        $stdout = & llvm-readobj --coff-imports $Module 2>$stderrFile.FullName
        $exit = $LASTEXITCODE
        $stderr = Get-Content -Raw -LiteralPath $stderrFile.FullName
    } finally {
        Remove-Item -LiteralPath $stderrFile.FullName -Force -ErrorAction SilentlyContinue
    }

    if ($exit -ne 0) {
        throw "llvm-readobj failed for '$Module' (exit ${exit}):`n$stderr"
    }

    $text = ($stdout | Out-String)

    # llvm-readobj emits one `Import { ... }` block per imported DLL. We
    # split on the opener and pull the `Name:` field out of each block.
    # The first chunk is the file header, which we discard.
    $chunks = $text -split 'Import\s*\{'
    if ($chunks.Count -lt 2) {
        throw "llvm-readobj produced no Import sections for '$Module'. Output was:`n$text"
    }

    $deps = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -lt $chunks.Count; $i++) {
        $block = $chunks[$i]
        $match = [regex]::Match($block, '(?m)^\s*Name:\s*(\S+)\s*$')
        if (-not $match.Success) {
            throw "Could not find 'Name:' field in Import block #$i of '$Module'. Block was:`n$block"
        }
        $deps.Add($match.Groups[1].Value)
    }
    return $deps
}

function Copy-DllDependencyClosure {
    param([Parameter(Mandatory)][string]$Module)

    foreach ($dep in (Get-DllDependency -Module $Module)) {
        if (-not $visited.Add($dep)) { continue }

        $source = Resolve-Dll -Name $dep
        if ($null -eq $source) { continue }

        $dest = Join-Path $bundleDir $dep
        if ($source -ine $dest) {
            Write-Host "Copying $source"
            Copy-Item -LiteralPath $source -Destination $dest -Force
            $pdb = [System.IO.Path]::ChangeExtension($source, 'pdb')
            if (Test-Path -LiteralPath $pdb) {
                Copy-Item -LiteralPath $pdb `
                    -Destination ([System.IO.Path]::ChangeExtension($dest, 'pdb')) `
                    -Force
            }
        }

        Copy-DllDependencyClosure -Module $source
    }
}

Write-Host "Bundling DLLs for $Executable into $bundleDir"
Copy-DllDependencyClosure -Module $Executable
Write-Host "Done. Visited $($visited.Count) unique DLL reference(s)."
