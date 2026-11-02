param(
    [string]$Router = '192.168.1.1',
    [string]$TftpAddress = '192.168.1.254'
)

$ErrorActionPreference = 'Stop'
Write-Host 'Скрипт сохранит дамп всех MTD-разделов, запишет загрузчик, очистит UBI и установит OpenWrt.' -ForegroundColor Yellow
if ((Read-Host 'Чтобы начать, введите FLASH-NETIS') -cne 'FLASH-NETIS') { throw 'Отменено до начала любых действий.' }
$WorkDir = $PSScriptRoot
$Fip = 'openwrt-25.12.6-mediatek-filogic-netis_n6-v2-bl31-uboot.fip'
$Recovery = 'openwrt-25.12.6-mediatek-filogic-netis_n6-v2-initramfs-recovery.itb'
$RecoveryTftpName = 'openwrt-mediatek-filogic-netis_n6-v2-initramfs-recovery.itb'
$Sysupgrade = 'openwrt-25.12.6-mediatek-filogic-netis_n6-v2-squashfs-sysupgrade.itb'
$Preloader = 'openwrt-25.12.6-mediatek-filogic-netis_n6-v2-preloader.bin'
$TftpDir = Join-Path $WorkDir 'Tftpd64'
$TftpZip = Join-Path $WorkDir 'tftpd64_portable_v4.74.zip'
$TftpUrl = 'https://github.com/PJO2/tftpd64/releases/download/v4.74/tftpd64_portable_v4.74.zip'
$TftpZipHash = '3ad38a71c0d7d42915429f8f02945e27bcf88161ad1028980d1364af8f76bf22'
$Images = @{
    $Fip        = @{ Hash = '3d60e1bd9594593c89f2dee178a43afa0f4ffc2b0293ef36893212c81ffe0ca4'; Bytes = 809180 }
    $Recovery   = @{ Hash = 'c2bf08cfdfbb8e25c92c9ff6c962992a1c4fcac6df1fe676e046c665641069f1'; Bytes = 9240576 }
    $Sysupgrade = @{ Hash = '4904de774fa041508f2686165fae33711fd9dcfbe446d2cd218ca850b333cc2b'; Bytes = 10940678 }
    $Preloader  = @{ Hash = '73416264bd5ff59fe447cbbb9f756b8ed7e258f4ef48a296773240c11b7bc79b'; Bytes = 230232 }
}
$script:UseNoPasswordAuth = $false
$script:TftpProcess = $null
$script:TftpExePath = $null
$script:FlashCompleted = $false

function Require-Image([string]$Name) {
    $path = Join-Path $WorkDir $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Не найден образ: $path" }
    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $Images[$Name]
    if ($item.Length -ne $expected.Bytes -or $hash -ne $expected.Hash) {
        throw "Образ $Name не совпадает с официальным OpenWrt 25.12.6 (размер/SHA-256). Остановлено до прошивки."
    }
    Write-Host ("Образ проверен: {0} ({1:N0} байт)" -f $Name, $item.Length)
    return $path
}

function Get-TftpExecutable {
    New-Item -ItemType Directory -Path $TftpDir -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Test-Path -LiteralPath $TftpZip) -or (Get-FileHash -LiteralPath $TftpZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $TftpZipHash) {
        Write-Host 'Скачиваю официальный Tftpd64 Portable 4.74...'
        Invoke-WebRequest -Uri $TftpUrl -OutFile $TftpZip -UseBasicParsing
    }
    if ((Get-FileHash -LiteralPath $TftpZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $TftpZipHash) {
        Remove-Item -LiteralPath $TftpZip -Force -ErrorAction SilentlyContinue
        throw 'Архив Tftpd64 не прошёл проверку SHA-256.'
    }
    $workPrefix = [IO.Path]::GetFullPath($WorkDir).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    Get-Process -Name tftpd64,tftpd32 -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($workPrefix,[StringComparison]::OrdinalIgnoreCase) } |
        Stop-Process -Force
    Expand-Archive -LiteralPath $TftpZip -DestinationPath $TftpDir -Force
    $found = Get-ChildItem -LiteralPath $TftpDir -Filter tftpd64.exe -File -Recurse | Select-Object -First 1
    if (-not $found) { throw 'В официальном архиве не найден tftpd64.exe.' }
    return $found.FullName
}

