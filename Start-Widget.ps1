# Begin Tokscale Monitor Desktop Widget
#Requires -Version 5.1

param(
    [int]$Interval = 3
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Windows.Forms

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$monitorScript = Join-Path $scriptDir 'monitor.mjs'
$port = 8899
$endpoint = "http://127.0.0.1:$port/stats"
$script:nodeProc = $null

function Format-Token([double]$n) {
    if ($n -lt 0) { $n = 0 }
    if ($n -ge 1e12) { return ('{0:0.00}万亿' -f ($n / 1e12)) }
    if ($n -ge 1e8)  { return ('{0:0.00}亿'   -f ($n / 1e8)) }
    if ($n -ge 1e4)  { return ('{0:0.00}万'   -f ($n / 1e4)) }
    return ('{0:N0}'  -f $n)
}

function Test-ExistingServer {
    try {
        $c = New-Object System.Net.Http.HttpClient
        $c.Timeout = [TimeSpan]::FromSeconds(3)
        $null = $c.GetStringAsync($endpoint).GetAwaiter().GetResult()
        return $true
    } catch { return $false }
}

function Start-MonitorBackend {
    if (Test-ExistingServer) { return }
    $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeExe) {
        foreach ($p in @('C:\Program Files\nodejs\node.exe', 'C:\Program Files (x86)\nodejs\node.exe')) {
            if (Test-Path $p) { $nodeExe = $p; break }
        }
    }
    if (-not $nodeExe) { throw '未找到 node.exe，请先安装 Node.js（nodejs.org）' }
    $script:nodeProc = Start-Process -FilePath $nodeExe `
        -ArgumentList @('--no-warnings', $monitorScript) `
        -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-ExistingServer) { break }
        Start-Sleep -Milliseconds 300
    }
}

# ---------- XAML ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="348" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" SizeToContent="Height" ResizeMode="NoResize"
        Opacity="0.97" UseLayoutRounding="True" FontFamily="Microsoft YaHei UI">
  <Border Name="Card" Background="#F5111318" CornerRadius="14" BorderBrush="#40222A3A" BorderThickness="1" Padding="16,12,16,12">
    <StackPanel>
      <DockPanel>
        <TextBlock Text="Token 实时监控" FontSize="13" FontWeight="Bold" Foreground="#E8EEFF"/>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" HorizontalAlignment="Right">
          <Ellipse Name="StatusDot" Width="8" Height="8" Fill="#4CD964" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <TextBlock Name="StatusText" Text="实时" FontSize="11" Foreground="#9FB3D9"/>
        </StackPanel>
      </DockPanel>

      <TextBlock Text="今日累计" FontSize="10" Foreground="#7A8BB0" Margin="0,10,0,0"/>
      <TextBlock Name="TodayTotal" Text="…" FontSize="26" FontWeight="Bold" Foreground="#FFFFFF"/>
      <TextBlock Name="TodayBreakdown" Text="输入 0 · 输出 0 · 缓存读 0" FontSize="10.5" Foreground="#A6B6D6" Margin="0,2,0,0"/>

      <Border Background="#1B2A4A" CornerRadius="8" Padding="10,7,10,7" Margin="0,10,0,0">
        <StackPanel>
          <TextBlock Name="BestLabel" Text="今日最强模型" FontSize="9" Foreground="#8FE3C6"/>
          <TextBlock Name="BestName" Text="—" FontSize="13" FontWeight="Bold" Foreground="#FFF3B0" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
          <TextBlock Name="BestMeta" Text="" FontSize="9.5" Foreground="#A9B9D8" Margin="0,2,0,0"/>
        </StackPanel>
      </Border>

      <DockPanel Margin="0,10,0,0">
        <TextBlock Text="最近60秒" FontSize="10.5" Foreground="#7A8BB0" DockPanel.Dock="Left"/>
        <TextBlock Name="RollingText" Text="+0 tokens" FontSize="10.5" Foreground="#9EE6A3" TextAlignment="Right" DockPanel.Dock="Right"/>
      </DockPanel>
      <DockPanel Margin="0,3,0,0">
        <TextBlock Name="SessionTitle" Text="当前会话：加载中…" FontSize="10.5" Foreground="#C6D3EA" TextTrimming="CharacterEllipsis" DockPanel.Dock="Left" MaxWidth="200"/>
        <TextBlock Name="CostText" Text="今日成本 $0.00" FontSize="10.5" Foreground="#FFD54F" TextAlignment="Right" DockPanel.Dock="Right"/>
      </DockPanel>

      <TextBlock Name="DetailBlock" Text="" FontSize="9.5" Foreground="#9FB3D9" TextWrapping="Wrap" Visibility="Collapsed" Margin="0,10,0,0"/>
      <TextBlock Name="Footer" Text="上次刷新 --:--:-- · 双击切换详情 · 右键菜单" FontSize="9" Foreground="#5B6B8F" Margin="0,10,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($xaml)
foreach ($n in @('Card','StatusDot','StatusText','TodayTotal','TodayBreakdown','BestLabel','BestName','BestMeta','RollingText','SessionTitle','CostText','DetailBlock','Footer')) {
    Set-Variable -Name $n -Value $window.FindName($n)
}

