Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
    [Console]::InputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom
}
catch {
}

function Invoke-Netsh {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & netsh @Arguments 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
    }
}

function Escape-XmlText {
    param([string] $Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-TemporaryDirectory {
    $path = Join-Path $env:TEMP ("wifi-switcher-{0}" -f ([guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Get-WlanInterfaces {
    $result = Invoke-Netsh @("wlan", "show", "interfaces")
    if ($result.ExitCode -ne 0) {
        throw "无法读取无线网卡信息。"
    }

    $interfaces = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match "^\s*Name\s*:\s*(.+?)\s*$") {
            [void]$interfaces.Add($Matches[1])
        }
    }

    return $interfaces
}

function Get-WlanConnectionDetails {
    $result = Invoke-Netsh @("wlan", "show", "interfaces")
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            InterfaceName = ""
            State       = ""
            Ssid        = ""
            Profile     = ""
            IsConnected = $false
        }
    }

    $interfaceName = ""
    $state = ""
    $ssid = ""
    $profile = ""
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match "^\s*Name\s*:\s*(.+?)\s*$") {
            $interfaceName = $Matches[1].Trim()
        }
        elseif ($line -match "^\s*State\s*:\s*(.+?)\s*$") {
            $state = $Matches[1].Trim()
        }
        elseif ($line -match "^\s*SSID\s*:\s*(.+?)\s*$") {
            $ssid = $Matches[1].Trim()
        }
        elseif ($line -match "^\s*Profile\s*:\s*(.+?)\s*$") {
            $profile = $Matches[1].Trim()
        }
    }

    return [pscustomobject]@{
        InterfaceName = $interfaceName
        State       = $state
        Ssid        = $ssid
        Profile     = $profile
        IsConnected = $state -match "^\s*connected\s*$"
    }
}

function Get-WlanProfiles {
    $exportDir = New-TemporaryDirectory

    try {
        $result = Invoke-Netsh @("wlan", "export", "profile", "folder=$exportDir")
        if ($result.ExitCode -ne 0) {
            throw "无法读取已保存的 Wi-Fi 配置。"
        }

        $profiles = New-Object System.Collections.Generic.List[object]
        $seen = New-Object "System.Collections.Generic.HashSet[string]"
        foreach ($file in Get-ChildItem -LiteralPath $exportDir -Filter "*.xml") {
            try {
                [xml]$profileXml = Get-Content -LiteralPath $file.FullName -Encoding UTF8
                $name = [string]$profileXml.WLANProfile.name
                $ssid = [string]$profileXml.WLANProfile.SSIDConfig.SSID.name
                $nonBroadcast = ([string]$profileXml.WLANProfile.SSIDConfig.nonBroadcast) -eq "true"

                if ($name -and $seen.Add($name)) {
                    [void]$profiles.Add([pscustomobject]@{
                        Name           = $name
                        Ssid           = if ($ssid) { $ssid } else { $name }
                        IsHidden       = $nonBroadcast
                        Authentication = [string]$profileXml.WLANProfile.MSM.security.authEncryption.authentication
                        Encryption     = [string]$profileXml.WLANProfile.MSM.security.authEncryption.encryption
                    })
                }
            }
            catch {
                Write-Log "跳过无法读取的 Wi-Fi 配置文件：$($file.Name)"
            }
        }

        return $profiles | Sort-Object -Property Name
    }
    finally {
        Remove-Item -LiteralPath $exportDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-WlanProfilesFast {
    $result = Invoke-Netsh @("wlan", "show", "profiles")
    if ($result.ExitCode -ne 0) {
        throw "无法快速读取已保存的 Wi-Fi 配置。"
    }

    $profiles = New-Object System.Collections.Generic.List[object]
    $seen = New-Object "System.Collections.Generic.HashSet[string]"
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match "^\s*(?:All User Profile|Current User Profile|所有用户配置文件|当前用户配置文件)\s*:\s*(.+?)\s*$") {
            $name = $Matches[1].Trim()
            if ($name -and $seen.Add($name)) {
                [void]$profiles.Add([pscustomobject]@{
                    Name           = $name
                    Ssid           = $name
                    IsHidden       = $false
                    Authentication = ""
                    Encryption     = ""
                })
            }
        }
    }

    return $profiles | Sort-Object -Property Name
}

