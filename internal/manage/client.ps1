param(
    [Parameter(Mandatory=$true)][string]$Binary,
    [Parameter(Mandatory=$true,Position=0)][ValidateSet('install','start','stop','status','uninstall')][string]$Action,
    [string]$Config
)
$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:LOCALAPPDATA 'Easy-proxy'
$Installed = Join-Path $Root 'easy-proxy.exe'
$ProfilePath = Join-Path $Root 'client.json'
$TaskName = 'Easy-proxy-client-' + [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Set-PrivateDirectory {
    $Acl = New-Object System.Security.AccessControl.DirectorySecurity
    $Acl.SetAccessRuleProtection($true, $false)
    foreach ($Sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, [System.Security.Principal.SecurityIdentifier]'S-1-5-18')) {
        $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule($Sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $Acl.AddAccessRule($Rule)
    }
    Set-Acl -LiteralPath $Root -AclObject $Acl
}
switch ($Action) {
    'install' {
        if (!$Config) { throw 'Use client install --config PATH' }
        & $Binary check --kind client --config $Config --listen
        if ($LASTEXITCODE -ne 0) { throw 'Client configuration check failed' }
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { throw 'Client already installed; stop and uninstall before replacing it.' }
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        Set-PrivateDirectory
        Copy-Item -LiteralPath $Binary -Destination $Installed -Force
        if ([IO.Path]::GetFullPath($Config) -ne $ProfilePath) { Copy-Item -LiteralPath $Config -Destination $ProfilePath -Force }
        # Copied files can retain their source ACL: explicitly inherit the
        # private destination directory rather than trusting source permissions.
        foreach ($Path in @($Installed, $ProfilePath)) {
            $FileAcl = New-Object System.Security.AccessControl.FileSecurity
            $FileAcl.SetAccessRuleProtection($false, $false)
            Set-Acl -LiteralPath $Path -AclObject $FileAcl
        }
        $TaskAction = New-ScheduledTaskAction -Execute $Installed -Argument ('client run --config "' + $ProfilePath + '"')
        $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $Identity
        $Principal = New-ScheduledTaskPrincipal -UserId $Identity -LogonType Interactive -RunLevel Limited
        $Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $TaskAction -Trigger $Trigger -Principal $Principal -Settings $Settings -Description 'Easy-proxy local CONNECT bridge' | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Milliseconds 800
        if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') { throw 'Client task failed to start. Use client run --config PATH to see the error.' }
        Write-Output 'Client installed and enabled at user logon. Import scripts/client-env.ps1 to enable proxy in this terminal.'
    }
    'start' { Start-ScheduledTask -TaskName $TaskName }
    'stop' { Stop-ScheduledTask -TaskName $TaskName }
    'status' { Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State; Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object LastRunTime,LastTaskResult }
    'uninstall' {
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Task) {
            if ($Task.Description -ne 'Easy-proxy local CONNECT bridge') { throw 'Refusing to remove an unrecognized task' }
            Stop-ScheduledTask -TaskName $TaskName
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
        # The caller can be the installed executable. A separate cleanup process
        # waits for that caller to exit before deleting the file Windows locks.
        Remove-Item -LiteralPath $ProfilePath -Force -ErrorAction SilentlyContinue
        if ([IO.Path]::GetFullPath($Binary) -eq $Installed) {
            $CallerId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
            $QuotedExe = $Installed.Replace("'", "''")
            $QuotedRoot = $Root.Replace("'", "''")
            $Cleanup = "Wait-Process -Id $CallerId -Timeout 30 -ErrorAction SilentlyContinue; Remove-Item -LiteralPath '$QuotedExe' -Force -ErrorAction SilentlyContinue; if (!(Get-ChildItem -LiteralPath '$QuotedRoot' -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath '$QuotedRoot' -ErrorAction SilentlyContinue }"
            $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Cleanup))
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-EncodedCommand',$Encoded) | Out-Null
        } else {
            Remove-Item -LiteralPath $Installed -Force -ErrorAction SilentlyContinue
            if (!(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $Root -ErrorAction SilentlyContinue }
        }
        Write-Output 'Client task removed. Run Disable-EasyProxy in terminals where the proxy was enabled.'
    }
}