function Prepare-Tftp([string]$ExePath, [string]$RecoveryPath) {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $TftpAddress -ErrorAction SilentlyContinue
    if (-not $ip) { throw "На ПК должен быть настроен адрес $TftpAddress/24 на Ethernet. Настройте его и запустите скрипт снова." }
    New-Item -ItemType Directory -Path $TftpDir -Force | Out-Null
    $tftpFile = Join-Path $TftpDir $RecoveryTftpName
    Copy-Item -LiteralPath $RecoveryPath -Destination $tftpFile -Force
    if ((Get-FileHash -LiteralPath $tftpFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Images[$Recovery].Hash) {
        throw 'Не удалось подготовить recovery-файл под именем, запрашиваемым загрузчиком.'
    }

    $exeDir = Split-Path -Parent $ExePath
    $iniPath = Join-Path $exeDir 'tftpd32.ini'
    $ini = @"
[TFTPD32]
BaseDirectory=$TftpDir
TftpPort=69
Hide=0
WinSize=0
Negociate=1
PXECompatibility=0
DirText=0
ShowProgressBar=1
Timeout=3
MaxRetransmit=6
SecurityLevel=1
UnixStrings=1
Beep=0
VirtualRoot=1
MD5=0
LocalIP=$TftpAddress
Services=1
TftpLogFile=$(Join-Path $TftpDir 'tftpd64.log')
SaveSyslogFile=
PipeSyslogMsg=0
LowestUDPPort=0
HighestUDPPort=0
Enable IPv6=0
"@
    Set-Content -LiteralPath $iniPath -Value $ini -Encoding ASCII
    $script:TftpExePath = $ExePath
    $script:TftpProcess = Start-Process -FilePath $ExePath -WorkingDirectory $exeDir -PassThru
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name tftpd64,tftpd32 -ErrorAction SilentlyContinue)) { throw 'Tftpd64 не запустился.' }
    Write-Host "Tftpd64 настроен: root=$TftpDir, интерфейс=$TftpAddress, recovery=$RecoveryTftpName"
}

function Test-TftpFile {
    Write-Host 'Проверяю локальную TFTP-передачу recovery до записи загрузчика...'
    $udp = [Net.Sockets.UdpClient]::new()
    $udp.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Parse($TftpAddress), 0))
    $udp.Client.ReceiveTimeout = 4000
    $server = [Net.IPEndPoint]::new([Net.IPAddress]::Parse($TftpAddress), 69)
    $rrqStream = [IO.MemoryStream]::new()
    $rrqStream.WriteByte(0); $rrqStream.WriteByte(1)
    $filenameBytes = [Text.Encoding]::ASCII.GetBytes($RecoveryTftpName)
    $rrqStream.Write($filenameBytes, 0, $filenameBytes.Length)
    $rrqStream.WriteByte(0)
    $modeBytes = [Text.Encoding]::ASCII.GetBytes('octet')
    $rrqStream.Write($modeBytes, 0, $modeBytes.Length)
    $rrqStream.WriteByte(0)
    $rrq = $rrqStream.ToArray()
    $rrqStream.Dispose()
    $sink = [IO.MemoryStream]::new()
    $expectedBlock = 1
    $peer = $null
    $lastAck = $null
    $timeouts = 0
    try {
        [void]$udp.Send($rrq, $rrq.Length, $server)
        while ($true) {
            $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
            try { $packet = $udp.Receive([ref]$remote); $timeouts = 0 }
            catch [Net.Sockets.SocketException] {
                if ($_.Exception.SocketErrorCode -ne [Net.Sockets.SocketError]::TimedOut) { throw }
                $timeouts++
                if ($timeouts -gt 5) { throw 'Нет ответа от Tftpd64 на TFTP-запрос.' }
                if ($peer -and $lastAck) { [void]$udp.Send($lastAck, $lastAck.Length, $peer) }
                else { [void]$udp.Send($rrq, $rrq.Length, $server) }
                continue
            }
            if ($peer -and ($remote.Address.ToString() -ne $peer.Address.ToString() -or $remote.Port -ne $peer.Port)) { continue }
            if (-not $peer) { $peer = $remote }
            if ($packet.Length -lt 4) { continue }
            $opcode = ([int]$packet[0] -shl 8) -bor [int]$packet[1]
            if ($opcode -eq 5) { throw "TFTP ERROR: $([Text.Encoding]::ASCII.GetString($packet,4,$packet.Length-4))" }
            if ($opcode -ne 3) { continue }
            $block = ([int]$packet[2] -shl 8) -bor [int]$packet[3]
            if ($block -eq $expectedBlock) {
                $dataLength = $packet.Length - 4
                $sink.Write($packet, 4, $dataLength)
                $lastAck = [byte[]]@(0,4,$packet[2],$packet[3])
                [void]$udp.Send($lastAck, $lastAck.Length, $peer)
                $expectedBlock++
                if ($dataLength -lt 512) { break }
            } elseif ($block -eq ($expectedBlock - 1)) {
                [void]$udp.Send($lastAck, $lastAck.Length, $peer)
            }
        }
    } finally { $udp.Dispose() }
    $bytes = $sink.ToArray()
    $sink.Dispose()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $sha = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha256.Dispose() }
    if ($bytes.Length -ne $Images[$Recovery].Bytes -or $sha -ne $Images[$Recovery].Hash) {
        throw 'TFTP-тест передал файл не полностью или его SHA-256 отличается.'
    }
    Write-Host '[OK] TFTP передаёт правильный recovery-файл.'
}