function Test-WifiConnectionMatch {
    param(
        [object] $Details,
        [string] $Name,
        [string] $Ssid
    )

    if (-not $Details -or -not $Details.IsConnected) {
        return $false
    }

    return (
        $Details.Profile -eq $Name -or
        $Details.Profile -eq $Ssid -or
        $Details.Ssid -eq $Ssid -or
        $Details.Ssid -eq $Name
    )
}

function Get-AvailableWifiScan {
    $names = New-Object System.Collections.Generic.List[string]
    $hiddenCount = 0
    $result = Invoke-Netsh @("wlan", "show", "networks", "mode=bssid")

    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            Names       = @()
            HiddenCount = 0
            Error       = "无法扫描当前可用 Wi-Fi。"
        }
    }

    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match "^\s*SSID\s+\d+\s*:\s*(.*)\s*$") {
            $ssid = $Matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($ssid)) {
                $hiddenCount++
            }
            elseif (-not $names.Contains($ssid)) {
                [void]$names.Add($ssid)
            }
        }
    }

    return [pscustomobject]@{
        Names       = @($names)
        HiddenCount = $hiddenCount
        Error       = $null
    }
}

function Get-CurrentConnection {
    try {
        $details = Get-WlanConnectionDetails
        if ($details -and $details.IsConnected) {
            $name = if ($details.Ssid) { $details.Ssid } elseif ($details.Profile) { $details.Profile } else { "Wi-Fi" }
            return "当前连接：$name"
        }
    }
    catch {
        return "当前状态：未知"
    }

    return "当前状态：未连接"
}

function New-HiddenWifiProfileXml {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Ssid,
        [Parameter(Mandatory = $true)]
        [string] $Password,
        [Parameter(Mandatory = $true)]
        [ValidateSet("WPA2PSK", "WPAPSK", "WPA3SAE")]
        [string] $Authentication,
        [Parameter(Mandatory = $true)]
        [ValidateSet("AES", "TKIP")]
        [string] $Encryption,
        [bool] $AutoConnect
    )

    $ssidEscaped = Escape-XmlText $Ssid
    $passwordEscaped = Escape-XmlText $Password
    $connectionMode = if ($AutoConnect) { "auto" } else { "manual" }

    return @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$ssidEscaped</name>
    <SSIDConfig>
        <SSID>
            <name>$ssidEscaped</name>
        </SSID>
        <nonBroadcast>true</nonBroadcast>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>$connectionMode</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>$Authentication</authentication>
                <encryption>$Encryption</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$passwordEscaped</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>
"@
}

function Add-HiddenWifiProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Ssid,
        [Parameter(Mandatory = $true)]
        [string] $Password,
        [Parameter(Mandatory = $true)]
        [string] $Authentication,
        [Parameter(Mandatory = $true)]
        [string] $Encryption,
        [bool] $AutoConnect
    )

    $xml = New-HiddenWifiProfileXml -Ssid $Ssid -Password $Password -Authentication $Authentication -Encryption $Encryption -AutoConnect $AutoConnect
    $tempPath = Join-Path $env:TEMP ("wifi-profile-{0}.xml" -f ([guid]::NewGuid().ToString("N")))

    try {
        Set-Content -LiteralPath $tempPath -Value $xml -Encoding UTF8
        $result = Invoke-Netsh @("wlan", "add", "profile", "filename=$tempPath", "user=current")
        if ($result.ExitCode -ne 0) {
            throw "添加 Wi-Fi 配置失败。请确认 SSID、密码、安全类型和加密方式是否正确。"
        }
        return $result.Output
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WifiConnectRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Ssid,
        [string] $InterfaceName = ""
    )

    $arguments = @("wlan", "connect", "name=$Name", "ssid=$Ssid")
    if ($InterfaceName) {
        $arguments += "interface=$InterfaceName"
    }
    else {
        $interfaces = Get-WlanInterfaces
        if ($interfaces.Count -gt 0) {
            $arguments += "interface=$($interfaces[0])"
        }
    }

    $result = Invoke-Netsh $arguments

    if ($result.ExitCode -ne 0) {
        throw "发起连接 '$Name' 失败。可能原因：这个 Wi-Fi 当前不在可用范围内、隐藏网络未被扫描到、密码或安全类型不匹配，或保存的配置已失效。"
    }

    return $result.Output
}

