# Installs the Sozvon engine on Windows into the data folder (default %LOCALAPPDATA%\Sozvon). No administrator rights.
# Run without changing the system's script policy, for this one process only:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 [-DataDir <folder>] [-Gpu] [-Experimental]
# -Gpu adds acceleration when this machine has a usable card; any failure there leaves the working CPU install.
# Safe to re-run: anything already downloaded is not downloaded again.
param(
    [string]$DataDir = "",
    [switch]$Gpu,
    [switch]$Experimental
)

# Errors of external commands are checked by $LASTEXITCODE: with Stop here, PowerShell 5.1 turns any stderr line into one.
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$UvVersion = "0.11.26"
$UvSha256 = "4e1278ede866be6c0bf32d2f466cc6de7a9fb399ecf20c9ce2d186e52424be47"
$UvUrl = "https://github.com/astral-sh/uv/releases/download/$UvVersion/uv-x86_64-pc-windows-msvc.zip"
$GpuSpaceGb = 5

function T([string]$ru, [string]$en) { if ($env:SOZVON_UI_LANG -eq "en") { $en } else { $ru } }
function Step([string]$message) { Write-Output "==> $message" }
function Die([string]$message) { [Console]::Error.WriteLine($message); exit 1 }

# Run an external program; $true if it ended with code 0.
function Run {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    return ($LASTEXITCODE -eq 0)
}

$machine = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($machine -ne "AMD64") {
    Die (T "ОШИБКА: Sozvon на Windows работает только на процессорах x64, на $machine он пока не поддерживается." "ERROR: Sozvon on Windows runs only on x64 processors; $machine is not supported yet.")
}

if (-not $DataDir) { $DataDir = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Sozvon" }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$DataDir = (Resolve-Path -LiteralPath $DataDir).ProviderPath

# Run from the repository: the code is copied next to the data, as the app does.
$source = $PSScriptRoot
if ((Resolve-Path -LiteralPath $source).ProviderPath -ne $DataDir) {
    foreach ($item in "server.py", "install.py", "models.py", "models.json", "pyproject.toml", "uv.lock", ".python-version", "vocab.default.json", "setup.ps1", "sozvon_engine", "bin", "gpu") {
        Copy-Item -LiteralPath (Join-Path $source $item) -Destination $DataDir -Recurse -Force -ErrorAction Stop
    }
    Get-ChildItem -LiteralPath $DataDir -Recurse -Directory -Filter "__pycache__" | Remove-Item -Recurse -Force
}
Set-Location -LiteralPath $DataDir

$UvDir = Join-Path $HOME ".local\bin"
$Uv = Join-Path $UvDir "uv.exe"
if (-not (Test-Path -LiteralPath $Uv)) {
    Step (T "Ставлю uv $UvVersion (менеджер Python от astral.sh)" "Installing uv $UvVersion (Python manager by astral.sh)")
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sozvon-uv-" + [Guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp "uv.zip"
        Invoke-WebRequest -UseBasicParsing -Uri $UvUrl -OutFile $zip -ErrorAction Stop
        $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $UvSha256) { Die (T "ОШИБКА: контрольная сумма uv не совпала." "ERROR: uv checksum mismatch.") }
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force -ErrorAction Stop
        New-Item -ItemType Directory -Force -Path $UvDir | Out-Null
        Copy-Item (Join-Path $tmp "uv.exe"), (Join-Path $tmp "uvx.exe") $UvDir -Force -ErrorAction Stop
    } catch {
        Die (T "ОШИБКА: не удалось поставить uv: $_" "ERROR: could not install uv: $_")
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$Python = Join-Path $DataDir ".venv\Scripts\python.exe"

# torch can be left half replaced (a killed GPU step), which a plain sync does not notice.
function SyncEnvironment([switch]$ReinstallTorch) {
    $syncArgs = @("sync", "--frozen", "--no-dev")
    if ($ReinstallTorch) { $syncArgs += @("--reinstall-package", "torch") }
    return (Run $Uv $syncArgs)
}

$gpuMarker = Join-Path $DataDir ".gpu-installing"
$interrupted = Test-Path -LiteralPath $gpuMarker

Step (T "Ставлю Python 3.12 и зависимости (около 1 ГБ, только в первый раз)" "Installing Python 3.12 and dependencies (about 1 GB, first time only)")
if (-not (SyncEnvironment -ReinstallTorch:$interrupted)) { Die (T "ОШИБКА: не удалось поставить зависимости." "ERROR: could not install the dependencies.") }
Remove-Item -LiteralPath $gpuMarker -Force -ErrorAction SilentlyContinue

Step (T "Подключаю ffmpeg" "Setting up ffmpeg")
$ffmpeg = & $Python -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())"
if ($LASTEXITCODE -ne 0 -or -not $ffmpeg) { Die (T "ОШИБКА: не найден ffmpeg." "ERROR: ffmpeg was not found.") }
Copy-Item -LiteralPath $ffmpeg.Trim() -Destination (Join-Path $DataDir ".venv\Scripts\ffmpeg.exe") -Force -ErrorAction Stop

