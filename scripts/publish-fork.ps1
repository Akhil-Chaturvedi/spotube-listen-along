# Publish the "Listen Along" Spotube fork to your GitHub account and trigger a
# cloud APK build (no local Flutter SDK required).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/publish-fork.ps1 `
#       -RepoUrl https://github.com/<you>/spotube-listen-along.git
#
# Prerequisites:
#   - git installed and authenticated (gh auth login, or a PAT / SSH key).
#   - The repo <you>/spotube-listen-along already created on GitHub (empty).

param(
  [Parameter(Mandatory = $true)]
  [string]$RepoUrl,

  [string]$Branch = "listen-along",
  [string]$CommitMessage = "feat: Friend Activity support (live refresh + startup 401 fix)"
)

$ErrorActionPreference = "Stop"

# Run from the repo root (this script lives in scripts/).
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "==> Repo root: $root"

# Ensure we have a git repo.
if (-not (Test-Path ".git")) {
  Write-Host "==> Initializing git repo"
  git init | Out-Null
  git branch -M $Branch
}

# Add or update the fork remote.
$remotes = git remote
if ($remotes -contains "fork") {
  git remote set-url fork $RepoUrl
} else {
  git remote add fork $RepoUrl
}
Write-Host "==> fork remote -> $RepoUrl"

# Commit the changes on a dedicated branch.
git checkout -B $Branch
git add -A
git commit -m $CommitMessage 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "==> Nothing to commit (already committed)"
}

Write-Host "==> Pushing to fork ($Branch)"
git push -u fork $Branch --force

Write-Host ""
Write-Host "Done. Next steps:"
Write-Host "  1. Open https://github.com/<you>/spotube-listen-along/actions"
Write-Host "  2. Select 'Build Spotube (Listen Along fork) Android APK'"
Write-Host "  3. Click 'Run workflow' (branch: $Branch)"
Write-Host "  4. Download the 'spotube-android-apk' artifact when it finishes."
Write-Host ""
Write-Host "Changed files in this fork:"
git show --stat --oneline HEAD