function Disconnect-Wifi {
    $result = Invoke-Netsh @("wlan", "disconnect")
    if ($result.ExitCode -ne 0) {
        throw "断开 Wi-Fi 失败。"
    }
    return $result.Output
}

function Delete-WifiProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $result = Invoke-Netsh @("wlan", "delete", "profile", "name=$Name")
    if ($result.ExitCode -ne 0) {
        throw "删除 '$Name' 失败。请点击刷新后确认这个配置是否仍然存在。"
    }

    return $result.Output
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Wi-Fi 切换器"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(640, 620)
$form.MinimumSize = New-Object System.Drawing.Size(560, 520)
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#F3F6F4")
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$colorSurface = [System.Drawing.ColorTranslator]::FromHtml("#FFFFFF")
$colorInk = [System.Drawing.ColorTranslator]::FromHtml("#17231B")
$colorMuted = [System.Drawing.ColorTranslator]::FromHtml("#66736A")
$colorAccent = [System.Drawing.ColorTranslator]::FromHtml("#0F6B4D")
$colorAccentSoft = [System.Drawing.ColorTranslator]::FromHtml("#E3F4ED")
$colorBlue = [System.Drawing.ColorTranslator]::FromHtml("#1E5B8F")
$colorAmber = [System.Drawing.ColorTranslator]::FromHtml("#9A5A00")
$colorDanger = [System.Drawing.ColorTranslator]::FromHtml("#A23A32")

function Set-ActionButtonStyle {
    param(
        [System.Windows.Forms.Button] $Button,
        [System.Drawing.Color] $BackColor
    )

    $Button.Width = 122
    $Button.Height = 34
    $Button.FlatStyle = "Flat"
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = $BackColor
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $Button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $Button.UseVisualStyleBackColor = $false
}

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = "Fill"
$mainLayout.ColumnCount = 1
$mainLayout.RowCount = 6
$mainLayout.Padding = New-Object System.Windows.Forms.Padding(16)
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 48))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 172))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 96))) | Out-Null
$form.Controls.Add($mainLayout)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = "Fill"
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11, [System.Drawing.FontStyle]::Bold)
$statusLabel.TextAlign = "MiddleLeft"
$statusLabel.Padding = New-Object System.Windows.Forms.Padding(14, 0, 14, 0)
$statusLabel.BackColor = $colorAccent
$statusLabel.ForeColor = [System.Drawing.Color]::White
$mainLayout.Controls.Add($statusLabel, 0, 0)

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Dock = "Fill"
$hintLabel.TextAlign = "MiddleLeft"
$hintLabel.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)
$hintLabel.BackColor = $colorAccentSoft
$hintLabel.ForeColor = $colorMuted
$hintLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$hintLabel.Text = "启动为快速加载：列表先显示已保存 Wi-Fi；点击[刷新]才会扫描当前可用状态。"
$mainLayout.Controls.Add($hintLabel, 0, 1)

$profileList = New-Object System.Windows.Forms.ListBox
$profileList.Dock = "Fill"
$profileList.Font = New-Object System.Drawing.Font("Segoe UI", 10.5)
$profileList.DisplayMember = "Display"
$profileList.BackColor = $colorSurface
$profileList.ForeColor = $colorInk
$profileList.BorderStyle = "FixedSingle"
$profileList.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$profileList.ItemHeight = 30
$profileList.IntegralHeight = $false
$mainLayout.Controls.Add($profileList, 0, 2)

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Dock = "Fill"
$buttonPanel.FlowDirection = "LeftToRight"
$buttonPanel.WrapContents = $false
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$buttonPanel.BackColor = $form.BackColor
$mainLayout.Controls.Add($buttonPanel, 0, 3)