function Invoke-Native([string]$Path, [string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Path @Arguments
        $script:NativeExitCode = $LASTEXITCODE
        return $output
    } finally { $ErrorActionPreference = $previousPreference }
}

function Test-RemoteNoPasswordAuth {
    $ssh = (Get-Command ssh -ErrorAction Stop).Source
    $common = @('-o','PubkeyAuthentication=no','-o','ConnectTimeout=5','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','GlobalKnownHostsFile=NUL','-T',"root@$Router",'true')
    Invoke-Native $ssh (@('-o','BatchMode=yes') + $common) *> $null
    return ($script:NativeExitCode -eq 0)
}

function Ensure-RemoteAuth([switch]$InteractiveOnly) {
    if (-not $InteractiveOnly -and (Test-RemoteNoPasswordAuth)) { $script:UseNoPasswordAuth = $true; return }
    $ssh = (Get-Command ssh -ErrorAction Stop).Source
    $common = @('-o','PubkeyAuthentication=no','-o','ConnectTimeout=5','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','GlobalKnownHostsFile=NUL','-T',"root@$Router",'true')
    Write-Host "Введите пароль root для $Router, если SSH его запросит."
    Invoke-Native $ssh $common | Out-Host
    if ($script:NativeExitCode -ne 0) { throw "SSH-аутентификация на $Router не удалась." }
    $script:UseNoPasswordAuth = $false
}

function Invoke-Remote([string]$Command, [switch]$AllowDisconnect, [switch]$AllowUpgradeDisconnect) {
    Write-Host "SSH: $Command"
    if ($script:UseNoPasswordAuth) {
        $sshArguments = @('-o','PubkeyAuthentication=no','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','GlobalKnownHostsFile=NUL','-T',"root@$Router",$Command)
    } else {
        $sshArguments = @('-o','PubkeyAuthentication=no','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','GlobalKnownHostsFile=NUL','-T',"root@$Router",$Command)
    }
    $output = Invoke-Native ((Get-Command ssh).Source) $sshArguments
    $code = $script:NativeExitCode
    $text = $output -join "`n"
    if ($text) { $text | Out-Host }
    if ($code -ne 0 -and -not $AllowDisconnect -and -not ($AllowUpgradeDisconnect -and ($code -eq 246 -or $text -match 'Commencing upgrade'))) {
        throw "SSH завершился с кодом $code"
    }
    return $text
}

