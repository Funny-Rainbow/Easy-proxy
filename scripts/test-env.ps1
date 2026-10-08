$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/client-env.ps1"
$env:HTTPS_PROXY = 'https://previous.example:443'
$env:NO_PROXY = 'previous.example'
Enable-EasyProxy
if ($env:HTTPS_PROXY -ne 'http://127.0.0.1:17890') { throw 'Enable failed' }
Enable-EasyProxy -Address '127.0.0.1:17891'
Disable-EasyProxy
if ($env:HTTPS_PROXY -ne 'https://previous.example:443' -or $env:NO_PROXY -ne 'previous.example') { throw 'Restore failed' }
$Failed = $false
try { Enable-EasyProxy -Address '0.0.0.0:1234' } catch { $Failed = $true }
if (!$Failed) { throw 'Non-loopback address accepted' }
Write-Output 'PowerShell environment restoration passed.'