$connectButton = New-Object System.Windows.Forms.Button
$connectButton.Text = "连接"
Set-ActionButtonStyle -Button $connectButton -BackColor $colorAccent
$buttonPanel.Controls.Add($connectButton)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "刷新"
Set-ActionButtonStyle -Button $refreshButton -BackColor $colorBlue
$buttonPanel.Controls.Add($refreshButton)

$disconnectButton = New-Object System.Windows.Forms.Button
$disconnectButton.Text = "断开"
Set-ActionButtonStyle -Button $disconnectButton -BackColor $colorAmber
$buttonPanel.Controls.Add($disconnectButton)

$deleteButton = New-Object System.Windows.Forms.Button
$deleteButton.Text = "删除配置"
Set-ActionButtonStyle -Button $deleteButton -BackColor $colorDanger
$buttonPanel.Controls.Add($deleteButton)

$script:PendingConnection = $null
$connectionTimer = New-Object System.Windows.Forms.Timer
$connectionTimer.Interval = 500

$hiddenGroup = New-Object System.Windows.Forms.GroupBox
$hiddenGroup.Text = "添加隐藏 Wi-Fi"
$hiddenGroup.Dock = "Fill"
$hiddenGroup.Padding = New-Object System.Windows.Forms.Padding(12)
$hiddenGroup.BackColor = $colorSurface
$hiddenGroup.ForeColor = $colorInk
$hiddenGroup.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
$mainLayout.Controls.Add($hiddenGroup, 0, 4)

$hiddenLayout = New-Object System.Windows.Forms.TableLayoutPanel
$hiddenLayout.Dock = "Fill"
$hiddenLayout.ColumnCount = 4
$hiddenLayout.RowCount = 4
$hiddenLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 76))) | Out-Null
$hiddenLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$hiddenLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 96))) | Out-Null
$hiddenLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$hiddenLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32))) | Out-Null
$hiddenLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32))) | Out-Null
$hiddenLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32))) | Out-Null
$hiddenLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36))) | Out-Null
$hiddenLayout.BackColor = $colorSurface
$hiddenGroup.Controls.Add($hiddenLayout)

$ssidLabel = New-Object System.Windows.Forms.Label
$ssidLabel.Text = "SSID"
$ssidLabel.Dock = "Fill"
$ssidLabel.TextAlign = "MiddleLeft"
$ssidLabel.ForeColor = $colorMuted
$hiddenLayout.Controls.Add($ssidLabel, 0, 0)

$ssidText = New-Object System.Windows.Forms.TextBox
$ssidText.Dock = "Fill"
$ssidText.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$hiddenLayout.Controls.Add($ssidText, 1, 0)
$hiddenLayout.SetColumnSpan($ssidText, 3)

$passwordLabel = New-Object System.Windows.Forms.Label
$passwordLabel.Text = "密码"
$passwordLabel.Dock = "Fill"
$passwordLabel.TextAlign = "MiddleLeft"
$passwordLabel.ForeColor = $colorMuted
$hiddenLayout.Controls.Add($passwordLabel, 0, 1)

$passwordText = New-Object System.Windows.Forms.TextBox
$passwordText.Dock = "Fill"
$passwordText.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$passwordText.UseSystemPasswordChar = $true
$hiddenLayout.Controls.Add($passwordText, 1, 1)
$hiddenLayout.SetColumnSpan($passwordText, 3)

$authLabel = New-Object System.Windows.Forms.Label
$authLabel.Text = "安全类型"
$authLabel.Dock = "Fill"
$authLabel.TextAlign = "MiddleLeft"
$authLabel.ForeColor = $colorMuted
$hiddenLayout.Controls.Add($authLabel, 0, 2)

$authCombo = New-Object System.Windows.Forms.ComboBox
$authCombo.Dock = "Fill"
$authCombo.DropDownStyle = "DropDownList"
$authCombo.FlatStyle = "Flat"
[void]$authCombo.Items.Add("WPA2PSK")
[void]$authCombo.Items.Add("WPAPSK")
[void]$authCombo.Items.Add("WPA3SAE")
$authCombo.SelectedItem = "WPA2PSK"
$hiddenLayout.Controls.Add($authCombo, 1, 2)

