# Builds Sozvon from this checkout, puts it into the user's programs folder and adds a desktop shortcut.
# Needs the .NET SDK only. The engine is not installed here: the app opens its setup wizard on first launch.
param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA "Programs\Sozvon")
)
$ErrorActionPreference = "Stop"

$windows = $PSScriptRoot
$repo = Split-Path $windows -Parent
$dotnet = Join-Path $env:USERPROFILE ".dotnet\dotnet.exe"
if (-not (Test-Path -LiteralPath $dotnet)) {
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
}

if (Get-Process -Name Sozvon -ErrorAction SilentlyContinue) {
    throw "Sozvon is running. Quit it from the tray icon and run this again."
}

& $dotnet publish (Join-Path $windows "Sozvon.App\Sozvon.App.csproj") -c Release -p:Platform=x64 -o $Target --nologo
if ($LASTEXITCODE -ne 0) {
    throw "The build failed with code $LASTEXITCODE."
}

# The wizard looks for an engine folder next to the app.
$engine = Join-Path $Target "engine"
if (Test-Path -LiteralPath $engine) {
    Remove-Item -LiteralPath $engine -Recurse -Force
}
New-Item -ItemType Directory -Path $engine | Out-Null
$skip = @(".venv", "tests", "__pycache__", ".pytest_cache", ".ruff_cache")
Get-ChildItem -LiteralPath (Join-Path $repo "engine") -Force |
    Where-Object { $skip -notcontains $_.Name } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $engine -Recurse -Force }

$desktop = [Environment]::GetFolderPath("Desktop")
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $desktop "Sozvon.lnk"))
$link.TargetPath = Join-Path $Target "Sozvon.exe"
$link.WorkingDirectory = $Target
$link.Description = "Sozvon"
$link.Save()

Write-Host "Installed to $Target. Open Sozvon from the desktop shortcut."