$work = [System.Windows.SystemParameters]::WorkArea
$window.Left = $work.Right - $window.Width - 18
$window.Top = $work.Bottom - $window.Height - 18

# ---------- context menu ----------
# timer created up-front so menu handlers can always resolve it
$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromSeconds($Interval)
$script:timer.Add_Tick({ Refresh-Stats })

$menu = New-Object System.Windows.Controls.ContextMenu

$miIntervalHeader = New-Object System.Windows.Controls.MenuItem
$miIntervalHeader.Header = '刷新间隔'
$menu.Items.Add($miIntervalHeader) | Out-Null
foreach ($iv in @(2, 3, 5, 10, 30)) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = ("{0} 秒" -f $iv)
    $mi.IsChecked = ($iv -eq $Interval)
    $mi.Tag = $iv
    $mi.Add_Click({
        param($sender, $e)
        $sec = [int]$sender.Tag
        $script:timer.Stop()
        $script:timer.Interval = [TimeSpan]::FromSeconds($sec)
        $script:timer.Start()
    })
    $miIntervalHeader.Items.Add($mi) | Out-Null
}

$miTopmost = New-Object System.Windows.Controls.MenuItem
$miTopmost.Header = '窗口置顶'; $miTopmost.IsChecked = $true
$miTopmost.Add_Click({ $window.Topmost = -not $window.Topmost; $miTopmost.IsChecked = $window.Topmost })

$miTopmost2 = $miTopmost
$miReport = New-Object System.Windows.Controls.MenuItem
$miReport.Header = '保存今日明细报表'
$miReport.Add_Click({ Save-DetailReport })

$miCopy = New-Object System.Windows.Controls.MenuItem
$miCopy.Header = '复制今日摘要'
$miCopy.Add_Click({ if ($script:lastStats) { $script:lastStats | ConvertTo-Json -Depth 8 | Set-Clipboard } })

$miRestart = New-Object System.Windows.Controls.MenuItem
$miRestart.Header = '重启监测后端'
$miRestart.Add_Click({
    if ($script:nodeProc -and -not $script:nodeProc.HasExited) { Stop-Process -Id $script:nodeProc.Id -Force -ErrorAction SilentlyContinue }
    $script:nodeProc = $null
    Start-MonitorBackend
})

$miExit = New-Object System.Windows.Controls.MenuItem
$miExit.Header = '退出'
$miExit.Add_Click({ $window.Close() })
$menu.Items.Add($miTopmost) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miReport) | Out-Null
$menu.Items.Add($miCopy) | Out-Null
$menu.Items.Add($miRestart) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($miExit) | Out-Null
$window.ContextMenu = $menu

# ---------- interaction ----------
$script:dbl = [System.Diagnostics.Stopwatch]::StartNew()
function Toggle-Detail {
    if ($DetailBlock.Visibility -eq 'Visible') {
        $DetailBlock.Visibility = 'Collapsed'
        $script:detailOn = $false
    } else {
        $DetailBlock.Visibility = 'Visible'
        $script:detailOn = $true
    }
    # reposition window after size change
    $window.Top = $work.Bottom - $window.ActualHeight - 18
}

$card.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($s.Visibility -ne 'Visible') { return }
    if ($script:dbl.ElapsedMilliseconds -lt [System.Windows.Forms.SystemInformation]::DoubleClickTime) {
        $script:dbl.Restart(); Toggle-Detail; return
    }
    $script:dbl.Restart()
    try { $window.DragMove() } catch {}
})

# ---------- data refresh ----------
$script:client = New-Object System.Net.Http.HttpClient
$script:client.Timeout = [TimeSpan]::FromSeconds(4)
$script:busy = $false
$script:lastStats = $null