$encLabel = New-Object System.Windows.Forms.Label
$encLabel.Text = "加密方式"
$encLabel.Dock = "Fill"
$encLabel.TextAlign = "MiddleLeft"
$encLabel.ForeColor = $colorMuted
$hiddenLayout.Controls.Add($encLabel, 2, 2)

$encCombo = New-Object System.Windows.Forms.ComboBox
$encCombo.Dock = "Fill"
$encCombo.DropDownStyle = "DropDownList"
$encCombo.FlatStyle = "Flat"
[void]$encCombo.Items.Add("AES")
[void]$encCombo.Items.Add("TKIP")
$encCombo.SelectedItem = "AES"
$hiddenLayout.Controls.Add($encCombo, 3, 2)

$autoConnectCheck = New-Object System.Windows.Forms.CheckBox
$autoConnectCheck.Text = "自动连接"
$autoConnectCheck.Checked = $true
$autoConnectCheck.Dock = "Fill"
$autoConnectCheck.ForeColor = $colorInk
$hiddenLayout.Controls.Add($autoConnectCheck, 1, 3)

$addHiddenButton = New-Object System.Windows.Forms.Button
$addHiddenButton.Text = "添加/更新"
$addHiddenButton.Dock = "Fill"
Set-ActionButtonStyle -Button $addHiddenButton -BackColor $colorAccent
$hiddenLayout.Controls.Add($addHiddenButton, 3, 3)

$logText = New-Object System.Windows.Forms.TextBox
$logText.Dock = "Fill"
$logText.Multiline = $true
$logText.ReadOnly = $true
$logText.ScrollBars = "Vertical"
$logText.Font = New-Object System.Drawing.Font("Consolas", 9)
$logText.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#0F1712")
$logText.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#DDEBE3")
$logText.BorderStyle = "FixedSingle"
$mainLayout.Controls.Add($logText, 0, 5)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 8000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay = 200
$toolTip.SetToolTip($profileList, "启动时不扫描周围 Wi-Fi，只列出保存过的配置。点击刷新后会按可用/隐藏/未扫描到分组。")
$toolTip.SetToolTip($refreshButton, "扫描当前可用 Wi-Fi，并重新按状态分组。配置较多时会比启动加载慢。")
$toolTip.SetToolTip($connectButton, "向 Windows 发送连接请求，后台确认连接结果。")

function Write-Log {
    param([string] $Message)

    $time = Get-Date -Format "HH:mm:ss"
    $logText.AppendText("[$time] $Message`r`n")
}

function New-ProfileListItem {
    param(
        [string] $Display,
        [object] $Profile,
        [bool] $IsHeader = $false,
        [string] $Status = ""
    )

    return [pscustomobject]@{
        Display  = $Display
        Profile  = $Profile
        IsHeader = $IsHeader
        Status   = $Status
    }
}

$profileList.Add_DrawItem({
    param($sender, $e)

    if ($e.Index -lt 0) {
        return
    }

    $item = $sender.Items[$e.Index]
    $isSelected = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -eq [System.Windows.Forms.DrawItemState]::Selected)
    $backColor = if ($isSelected) { $colorAccent } else { $colorSurface }
    $foreColor = if ($isSelected) { [System.Drawing.Color]::White } else { $colorInk }
    $font = $sender.Font

    if ($item.IsHeader) {
        $backColor = if ($isSelected) { $colorAccent } else { $colorAccentSoft }
        $foreColor = if ($isSelected) { [System.Drawing.Color]::White } else { $colorAccent }
        $font = New-Object System.Drawing.Font($sender.Font, [System.Drawing.FontStyle]::Bold)
    }
    elseif (-not $isSelected) {
        if ($item.Status -eq "available") {
            $foreColor = $colorAccent
        }
        elseif ($item.Status -eq "hidden-or-unknown") {
            $foreColor = $colorAmber
        }
        elseif ($item.Status -eq "unavailable") {
            $foreColor = $colorMuted
        }
    }

    $backgroundBrush = New-Object System.Drawing.SolidBrush($backColor)
    $textBrush = New-Object System.Drawing.SolidBrush($foreColor)
    try {
        $e.Graphics.FillRectangle($backgroundBrush, $e.Bounds)
        $textBounds = New-Object System.Drawing.Rectangle(($e.Bounds.Left + 10), ($e.Bounds.Top + 5), ($e.Bounds.Width - 20), ($e.Bounds.Height - 8))
        [System.Windows.Forms.TextRenderer]::DrawText(
            $e.Graphics,
            [string]$item.Display,
            $font,
            $textBounds,
            $foreColor,
            ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis)
        )
        if ($isSelected) {
            $e.DrawFocusRectangle()
        }
    }
    finally {
        $backgroundBrush.Dispose()
        $textBrush.Dispose()
        if ($item.IsHeader -and $font -ne $sender.Font) {
            $font.Dispose()
        }
    }
})