function Save-Partition([int]$Index, [string]$Destination, [long]$ExpectedBytes) {
    Write-Host ("Дамп mtd{0}: {1:N0} байт" -f $Index, $ExpectedBytes)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command ssh -ErrorAction Stop).Source
    if ($script:UseNoPasswordAuth) {
        $psi.Arguments = "-o PubkeyAuthentication=no -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o GlobalKnownHostsFile=NUL -T root@$Router cat /dev/mtd${Index}ro"
    } else {
        $psi.Arguments = "-o PubkeyAuthentication=no -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o GlobalKnownHostsFile=NUL -T root@$Router cat /dev/mtd${Index}ro"
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Не удалось запустить SSH для mtd$Index" }
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $process.StandardOutput.BaseStream.CopyTo($stream) }
    finally { $stream.Dispose() }
    $process.WaitForExit()
    $actual = (Get-Item -LiteralPath $Destination).Length
    if ($process.ExitCode -ne 0 -or $actual -ne $ExpectedBytes) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "Дамп mtd$Index не прошёл проверку размера/SSH-кода. Прошивка не начата."
    }
}

function Wait-ForSsh([int]$TimeoutSeconds, [string]$Message) {
    Write-Host $Message
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    $lastError = ''
    $authFailures = 0
    $passwordAttempted = $false
    while ((Get-Date) -lt $deadline) {
        $attempt++
        if (-not $script:TftpProcess -or $script:TftpProcess.HasExited) {
            $script:TftpProcess = Start-Process -FilePath $script:TftpExePath -WorkingDirectory (Split-Path -Parent $script:TftpExePath) -PassThru
            Start-Sleep -Seconds 2
        }
        $test = Test-NetConnection -ComputerName $Router -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($test) {
            if (Test-RemoteNoPasswordAuth) { $script:UseNoPasswordAuth = $true; return }
            $authFailures++
            if ($authFailures -ge 6 -and -not $passwordAttempted) {
                try { Ensure-RemoteAuth -InteractiveOnly; return }
                catch { $lastError = $_.Exception.Message; $passwordAttempted = $true }
            }
        }
        if ($attempt % 6 -eq 0) { Write-Host 'SSH порт доступен, жду завершения загрузки recovery и готовности входа...' }
        Start-Sleep -Seconds 5
    }
    throw "SSH recovery не стал готов за $TimeoutSeconds секунд. $lastError Не отключайте питание; проверьте TFTP и оставьте роутер включённым."
}