function Save-DetailReport {
    try {
        $txt = Build-ReportText
        $path = Join-Path ([Environment]::GetFolderPath('Desktop')) ('tokscale-今日明细-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date))
        [System.IO.File]::WriteAllText($path, $txt, [System.Text.Encoding]::UTF8)
        Start-Process notepad $path
    } catch { [System.Windows.MessageBox]::Show("导出失败：$_") }
}

function Build-ReportText {
    $st = $script:lastStats
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('==== Tokscale 实时监控 · 今日明细 ====')
    if (-not $st) { [void]$sb.AppendLine('暂无数据'); return $sb.ToString() }
    [void]$sb.AppendLine(('生成时间: {0}' -f (Get-Date)))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('今日 token 总量: {0}' -f (Format-Token $st.today.total)))
    [void]$sb.AppendLine(('  输入 {0} · 输出 {1} · 缓存读 {2} · 推理 {3}' -f (Format-Token $st.today.input), (Format-Token $st.today.output), (Format-Token $st.today.cacheRead), (Format-Token $st.today.reasoning)))
    [void]$sb.AppendLine(('今日成本: ${0:F4}' -f $st.today.cost))
    [void]$sb.AppendLine('')
    if ($st.bestModel) {
        $b = $st.bestModel
        $speed = if ($null -ne $b.msPer1K) { ('{0:N1} ms/千token' -f $b.msPer1K) } else { '—' }
        [void]$sb.AppendLine(('今日最强模型: {0}' -f $b.model))
        [void]$sb.AppendLine(('  生成速度 {0} · {1} tokens/秒' -f $speed, $b.tokensPerSec))
        [void]$sb.AppendLine(('  今日用量 {0} (占比 {1:P1})' -f (Format-Token $b.total), $b.share))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- 今日各模型明细 --')
    foreach ($m in $st.modelsToday) {
        $speed = if ($null -ne $m.msPer1K) { ('{0:N1}' -f $m.msPer1K) } else { '—' }
        [void]$sb.AppendLine(('{0}: 输入{1} 输出{2} 缓存{3} 合计{4} | {5} ms/1K · 占比 {6}' -f $m.model, (Format-Token $m.input), (Format-Token $m.output), (Format-Token $m.cacheRead), (Format-Token $m.total), $speed, ('{0:P1}' -f $m.share)))
    }
    return $sb.ToString()
}

function Refresh-Stats {
    if ($script:busy) { return }
    $script:busy = $true
    try {
        $resp = $script:client.GetStringAsync($endpoint).GetAwaiter().GetResult()
        $st = $resp | ConvertFrom-Json
        if (-not $st.ok) { throw 'db-unavailable' }
        $script:lastStats = $st

        $StatusDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4CD964')
        $StatusText.Text = '实时'

        $TodayTotal.Text = Format-Token $st.today.total
        $TodayBreakdown.Text = ('输入 {0} · 输出 {1} · 缓存读 {2} · 推理 {3}' -f (Format-Token $st.today.input), (Format-Token $st.today.output), (Format-Token $st.today.cacheRead), (Format-Token $st.today.reasoning))

        if ($st.rolling.messages -gt 0) {
            $RollingText.Text = ('+{0} tokens · {1} 条' -f (Format-Token $st.rolling.total), $st.rolling.messages)
            $RollingText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#9EE6A3')
        } else {
            $RollingText.Text = '无新消息'
            $RollingText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#6B7C9F')
        }

        if ($st.bestModel) {
            $b = $st.bestModel
            $BestName.Text = $b.model
            $speed = if ($null -ne $b.msPer1K) { ('{0:N0} ms/千token · {1:N0} tokens/秒' -f $b.msPer1K, $b.tokensPerSec) } else { '暂无数速样本' }
            $BestMeta.Text = ('今日 {0} · 占比 {1:P0} · 费用 ${2:F4}' -f (Format-Token $b.total), $b.share, $b.cost)
        } else {
            $BestName.Text = '暂无数据'
            $BestMeta.Text = '完成一次会话后自动生成'
        }

        $sess = $st.active
        if ($sess) {
            $title = $sess.title
            if ($title.Length -gt 22) { $title = $title.Substring(0, 22) + '…' }
            $total = Format-Token ($sess.total)
            $SessionTitle.Text = ('会话：{0} · {1} · {2}' -f $title, $sess.model, $total)
        } else {
            $SessionTitle.Text = '当前会话：暂无'
        }
        $CostText.Text = ('今日成本 ${0:F4}' -f $st.today.cost)

        if ($script:detailOn) { $DetailBlock.Text = Build-DetailLines $st }

        $Footer.Text = ('上次刷新 {0:HH:mm:ss} · 双击切换详情 · 右键菜单' -f (Get-Date))
    } catch {
        $StatusDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF9500')
        $StatusText.Text = '连接中…'
    } finally {
        $script:busy = $false
    }
}

function Build-DetailLines($st) {
    $lines = @()
    $lines += '── 今日模型详情 ──'
    if ($st.modelsToday.Count -eq 0) { $lines += '（今日暂无记录）' }
    foreach ($m in $st.modelsToday) {
        $speed = if ($null -ne $m.msPer1K) { ('{0:N0}ms/1K' -f $m.msPer1K) } else { '—' }
        $lines += ('{0}: 输入 {1} / 输出 {2} / 缓存读 {3}' -f $m.model, (Format-Token $m.input), (Format-Token $m.output), (Format-Token $m.cacheRead))
        $lines += ('   合计 {0} · 占 {1:P0} · {2} · ${3:F4}' -f (Format-Token $m.total), $m.share, $speed, $m.cost)
    }
    $lines += ''
    $lines += ('最近60秒: 输入{0} 输出{1} 缓存读{2}' -f (Format-Token $st.rolling.input), (Format-Token $st.rolling.output), (Format-Token $st.rolling.cacheRead))
    return ($lines -join "`n")
}

# ---------- launch ----------
Start-MonitorBackend
$window.Add_Closed({
    $script:timer.Stop()
    if ($script:nodeProc -and -not $script:nodeProc.HasExited) {
        Stop-Process -Id $script:nodeProc.Id -Force -ErrorAction SilentlyContinue
    }
})
$script:dbl.Restart()
$script:timer.Start()
Refresh-Stats

$window.Show() | Out-Null
$window.Activate() | Out-Null
[System.Windows.Threading.Dispatcher]::Run()