function Get-SelectedProfileItem {
    $item = $profileList.SelectedItem
    if (-not $item -or $item.IsHeader -or -not $item.Profile) {
        return $null
    }

    return $item
}

function Select-ProfileByName {
    param([string] $Name)

    foreach ($item in $profileList.Items) {
        if (-not $item.IsHeader -and $item.Profile -and $item.Profile.Name -eq $Name) {
            $profileList.SelectedItem = $item
            return
        }
    }
}

function Add-ProfileSection {
    param(
        [string] $Title,
        [object[]] $Profiles,
        [string] $Status
    )

    if (-not $Profiles -or $Profiles.Count -eq 0) {
        return
    }

    [void]$profileList.Items.Add((New-ProfileListItem -Display $Title -IsHeader $true))
    foreach ($profile in ($Profiles | Sort-Object -Property Name)) {
        $label = if ($profile.IsHidden) { "$($profile.Name)    [隐藏]" } else { $profile.Name }
        [void]$profileList.Items.Add((New-ProfileListItem -Display "  $label" -Profile $profile -Status $Status))
    }
}

function Restore-SelectedProfile {
    param([string] $SelectedName)

    if (-not $SelectedName) {
        return
    }

    foreach ($item in $profileList.Items) {
        if (-not $item.IsHeader -and $item.Profile -and $item.Profile.Name -eq $SelectedName) {
            $profileList.SelectedItem = $item
            break
        }
    }
}

function Refresh-Profiles {
    param([switch] $Fast)

    try {
        $statusLabel.Text = Get-CurrentConnection
        $selectedItem = Get-SelectedProfileItem
        $selectedName = if ($selectedItem) { $selectedItem.Profile.Name } else { $null }
        $profileList.Items.Clear()

        if ($Fast) {
            $profiles = @(Get-WlanProfilesFast)
            Add-ProfileSection -Title "== 已保存 Wi-Fi ==" -Profiles $profiles -Status "available"

            if ($profileList.Items.Count -eq 0) {
                [void]$profileList.Items.Add((New-ProfileListItem -Display "没有找到已保存的 Wi-Fi 配置" -IsHeader $true))
            }

            Restore-SelectedProfile -SelectedName $selectedName
            $hintLabel.Text = "快速加载：这里只列出保存过的 Wi-Fi。点击[刷新]后会扫描当前可用状态并重新分组。"
            Write-Log "快速加载完成：已保存 $($profiles.Count) 个。点击刷新可扫描可用状态。"
            return
        }

        $profiles = @(Get-WlanProfiles)
        $scan = Get-AvailableWifiScan
        $availableNames = New-Object "System.Collections.Generic.HashSet[string]"
        foreach ($name in $scan.Names) {
            [void]$availableNames.Add($name)
        }

        $available = @($profiles | Where-Object { $availableNames.Contains($_.Ssid) -or $availableNames.Contains($_.Name) })
        $availableProfileNames = New-Object "System.Collections.Generic.HashSet[string]"
        foreach ($profile in $available) {
            [void]$availableProfileNames.Add($profile.Name)
        }

        $hiddenOrUnknown = @($profiles | Where-Object { -not $availableProfileNames.Contains($_.Name) -and $_.IsHidden })
        $unavailable = @($profiles | Where-Object { -not $availableProfileNames.Contains($_.Name) -and -not $_.IsHidden })

        Add-ProfileSection -Title "== 可用的已保存 Wi-Fi ==" -Profiles $available -Status "available"
        Add-ProfileSection -Title "== 隐藏/未确认的已保存 Wi-Fi ==" -Profiles $hiddenOrUnknown -Status "hidden-or-unknown"
        Add-ProfileSection -Title "== 暂未扫描到的已保存 Wi-Fi ==" -Profiles $unavailable -Status "unavailable"

        if ($profileList.Items.Count -eq 0) {
            [void]$profileList.Items.Add((New-ProfileListItem -Display "没有找到已保存的 Wi-Fi 配置" -IsHeader $true))
        }

        Restore-SelectedProfile -SelectedName $selectedName

        $hiddenScanText = if ($scan.HiddenCount -gt 0) { "，另扫描到 $($scan.HiddenCount) 个隐藏网络" } else { "" }
        if ($scan.Error) {
            $hintLabel.Text = "已加载保存配置，但当前可用 Wi-Fi 扫描失败；仍可尝试连接已保存网络。"
            Write-Log "Wi-Fi 列表已刷新，但扫描可用 Wi-Fi 失败。"
        }
        else {
            $hintLabel.Text = "已完成扫描：列表已按可用、隐藏/未确认、暂未扫描到分组。"
            Write-Log "Wi-Fi 列表已刷新：可用 $($available.Count) 个，隐藏/未确认 $($hiddenOrUnknown.Count) 个，暂未扫描到 $($unavailable.Count) 个$hiddenScanText。"
        }
    }
    catch {
        Write-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Wi-Fi 切换器", "OK", "Error") | Out-Null
    }
}