function Wait-ForRecovery([int]$TimeoutSeconds) {
    Write-Host 'FIP записан и проверен чтением обратно; очистка UBI завершилась.' -ForegroundColor Green
    Write-Host 'Оставьте Tftpd64 открытым. Ищите новый запрос от 192.168.1.1 после перезагрузки; локальная предварительная проверка с ПК запросом роутера не считается.' -ForegroundColor Yellow
    Write-Host 'Жду именно initramfs recovery: доступность SSH заводской системы не считается завершением загрузки.'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    $lastBoard = "SSH от $Router пока недоступен; ответа ubus нет."
    $interactiveBoardAttempted = $false
    while ((Get-Date) -lt $deadline) {
        $attempt++
        if (-not $script:TftpProcess -or $script:TftpProcess.HasExited) {
            $script:TftpProcess = Start-Process -FilePath $script:TftpExePath -WorkingDirectory (Split-Path -Parent $script:TftpExePath) -PassThru
            Start-Sleep -Seconds 2
        }
        $sshAvailable = Test-NetConnection -ComputerName $Router -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($sshAvailable -and (Test-RemoteNoPasswordAuth)) {
            $script:UseNoPasswordAuth = $true
            try {
                $lastBoard = Invoke-Remote 'ubus call system board'
                if ($lastBoard -match '"rootfs_type"\s*:\s*"initramfs"') { return }
            } catch { $lastBoard = $_.Exception.Message }
        } elseif ($sshAvailable -and $attempt -ge 6 -and -not $interactiveBoardAttempted) {
            $interactiveBoardAttempted = $true
            try {
                $lastBoard = Invoke-Remote 'ubus call system board'
                if ($lastBoard -match '"rootfs_type"\s*:\s*"initramfs"') { return }
            } catch { $lastBoard = $_.Exception.Message }
        }
        if ($attempt % 12 -eq 0) {
            if ($lastBoard -match '"hostname"\s*:\s*"Netis-N6"|21\.02-SNAPSHOT') {
                Write-Host 'По SSH всё ещё отвечает заводская OpenWrt 21.02; это не recovery. Проверьте, появился ли новый TFTP-запрос именно от 192.168.1.1.' -ForegroundColor Yellow
            } else {
                Write-Host "Recovery ещё не загрузилась; продолжаю ждать. Последний ответ: $lastBoard"
            }
        }
        Start-Sleep -Seconds 5
    }
    if ($lastBoard -match '"hostname"\s*:\s*"Netis-N6"|21\.02-SNAPSHOT') {
        throw "Recovery не загрузилась за $TimeoutSeconds секунд; по SSH отвечает заводская OpenWrt. Запись FIP и очистка UBI в этом запуске были подтверждены. Не запускайте полный скрипт повторно и не стирайте UBI ещё раз. Оставьте Tftpd64 включённым. Если после перезагрузки в его журнале нет нового запроса от 192.168.1.1, откройте второе окно PowerShell и один раз выполните: ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o GlobalKnownHostsFile=NUL root@$Router reboot. Следите за журналом. Если роутер снова вернётся в заводскую систему без TFTP-запроса, остановитесь: нужна диагностика загрузчика, возможно UART. Последний ответ: $lastBoard"
    }
    $httpAvailable = Test-NetConnection -ComputerName $Router -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue
    $httpsAvailable = Test-NetConnection -ComputerName $Router -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($httpAvailable -or $httpsAvailable) {
        throw "Веб-интерфейс роутера доступен, но SSH не отвечает. Откройте http://$Router или https://$Router и проверьте Status / Overview: для recovery ожидается rootfs_type=initramfs. Если это recovery, задайте пароль root в System / Administration и убедитесь, что SSH включён, затем запустите этот скрипт снова. Он распознает initramfs, пропустит резервное копирование, запись FIP и очистку UBI, продолжит установку sysupgrade. Не стирайте UBI вручную."
    }
    throw "Recovery не загрузилась за $TimeoutSeconds секунд, SSH от роутера не ответил. Не запускайте полный скрипт повторно и не стирайте UBI ещё раз. Запись от 192.168.1.254 в журнале Tftpd64 — только локальная проверка скрипта; она не подтверждает связь с роутером. Разрешите tftpd64.exe входящие подключения в брандмауэре Windows для Ethernet и проверьте, что сервер привязан к адресу 192.168.1.254. Оставьте Tftpd64 включённым; если роутер не отвечает по SSH, один раз перезапустите питание роутера и следите за новым запросом от 192.168.1.1. Если запроса нет и после этого, остановитесь: нужна диагностика загрузчика, возможно через UART."
}

function Assert-RecoveryRoot {
    $boardJson = Invoke-Remote 'ubus call system board'
    if ($boardJson -notmatch '"rootfs_type"\s*:\s*"initramfs"') { throw "Роутер загрузился не в initramfs recovery: $boardJson" }
}

function Assert-NetisN6V2([string]$BoardInfo) {
    $isOpenWrtN6V2 = $BoardInfo -match '"board_name"\s*:\s*"netis,n6-v2"'
    $isFactoryN6 = $BoardInfo -match '"hostname"\s*:\s*"Netis-N6"' -and
        $BoardInfo -match '"model"\s*:\s*"MediaTek MT7981 RFB"' -and
        $BoardInfo -match 'mediatek,mt7981-spim-snand-rfb'
    if (-not ($isOpenWrtN6V2 -or $isFactoryN6)) {
        throw "Не удалось подтвердить Netis N6 v2 по ожидаемому board_name OpenWrt или заводскому отпечатку Netis-N6/MT7981 RFB. Запись остановлена: $BoardInfo"
    }
    if ($isOpenWrtN6V2) { Write-Host 'Модель подтверждена: netis,n6-v2.' }
    else { Write-Host 'Модель подтверждена по заводскому отпечатку Netis-N6 / MT7981 RFB.' }
}

function Assert-PersistentRoot {
    $boardJson = Invoke-Remote 'ubus call system board'
    if ($boardJson -notmatch '"rootfs_type"\s*:\s*"[^"]+"' -or $boardJson -match '"rootfs_type"\s*:\s*"initramfs"') {
        throw "Не подтверждена постоянная система после sysupgrade: $boardJson"
    }
}

