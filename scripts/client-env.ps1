# Dot-source this file: . .\scripts\client-env.ps1
function Enable-EasyProxy {
    param([string]$Address = '127.0.0.1:17890')
    if ($Address -notmatch '^127\.0\.0\.1:([0-9]{1,5})$' -or [int]$Matches[1] -lt 1 -or [int]$Matches[1] -gt 65535) { throw 'Use a loopback address such as 127.0.0.1:17890' }
    if (!$script:EasyProxySaved) {
        $script:EasyProxySaved = @{}
        foreach ($Name in @('HTTPS_PROXY','https_proxy','NO_PROXY','no_proxy')) {
            $script:EasyProxySaved[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
        }
    }
    $env:HTTPS_PROXY = "http://$Address"
    $Original = $script:EasyProxySaved['NO_PROXY']
    if ($Original) { $env:NO_PROXY = "$Original,localhost,127.0.0.1,::1" } else { $env:NO_PROXY = 'localhost,127.0.0.1,::1' }
    Write-Output "HTTPS proxy enabled: http://$Address"
}
function Disable-EasyProxy {
    if (!$script:EasyProxySaved) { return }
    foreach ($Name in $script:EasyProxySaved.Keys) {
        [Environment]::SetEnvironmentVariable($Name, $script:EasyProxySaved[$Name], 'Process')
    }
    $script:EasyProxySaved = $null
    Write-Output 'Original proxy environment restored.'
}
