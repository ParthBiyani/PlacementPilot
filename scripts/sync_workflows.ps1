# Weekly workflow export/drift-check (Phase 3 leftover).
# Runs scripts/sync_workflows.py against the live n8n instance; if it finds real
# drift (a live UI edit that never made it back into git), commits and pushes it.
# Intended to be run weekly -- manually, or via a scheduled task pointed at this file.

$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

python3 scripts/sync_workflows.py
$exitCode = $LASTEXITCODE

if ($exitCode -eq 2) {
    git add workflows/*.json
    $status = git status --porcelain workflows/
    if ($status) {
        $date = Get-Date -Format "yyyy-MM-dd HH:mm"
        git commit -m "chore: sync workflows from live n8n instance ($date) -- drift detected by weekly export check"
        git push origin main
        Write-Host "Drift committed and pushed."
    } else {
        Write-Host "sync_workflows.py reported drift but git saw no staged changes -- investigate."
    }
} elseif ($exitCode -eq 0) {
    Write-Host "No drift -- nothing to commit."
} else {
    Write-Host "sync_workflows.py failed (exit $exitCode) -- not committing anything."
    exit 1
}