$connectionTimer.Add_Tick({
    if (-not $script:PendingConnection) {
        $connectionTimer.Stop()
        $connectButton.Enabled = $true
        $refreshButton.Enabled = $true
        return
    }

    try {
        $pending = $script:PendingConnection
        $details = Get-WlanConnectionDetails
        if (Test-WifiConnectionMatch -Details $details -Name $pending.Name -Ssid $pending.Ssid) {
            $connectionTimer.Stop()
            $script:PendingConnection = $null
            $connectedName = if ($details.Ssid) { $details.Ssid } else { $pending.Name }
            Write-Log "连接成功：$connectedName"
            $statusLabel.Text = Get-CurrentConnection
            $connectButton.Enabled = $true
            $refreshButton.Enabled = $true
            return
        }

        if ((Get-Date) -ge $pending.Deadline) {
            $connectionTimer.Stop()
            $script:PendingConnection = $null
            $current = if ($details -and $details.Ssid) { $details.Ssid } elseif ($details -and $details.Profile) { $details.Profile } else { "未连接" }
            $message = "连接 '$($pending.Name)' 超时，当前仍是：$current。请确认信号范围、密码和安全类型；如果这是隐藏 Wi-Fi，请先靠近热点后点击刷新再连接，必要时先点击断开。"
            Write-Log $message
            $statusLabel.Text = Get-CurrentConnection
            $connectButton.Enabled = $true
            $refreshButton.Enabled = $true
            [System.Windows.Forms.MessageBox]::Show($message, "Wi-Fi 切换器", "OK", "Error") | Out-Null
        }
    }
    catch {
        $connectionTimer.Stop()
        $script:PendingConnection = $null
        $connectButton.Enabled = $true
        $refreshButton.Enabled = $true
        Write-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Wi-Fi 切换器", "OK", "Error") | Out-Null
    }
})