# The sync above puts the CPU torch back: a machine with a working GPU step gets it again without being asked.
$gpuState = Join-Path $DataDir ".gpu.json"
if ((Test-Path -LiteralPath $gpuState) -and -not $Gpu) {
    try { if ((Get-Content -LiteralPath $gpuState -Raw -Encoding UTF8 | ConvertFrom-Json).ok -eq $true) { $Gpu = $true } } catch { }
}

function GiveUpGpu([string]$backend, [string]$reason) {
    Write-Output (T "Ускорение не подключено ($reason). Всё будет работать на процессоре." "Acceleration was not set up ($reason). Everything will run on the processor.")
    & $Python -m sozvon_engine.gpu_probe fail $backend $reason
    if (-not (SyncEnvironment -ReinstallTorch)) { Die (T "ОШИБКА: не удалось вернуть окружение." "ERROR: could not restore the environment.") }
    Remove-Item -LiteralPath $gpuMarker -Force -ErrorAction SilentlyContinue
}

if ($Gpu) {
    Step (T "Ищу видеокарту" "Looking for a GPU")
    $probeArgs = @("-m", "sozvon_engine.gpu_probe", "detect")
    if ($Experimental) { $probeArgs += "--experimental" }
    $found = & $Python @probeArgs
    $found = if ($found) { ([string]$found).Trim() } else { "none" }
    if ($found.StartsWith("none")) {
        & $Python -m sozvon_engine.gpu_probe fail none "no supported GPU"
        Write-Output (T "Подходящей видеокарты нет. Всё будет работать на процессоре." "No supported GPU. Everything will run on the processor.")
    } else {
        $parts = $found.Split(" ", 4)
        $backend, $index, $requirements = $parts[0], $parts[1], $parts[2]
        Write-Output (T "Нашёл: $($parts[3])" "Found: $($parts[3])")
        $drive = Get-PSDrive -Name ($DataDir.Substring(0, 1))
        if ($drive.Free -lt ($GpuSpaceGb * 1GB)) {
            GiveUpGpu $backend (T "нужно около $GpuSpaceGb ГБ свободного места" "about $GpuSpaceGb GB of free disk space is needed")
        } else {
            Step (T "Ставлю ускорение ($backend, несколько ГБ)" "Installing acceleration ($backend, several GB)")
            $file = Join-Path $DataDir "gpu\$requirements"
            New-Item -ItemType File -Force -Path $gpuMarker | Out-Null
            $installed = Run $Uv @("pip", "install", "--python", $Python, "--require-hashes", "--no-deps", "--reinstall-package", "torch", "--index-url", $index, "-r", $file)
            if (-not $installed) {
                GiveUpGpu $backend (T "не удалось скачать" "the download failed")
            } else {
                Step (T "Проверяю видеокарту" "Checking the GPU")
                & $Python -m sozvon_engine.gpu_probe verify $backend
                if ($LASTEXITCODE -ne 0) {
                    GiveUpGpu $backend (T "проверка на карте не прошла" "the check on the card failed")
                } else {
                    Remove-Item -LiteralPath $gpuMarker -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# Models (models.json, pinned revisions), diarization, markers. After the GPU step: the default model depends on it.
$env:PYTHONWARNINGS = "ignore"
& $Python (Join-Path $DataDir "install.py") $DataDir
if ($LASTEXITCODE -ne 0) { Die (T "ОШИБКА: не удалось поставить модели." "ERROR: could not install the models.") }
