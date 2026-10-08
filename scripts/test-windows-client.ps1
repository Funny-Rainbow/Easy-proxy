# Optional integration check for an interactive Windows user session.
param([Parameter(Mandatory=$true)][string]$Binary)
$ErrorActionPreference = 'Stop'
$Binary = [IO.Path]::GetFullPath($Binary)
$TaskName = 'Easy-proxy-client-' + [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { throw 'Existing client task found; refusing to modify it for tests.' }
$Work = Join-Path ([IO.Path]::GetTempPath()) ('easy-proxy-client-test-' + [Guid]::NewGuid().ToString('N'))
$SavedAppData = $env:LOCALAPPDATA
New-Item -ItemType Directory -Path $Work | Out-Null
try {
    $env:LOCALAPPDATA = Join-Path $Work 'appdata'
    $Listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $Listener.Start(); $Port = $Listener.LocalEndpoint.Port; $Listener.Stop()
    $State = Join-Path $Work 'state'
    $ProfilePath = Join-Path $Work 'client.json'
    & $Binary init --dir $State --host 127.0.0.1 --port 18443
    if ($LASTEXITCODE) { throw 'Init failed' }
    & $Binary pki-export --dir $State --out $ProfilePath --listen "127.0.0.1:$Port"
    if ($LASTEXITCODE) { throw 'Export failed' }
    & $Binary client install --config $ProfilePath
    if ($LASTEXITCODE) { throw 'Install failed' }
    $Installed = Join-Path $env:LOCALAPPDATA 'Easy-proxy/easy-proxy.exe'
    $Acl = Get-Acl (Join-Path $env:LOCALAPPDATA 'Easy-proxy/client.json')
    foreach ($Access in $Acl.Access) {
        $Sid = $Access.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        if ($Sid -notin @('S-1-5-18',[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) { throw "Unexpected file ACL: $Sid" }
    }
    & $Installed client status
    if ($LASTEXITCODE) { throw 'Status failed' }
    $Code = & curl.exe --silent --max-time 5 --output NUL --write-out '%{http_code}' "http://127.0.0.1:$Port/"
    if ($Code -ne '405') { throw "Local bridge did not reject non-CONNECT request: $Code" }
    & $Binary client stop
    if ($LASTEXITCODE) { throw 'Stop failed' }
    & $Binary client start
    if ($LASTEXITCODE) { throw 'Start failed' }
    & $Installed client uninstall
    if ($LASTEXITCODE) { throw 'Uninstall failed' }
    for ($i=0; $i -lt 20 -and (Test-Path -LiteralPath $Installed); $i++) { Start-Sleep -Milliseconds 250 }
    if (Test-Path -LiteralPath $Installed) { throw 'Installed executable was not cleaned up' }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { throw 'Scheduled task was not removed' }
    Write-Output 'Windows client install/start/stop/ACL/uninstall lifecycle passed.'
} finally {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $env:LOCALAPPDATA = $SavedAppData
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
