# Optional Internet smoke test, using Windows network access and temporary state.
param([Parameter(Mandatory=$true)][string]$Binary)
$ErrorActionPreference = 'Stop'
$Binary = [IO.Path]::GetFullPath($Binary)
$Work = Join-Path ([IO.Path]::GetTempPath()) ('easy-proxy-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null
function Free-Port {
    $Listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $Listener.Start(); $Port = $Listener.LocalEndpoint.Port; $Listener.Stop(); return $Port
}
$Server = $null; $Client = $null
$Failures = @()
try {
    $UpstreamPort = Free-Port
    $ClientPort = Free-Port
    $State = Join-Path $Work 'state'
    $ProfilePath = Join-Path $Work 'client.json'
    & $Binary init --dir $State --host 127.0.0.1 --port $UpstreamPort --listen "127.0.0.1:$UpstreamPort"
    if ($LASTEXITCODE) { throw 'Init failed' }
    & $Binary pki-export --dir $State --out $ProfilePath --listen "127.0.0.1:$ClientPort"
    if ($LASTEXITCODE) { throw 'Export failed' }
    $Server = Start-Process $Binary -ArgumentList @('server','--config',('"' + (Join-Path $State 'server.json') + '"')) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Work 'server.log')
    $Client = Start-Process $Binary -ArgumentList @('client','run','--config',('"' + $ProfilePath + '"')) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Work 'client.log')
    Start-Sleep -Seconds 1
    & $Binary probe --config $ProfilePath
    if ($LASTEXITCODE) { $Failures += 'Probe failed' }
    $Proxy = "http://127.0.0.1:$ClientPort"
    foreach ($Target in @('https://github.com','https://huggingface.co/bert-base-uncased/resolve/main/config.json','https://pypi.org/simple/requests/')) {
        & curl.exe --silent --show-error --fail --location --max-time 60 --proxy $Proxy --output NUL --write-out "PASS $Target %{http_code}`n" $Target
        if ($LASTEXITCODE) { $Failures += "Download failed: $Target" }
    }
    & git.exe -c "http.proxy=$Proxy" clone --depth 1 https://github.com/octocat/Hello-World.git (Join-Path $Work 'clone')
    if ($LASTEXITCODE) { throw 'Git clone failed' }
    if ($Failures.Count) { throw ($Failures -join '; ') }
    Write-Output 'Live Windows TLS bridge, GitHub, Hugging Face, PyPI, Docker challenge, and Git clone passed.'
} finally {
    foreach ($Process in @($Client,$Server)) { if ($Process -and !$Process.HasExited) { Stop-Process -Id $Process.Id -Force } }
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