function Test-WindowsOpenSsh {
    $commands = @{}
    foreach ($name in 'ssh','scp') {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) {
            throw "Не найден компонент Windows OpenSSH ($name.exe). Установите Optional Feature 'OpenSSH Client' в Параметрах Windows и запустите сценарий снова."
        }
        $commands[$name] = $command.Source
        Write-Host "[OK] $name`: $($command.Source)"
    }
    $sshPath = $commands['ssh']
    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $sshPath
    $processInfo.Arguments = '-V'
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    if (-not $process.Start()) { throw 'Windows OpenSSH найден, но ssh.exe не запускается.' }
    $version = ($process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()).Trim()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or -not $version) { throw 'Windows OpenSSH найден, но ssh.exe не запускается.' }
    Write-Host "[OK] $version"
}

try {
    if ($Host.Name -match 'ISE') { throw 'Запустите скрипт в обычном Windows PowerShell/Windows Terminal, не в PowerShell ISE (он ненадёжно обрабатывает интерактивный SSH).' }
    Test-WindowsOpenSsh
    $fipPath = Require-Image $Fip
    $recoveryPath = Require-Image $Recovery
    $sysupgradePath = Require-Image $Sysupgrade
    $tftpExe = Get-TftpExecutable
    Prepare-Tftp $tftpExe $recoveryPath
    Test-TftpFile

    Ensure-RemoteAuth
    $initialBoardJson = Invoke-Remote 'ubus call system board 2>/dev/null || true; printf "\n"; tr "\000" "\n" </proc/device-tree/compatible 2>/dev/null || true'
    Assert-NetisN6V2 $initialBoardJson
    $resumeRecovery = $initialBoardJson -match '"rootfs_type"\s*:\s*"initramfs"'
    if ($resumeRecovery) {
        Write-Host 'Уже запущен initramfs recovery: пропускаю резервное копирование и запись FIP/UBI, продолжаю установку sysupgrade.' -ForegroundColor Yellow
    } else {
        $installed = Invoke-Remote 'cat /etc/openwrt_release 2>/dev/null || true'
        if ($installed -match "DISTRIB_RELEASE='25\.12\.6'") {
            Assert-PersistentRoot
            Write-Host 'OpenWrt 25.12.6 уже установлена и проверена. Повторная прошивка не требуется.' -ForegroundColor Green
            $script:FlashCompleted = $true
            return
        }
    }
    if (-not $resumeRecovery) {
    $table = Invoke-Remote 'cat /proc/mtd'
    $parts = @()
    foreach ($line in ($table -split "`n")) {
        if ($line -match '^mtd(\d+):\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+"([^"]+)"') {
            $parts += [pscustomobject]@{ Index = [int]$Matches[1]; Bytes = [Convert]::ToInt64($Matches[2],16); EraseBytes = [Convert]::ToInt64($Matches[3],16); Name = $Matches[4] }
        }
    }
    if (-not $parts.Count) { throw 'Не удалось разобрать /proc/mtd; прошивка остановлена.' }
    Write-Host 'Разметка MTD автоматически не сверяется с эталоном; проверьте, что сохранённые дампы соответствуют вашему устройству.' -ForegroundColor Yellow
    $total = ($parts | Measure-Object Bytes -Sum).Sum
    $drive = Get-PSDrive -PSProvider FileSystem | Where-Object { $WorkDir.StartsWith($_.Root,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if (-not $drive -or $drive.Free -lt ($total + 16MB)) { throw "На диске недостаточно места для дампов: требуется минимум $total байт плюс 16 MiB." }
    $backupDir = Join-Path $WorkDir ("backup_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $backupDir | Out-Null
    Write-Host "Создаю резервные копии $($parts.Count) разделов в $backupDir (суммарный объём $total байт)."
    $manifest = @()
    foreach ($part in $parts) {
        $safe = $part.Name -replace '[^A-Za-z0-9_.-]','_'
        $dump = Join-Path $backupDir ("mtd{0}_{1}.bin" -f $part.Index,$safe)
        Save-Partition $part.Index $dump $part.Bytes
        $manifest += [pscustomobject]@{ Index = $part.Index; Name = $part.Name; Bytes = $part.Bytes; SHA256 = (Get-FileHash -LiteralPath $dump -Algorithm SHA256).Hash.ToLowerInvariant(); File = [IO.Path]::GetFileName($dump) }
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDir 'manifest.json') -Encoding UTF8
    Write-Host "Дампы сохранены и проверены: $backupDir"

    if ($script:UseNoPasswordAuth) {
        Invoke-Native ((Get-Command scp).Source) @('-o','PubkeyAuthentication=no','-o','BatchMode=yes','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','GlobalKnownHostsFile=NUL','-O',$fipPath,"root@${Router}:/tmp/$Fip") | Out-Host
    } else {
        Invoke-Native ((Get-Command scp).Source) @('-o','PubkeyAuthentication=no','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','GlobalKnownHostsFile=NUL','-O',$fipPath,"root@${Router}:/tmp/$Fip") | Out-Host
    }
    if ($script:NativeExitCode -ne 0) { throw 'Передача FIP не удалась; роутер не изменён.' }
    $fipHash = $Images[$Fip].Hash
    $remoteFipHash = Invoke-Remote "sha256sum /tmp/$Fip"
    if ($remoteFipHash -notmatch $fipHash) { throw 'SHA-256 переданного FIP не совпал; запись не выполнялась.' }
    Invoke-Remote "mtd write /tmp/$Fip FIP"
    $readback = Invoke-Remote "dd if=/dev/mtd4ro bs=$($Images[$Fip].Bytes) count=1 2>/dev/null | sha256sum"
    if ($readback -notmatch $fipHash) { throw 'Проверка FIP чтением обратно не прошла; UBI не тронут.' }
    Invoke-Remote 'mtd erase ubi && sync'
    Invoke-Remote 'reboot' -AllowDisconnect | Out-Null

    Wait-ForRecovery 900
    }
    Assert-RecoveryRoot

    if ($script:UseNoPasswordAuth) {
        Invoke-Native ((Get-Command scp).Source) @('-o','PubkeyAuthentication=no','-o','BatchMode=yes','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','GlobalKnownHostsFile=NUL','-O',$sysupgradePath,"root@${Router}:/tmp/$Sysupgrade") | Out-Host
    } else {
        Invoke-Native ((Get-Command scp).Source) @('-o','PubkeyAuthentication=no','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','GlobalKnownHostsFile=NUL','-O',$sysupgradePath,"root@${Router}:/tmp/$Sysupgrade") | Out-Host
    }
    if ($script:NativeExitCode -ne 0) { throw 'Передача sysupgrade не удалась. Recovery оставлена запущенной; повторно FIP/UBI не трогаю.' }
    $remoteSysupgradeHash = Invoke-Remote "sha256sum /tmp/$Sysupgrade"
    if ($remoteSysupgradeHash -notmatch $Images[$Sysupgrade].Hash) { throw 'SHA-256 переданного sysupgrade не совпал; upgrade не запускался.' }
    Invoke-Remote "sysupgrade -T /tmp/$Sysupgrade"
    Invoke-Remote "sysupgrade -n /tmp/$Sysupgrade" -AllowUpgradeDisconnect | Out-Null
    Write-Host 'Sysupgrade принят. SSH отключится во время перезагрузки; жду постоянную OpenWrt.'
    Wait-ForSsh 900 'Ожидаю перезагрузку в установленную OpenWrt (до 15 минут).'
    Assert-PersistentRoot
    $finalRelease = Invoke-Remote 'cat /etc/openwrt_release'
    if ($finalRelease -notmatch "DISTRIB_RELEASE='25\.12\.6'") { throw 'После перезагрузки не подтверждена OpenWrt 25.12.6.' }
    Write-Host 'Завершено: SSH снова доступен после sysupgrade. Задайте root пароль и проверьте сеть.'
    $script:FlashCompleted = $true
}
finally {
    if ($script:FlashCompleted -and $script:TftpProcess -and -not $script:TftpProcess.HasExited) { Stop-Process -Id $script:TftpProcess.Id -Force -ErrorAction SilentlyContinue }
}
