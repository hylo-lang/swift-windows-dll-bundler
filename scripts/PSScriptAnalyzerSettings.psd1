@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Write-Host is intentional: this script emits human-readable log
        # lines to the GitHub Actions console, not pipeline output.
        'PSAvoidUsingWriteHost'
    )
}