$connectButton.Add_Click({
    $item = Get-SelectedProfileItem
    if (-not $item) {
        [System.Windows.Forms.MessageBox]::Show("请先选择一个已保存的 Wi-Fi。", "Wi-Fi 切换器", "OK", "Information") | Out-Null
        return
    }

    try {
        $name = [string]$item.Profile.Name
        $ssid = [string]$item.Profile.Ssid
        if (-not $ssid) {
            $ssid = $name
        }

        $details = Get-WlanConnectionDetails
        if (Test-WifiConnectionMatch -Details $details -Name $name -Ssid $ssid) {
            $connectedName = if ($details.Ssid) { $details.Ssid } else { $name }
            Write-Log "已连接：$connectedName"
            $statusLabel.Text = Get-CurrentConnection
            return
        }

        Write-Log "正在连接 $name..."
        $connectButton.Enabled = $false
        $refreshButton.Enabled = $false
        [void](Invoke-WifiConnectRequest -Name $name -Ssid $ssid -InterfaceName $details.InterfaceName)
        $script:PendingConnection = [pscustomobject]@{
            Name     = $name
            Ssid     = $ssid
            Deadline = (Get-Date).AddSeconds(12)
        }
        $statusLabel.Text = "正在连接：$name"
        $connectionTimer.Stop()
        $connectionTimer.Start()
        Write-Log "已发送连接请求：$name"
    }
    catch {
        $script:PendingConnection = $null
        $connectionTimer.Stop()
        $connectButton.Enabled = $true
        $refreshButton.Enabled = $true
        Write-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Wi-Fi 切换器", "OK", "Error") | Out-Null
    }
})

$profileList.Add_DoubleClick({
    $connectButton.PerformClick()
})

$refreshButton.Add_Click({
    Refresh-Profiles
})

$disconnectButton.Add_Click({
    try {
        $script:PendingConnection = $null
        $connectionTimer.Stop()
        $connectButton.Enabled = $true
        $refreshButton.Enabled = $true
        Write-Log "正在断开 Wi-Fi..."
        [void](Disconnect-Wifi)
        Write-Log "已发送断开请求。"
        Start-Sleep -Milliseconds 500
        $statusLabel.Text = Get-CurrentConnection
    }
    catch {
        Write-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Wi-Fi 切换器", "OK", "Error") | Out-Null
    }
})

$deleteButton.Add_Click({
    $item = Get-SelectedProfileItem
    if (-not $item) {
        [System.Windows.Forms.MessageBox]::Show("请先选择一个要删除的 Wi-Fi 配置。", "Wi-Fi 切换器", "OK", "Information") | Out-Null
        return
    }

    $name = [string]$item.Profile.Name
    $confirm = [System.Windows.Forms.MessageBox]::Show("确定要删除 '$name' 的保存配置吗？`r`n删除后需要重新输入密码才能再次保存。", "确认删除", "YesNo", "Warning")
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        Write-Log "正在删除 Wi-Fi 配置：$name..."
        [void](Delete-WifiProfile -Name $name)
        Write-Log "已删除 Wi-Fi 配置：$name"
        Refresh-Profiles
        $statusLabel.Text = Get-CurrentConnection
    }
    catch {
        Write-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Wi-Fi 切换器", "OK", "Error") | Out-Null
    }
})

$addHiddenButton.Add_Click({
    $ssid = $ssidText.Text.Trim()
    $password = $passwordText.Text

    if (-not $ssid) {
        [System.Windows.Forms.MessageBox]::Show("请输入隐藏 Wi-Fi 的 SSID。", "Wi-Fi 切换器", "OK", "Information") | Out-Null
        return
    }
    if (-not $password) {
        [System.Windows.Forms.MessageBox]::Show("请输入 Wi-Fi 密码。", "Wi-Fi 切换器", "OK", "Information") | Out-Null
        return
    }

    try {
        Write-Log "正在添加隐藏 Wi-Fi：$ssid..."
        [void](Add-HiddenWifiProfile -Ssid $ssid -Password $password -Authentication ([string]$authCombo.SelectedItem) -Encryption ([string]$encCombo.SelectedItem) -AutoConnect $autoConnectCheck.Checked)
        Write-Log "已添加/更新隐藏 Wi-Fi：$ssid"
        $passwordText.Clear()
        Refresh-Profiles
        Select-ProfileByName -Name $ssid
    }
    catch {
        Write-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Wi-Fi 切换器", "OK", "Error") | Out-Null
    }
})

$form.Add_Shown({
    Refresh-Profiles -Fast
})

[void][System.Windows.Forms.Application]::Run($form)
