# Start splat-server (PowerShell).
#   .\server\run_server.ps1              -> 127.0.0.1:8000 (this PC only)
#   .\server\run_server.ps1 -Lan         -> 0.0.0.0:8000   (reachable from the LAN; needs the firewall rule)
param(
    [switch]$Lan,
    [int]$Port = 8000,
    [string]$Python = "$env:USERPROFILE\anaconda3\envs\sharp\python.exe"
)
$ErrorActionPreference = "Stop"
# The user site-packages (%APPDATA%\Python\Python313) would shadow the conda env's packages.
$env:PYTHONNOUSERSITE = "1"
$hostAddr = if ($Lan) { "0.0.0.0" } else { "127.0.0.1" }
Set-Location $PSScriptRoot
& $Python app.py --host $hostAddr --port $Port
