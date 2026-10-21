# PSScriptAnalyzer settings for this repository.
#
# Run locally with:
#   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
#
# Rules are excluded here only when they don't fit the whole repository, with
# the reason. One-off exceptions are suppressed in the code next to the
# finding instead, so the reason stays with the code.
@{
    Severity     = @("Error", "Warning")

    ExcludeRules = @(
        # These are interactive console scripts: colored progress output is
        # the point, and since PowerShell 5 Write-Host goes to the
        # information stream, so it can still be captured and is included in
        # the transcript log.
        "PSAvoidUsingWriteHost"
    )
}
