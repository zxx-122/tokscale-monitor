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
$lbEndpoint = "http://127.0.0.1:$port/leaderboard"
$toolsEndpoint = "http://127.0.0.1:$port/tools"
$historyEndpoint = "http://127.0.0.1:$port/history?days=30"
$script:nodeProc = $null

function Log([string]$m) {
    try { Add-Content -Path (Join-Path $scriptDir 'widget.log') -Value (('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m)) -Encoding UTF8 } catch {}
}

# 启动时截断日志，避免无限累积
try { [System.IO.File]::WriteAllText((Join-Path $scriptDir 'widget.log'), '') } catch {}

function Format-Token([double]$n) {
    if ($n -lt 0) { $n = 0 }
    if ($n -ge 1e12) { return ('{0:0.00}万亿' -f ($n / 1e12)) }
    if ($n -ge 1e8)  { return ('{0:0.00}亿'   -f ($n / 1e8)) }
    if ($n -ge 1e4)  { return ('{0:0.00}万'   -f ($n / 1e4)) }
    return ('{0:N0}'  -f $n)
}

function Get-LbShortName($lb) {
    try {
        if ($lb -and $lb.sourceName) {
            if ($lb.sourceName -match 'AA|Artificial Analysis|智能指数') { return 'AA 智能指数' }
            if ($lb.sourceName -match '编程|SWE') { return '编程能力' }
            if ($lb.sourceName -match 'OpenCompass') { return 'OpenCompass' }
            return $lb.sourceName
        }
    } catch {}
    return '排行榜'
}

function Format-LbDate($lb) {
    try {
        if ($lb -and $lb.month) { return [string]$lb.month }
        if ($lb -and $lb.updatedAt) {
            $d = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$lb.updatedAt)).LocalDateTime
            return ('{0:yyyy-MM-dd}' -f $d)
        }
    } catch {}
    return '实时'
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
    if (Test-ExistingServer) { Log 'backend already running (skip spawn)'; return }
    $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeExe) {
        foreach ($p in @('C:\Program Files\nodejs\node.exe', 'C:\Program Files (x86)\nodejs\node.exe')) {
            if (Test-Path $p) { $nodeExe = $p; break }
        }
    }
    if (-not $nodeExe) { throw '未找到 node.exe，请先安装 Node.js（nodejs.org）' }
    Log "nodeExe=$nodeExe monitorScript=$monitorScript"
    $errLog = Join-Path $scriptDir 'monitor.err.log'
    $outLog = Join-Path $scriptDir 'monitor.out.log'
    try {
        $script:nodeProc = Start-Process -FilePath $nodeExe `
            -ArgumentList @('--no-warnings', $monitorScript) `
            -WindowStyle Hidden -PassThru -RedirectStandardError $errLog -RedirectStandardOutput $outLog
        Log "node spawned pid=$($script:nodeProc.Id) exited=$($script:nodeProc.HasExited)"
    } catch {
        Log "Start-Process threw: $($_.Exception.Message)"
        throw
    }
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-ExistingServer) { Log 'backend up after wait'; break }
        if ($script:nodeProc.HasExited) { Log "node exited early (code=$($script:nodeProc.ExitCode))"; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not (Test-ExistingServer) -and $script:nodeProc.HasExited) {
        $msg = [string](Get-Content $errLog -Raw -ErrorAction SilentlyContinue)
        throw "monitor.mjs 启动失败: $msg"
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
          <TextBlock Name="StatusText" Text="实时" FontSize="11" Foreground="#9FB3D9" VerticalAlignment="Center"/>
          <Button Name="CloseBtn" Content="×" Width="20" Height="20" Margin="10,0,0,0" Padding="0" Cursor="Hand"
                  VerticalAlignment="Center" ToolTip="退出并停止运行">
            <Button.Style>
              <Style TargetType="Button">
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="BorderThickness" Value="0"/>
                <Setter Property="Foreground" Value="#8A9BC0"/>
                <Setter Property="FontSize" Value="14"/>
                <Style.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="#FF5B6B"/>
                  </Trigger>
                </Style.Triggers>
              </Style>
            </Button.Style>
          </Button>
        </StackPanel>
      </DockPanel>

      <TextBlock Text="今日累计" FontSize="10" Foreground="#7A8BB0" Margin="0,10,0,0"/>
      <TextBlock Name="TodayTotal" Text="…" FontSize="26" FontWeight="Bold" Foreground="#FFFFFF"/>
      <TextBlock Name="TodayBreakdown" Text="输入 0 · 输出 0 · 缓存读 0" FontSize="10.5" Foreground="#A6B6D6" Margin="0,2,0,0"/>

      <Border Background="#1B2A4A" CornerRadius="8" Padding="10,7,10,7" Margin="0,10,0,0">
        <StackPanel>
          <TextBlock Name="BestLabel" Text="今日最快模型" FontSize="9" Foreground="#8FE3C6"/>
          <TextBlock Name="BestName" Text="—" FontSize="13" FontWeight="Bold" Foreground="#FFF3B0" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
          <TextBlock Name="BestMeta" Text="" FontSize="9.5" Foreground="#A9B9D8" Margin="0,2,0,0"/>
        </StackPanel>
      </Border>

      <DockPanel Margin="0,10,0,0">
        <TextBlock Text="今日使用模型" FontSize="10" Foreground="#7A8BB0" DockPanel.Dock="Left"/>
        <TextBlock Name="ModelsCount" Text="" FontSize="10" Foreground="#8FE3C6" TextAlignment="Right" DockPanel.Dock="Right"/>
      </DockPanel>
      <TextBlock Name="ModelsList" Text="" FontSize="9.5" Foreground="#C6D3EA" TextWrapping="Wrap" LineHeight="16" Margin="0,2,0,0"/>
      <TextBlock Name="ToolsSummary" Text="" FontSize="9" Foreground="#7FA8D9" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed"/>

      <DockPanel Margin="0,10,0,0">
        <TextBlock Text="模型能力排行榜" FontSize="10" Foreground="#7A8BB0" DockPanel.Dock="Left"/>
        <TextBlock Name="LbSource" Text="排行榜 · 加载中" FontSize="9" Foreground="#5B6B8F" TextAlignment="Right" DockPanel.Dock="Right"/>
      </DockPanel>
      <TextBlock Name="LbList" Text="" FontSize="9.5" Foreground="#C6D3EA" TextWrapping="Wrap" LineHeight="15" Margin="0,2,0,0"/>

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
foreach ($n in @('Card','StatusDot','StatusText','TodayTotal','TodayBreakdown','BestLabel','BestName','BestMeta','ModelsCount','ModelsList','ToolsSummary','RollingText','SessionTitle','CostText','DetailBlock','Footer','LbSource','LbList')) {
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

$miLbRefresh = New-Object System.Windows.Controls.MenuItem
$miLbRefresh.Header = '刷新排行榜'
$miLbRefresh.Add_Click({
    try {
        $null = $script:client.GetStringAsync("$lbEndpoint?refresh=1").GetAwaiter().GetResult()
        Log 'leaderboard refreshed'
        Refresh-Stats
    } catch { Log "leaderboard refresh threw: $($_.Exception.Message)" }
})

# 排行榜源切换（aa=AA 智能指数 / code=编程能力）
# 注意：变量名避免与控件 $LbSource 冲突（PowerShell 不区分大小写），故用 lbSrc
$miLbSourceHeader = New-Object System.Windows.Controls.MenuItem
$miLbSourceHeader.Header = '排行榜源'
$script:lbSrc = 'aa'
foreach ($ls in @(@('aa', 'AA 智能指数'), @('code', '编程能力'))) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $ls[1]
    $mi.Tag = $ls[0]
    $mi.IsChecked = ($ls[0] -eq $script:lbSrc)
    $mi.Add_Click({
        param($sender, $e)
        $src = [string]$sender.Tag
        $script:lbSrc = $src
        try {
            $null = $script:client.GetStringAsync("$lbEndpoint?source=$src").GetAwaiter().GetResult()
            Log "leaderboard source switched to $src"
            Refresh-Stats
        } catch { Log "leaderboard switch threw: $($_.Exception.Message)" }
    })
    $miLbSourceHeader.Items.Add($mi) | Out-Null
}

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
$menu.Items.Add($miLbRefresh) | Out-Null
$menu.Items.Add($miLbSourceHeader) | Out-Null
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
$script:history = $null
$script:lastHistoryAt = 0
$script:tools = $null
$script:lastToolsAt = 0

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
        [void]$sb.AppendLine(('今日最快模型: {0}' -f $b.model))
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

        # 节流拉取：近30天历史（60s）与 skill/MCP 工具统计（30s），供详情视图使用
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if ($nowMs - $script:lastHistoryAt -ge 60000) {
            try {
                $script:history = $script:client.GetStringAsync($historyEndpoint).GetAwaiter().GetResult() | ConvertFrom-Json
                $script:lastHistoryAt = $nowMs
            } catch { Log ("history fetch failed: " + $_.Exception.Message) }
        }
        if ($nowMs - $script:lastToolsAt -ge 30000) {
            try {
                $script:tools = $script:client.GetStringAsync($toolsEndpoint).GetAwaiter().GetResult() | ConvertFrom-Json
                $script:lastToolsAt = $nowMs
            } catch { Log ("tools fetch failed: " + $_.Exception.Message) }
        }

        # 主卡：近7天 skill/MCP 简况
        if ($script:tools -and $script:tools.ok) {
            $ts = $script:tools
            $parts = @()
            $parts += ('工具调用 {0} 次' -f $ts.totalCalls)
            if ($ts.skill -and $ts.skill.total -gt 0) {
                $topSk = @($ts.skill.byName | Select-Object -First 1)
                if ($topSk.Count -gt 0) { $parts += ('skill {0} 次 ({1})' -f $ts.skill.total, $topSk[0].name) }
                else { $parts += ('skill {0} 次' -f $ts.skill.total) }
            } else {
                $parts += 'skill 0 次'
            }
            if ($ts.mcp -and $ts.mcp.detected) { $parts += ('MCP {0} 次' -f $ts.mcp.total) }
            else { $parts += 'MCP 未启用' }
            $ToolsSummary.Text = ('近7天 ' + ($parts -join ' · '))
            $ToolsSummary.Visibility = 'Visible'
        } else {
            $ToolsSummary.Visibility = 'Collapsed'
        }

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

        $models = @($st.modelsToday)
        $ModelsCount.Text = ('{0} 个模型' -f $models.Count)
        if ($models.Count -eq 0) {
            $ModelsList.Text = '（今日暂无模型使用记录）'
        } else {
            $mlines = @()
            $show = [Math]::Min(6, $models.Count)
            for ($i = 0; $i -lt $show; $i++) {
                $m = $models[$i]
                $star = ''
                if ($st.bestModel -and $m.model -eq $st.bestModel.model) { $star = '★ ' }
                $mlines += ('{0}{1}: 输入 {2} · 输出 {3} · 缓存读 {4} | 合计 {5}（{6:P0}） ${7:F4}' -f $star, $m.model, (Format-Token $m.input), (Format-Token $m.output), (Format-Token $m.cacheRead), (Format-Token $m.total), $m.share, $m.cost)
            }
            if ($models.Count -gt $show) { $mlines += ('… 还有 {0} 个模型，双击看全部' -f ($models.Count - $show)) }
            $ModelsList.Text = ($mlines -join "`n")
        }

        $lb = $st.leaderboard
        try {
            if ($lb -and $lb.items -and $lb.items.Count -gt 0) {
                $srcName = Get-LbShortName $lb
                $dateTxt = Format-LbDate $lb
                $LbSource.Text = ('{0} · {1} · {2}名' -f $srcName, $dateTxt, $lb.count)
                if ($lb.stale) { $LbSource.Text += ' · 缓存' }
                $lbLines = @()
                $lbShow = [Math]::Min(5, $lb.items.Count)
                for ($i = 0; $i -lt $lbShow; $i++) {
                    $x = $lb.items[$i]
                    $tm = if ($x.PSObject.Properties['thinkingMode'] -and $x.thinkingMode) { (' ({0})' -f $x.thinkingMode) } else { '' }
                    $scoreTxt = if ($x.score -ne $null) { $x.score } else { '—' }
                    $lbLines += ('{0}. {1}{2} · {3}' -f $x.rank, $x.model, $tm, $scoreTxt)
                }
                if ($lb.items.Count -gt $lbShow) { $lbLines += ('… 还有 {0} 名，双击详情查看' -f ($lb.items.Count - $lbShow)) }
                $LbList.Text = ($lbLines -join "`n")
            } else {
                $LbSource.Text = (Get-LbShortName $lb)
                $LbList.Text = '（榜单暂不可用）'
            }
        } catch {
            Log ("leaderboard section FAILED: " + $_.Exception.Message)
            $LbSource.Text = '排行榜'
            $LbList.Text = '（榜单暂不可用）'
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
        $diag = 'type=' + $_.Exception.GetType().FullName
        if ($_.InvocationInfo) { $diag += ' line=' + $_.InvocationInfo.ScriptLineNumber + ':' + $_.InvocationInfo.Line.Trim() }
        Log ("Refresh-Stats FAILED: " + $_.Exception.Message + " | " + $diag)
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
    if ($st.leaderboard -and $st.leaderboard.items -and $st.leaderboard.items.Count -gt 0) {
        $lines += ''
        $lines += ('── 模型能力排行榜 ({0}) ──' -f (Get-LbShortName $st.leaderboard))
        $lb = $st.leaderboard
        $dateTxt = Format-LbDate $lb
        $lines += ('更新时间: {0} · 共 {1} 名' -f $dateTxt, $lb.count)
        foreach ($x in $lb.items) {
            $tm = if ($x.PSObject.Properties['thinkingMode'] -and $x.thinkingMode) { (' · {0}' -f $x.thinkingMode) } else { '' }
            $org = if ($x.PSObject.Properties['org'] -and $x.org) { (' · {0}' -f $x.org) } else { '' }
            $lines += ('{0,2}. {1}{2}{3} · {4}分' -f $x.rank, $x.model, $tm, $org, $x.score)
        }
    }

    # 近30天每日消耗
    if ($script:history -and $script:history.ok) {
        $lines += ''
        $lines += ('── 近 {0} 天每日消耗 ──' -f $script:history.days)
        $hItems = @($script:history.items)
        if ($hItems.Count -eq 0) {
            $lines += '（无记录）'
        } else {
            $half = [Math]::Ceiling($hItems.Count / 2)
            for ($i = 0; $i -lt $half; $i++) {
                $d = $hItems[$i]
                $left = ('{0} {1}' -f $d.date.Substring(5), (Format-Token $d.total))
                $j = $i + $half
                if ($j -lt $hItems.Count) {
                    $d2 = $hItems[$j]
                    $pad = ' ' * [Math]::Max(1, (18 - $left.Length))
                    $lines += ($left + $pad + ('{0} {1}' -f $d2.date.Substring(5), (Format-Token $d2.total)))
                } else {
                    $lines += $left
                }
            }
        }
        if ($script:history.totals) {
            $ht = $script:history.totals
            $avg = $ht.total / [Math]::Max(1, $script:history.days)
            $lines += ('合计 {0} · 日均 {1} · 成本 ${2:F2}' -f (Format-Token $ht.total), (Format-Token $avg), $ht.cost)
        }
    }

    # 近7天各工具 token 消耗（opencode / claude / codex）
    if ($script:history -and $script:history.byToolTotals) {
        $lines += ''
        $lines += '── 近7天各工具消耗 ──'
        $toolLabel = @{ opencode = 'opencode'; claude = 'claude code'; codex = 'codex'; deepcode = 'deepcode'; kimi = 'kimi-code' }
        $toolOrder = @('opencode', 'claude', 'codex', 'kimi', 'deepcode')
        $anyTool = $false
        foreach ($tk in $toolOrder) {
            if (-not $script:history.byToolTotals.PSObject.Properties[$tk]) { continue }
            $t = $script:history.byToolTotals.$tk
            $label = $toolLabel[$tk]
            $hs = $script:history.tools
            $noUsage = $hs -and $hs.$tk -and -not $hs.$tk.hasUsage
            if ($t.total -gt 0 -or $t.messages -gt 0) {
                $anyTool = $true
                if ($noUsage) {
                    $lines += ('{0}: {1} 条消息 (无用量数据)' -f $label, $t.messages)
                } else {
                    $lines += ('{0}: {1} (输入{2} 输出{3}) · {4}条' -f $label, (Format-Token $t.total), (Format-Token $t.input), (Format-Token $t.output), $t.messages)
                }
            } elseif (-not $noUsage) {
                $lines += ('{0}: 0' -f $label)
            }
        }
        if (-not $anyTool) { $lines += '（近7天各工具均无用量记录）' }
        # 每日各工具分布（近7天，横向展示）
        $hItems7 = @($script:history.items)
        if ($hItems7.Count -gt 0) {
            $lines += ('每日: ' + (($hItems7 | ForEach-Object {
                $parts = @()
                foreach ($tk in @('opencode', 'claude', 'codex')) {
                    if ($_.byTool.$tk.total -gt 0) { $parts += ('{0} {1}' -f $tk, (Format-Token $_.byTool.$tk.total)) }
                }
                if ($parts.Count -eq 0) { return '' }
                ('{0}[{1}]' -f $_.date.Substring(5), ($parts -join ' '))
            } | Where-Object { $_ }) -join ' '))
        }
    }

    # 近7天 skill / MCP 调用
    if ($script:tools -and $script:tools.ok) {
        $lines += ''
        $lines += '── 近7天工具调用 ──'
        $lines += ('总调用 {0} 次' -f $script:tools.totalCalls)
        $sk = $script:tools.skill
        if ($sk -and $sk.total -gt 0) {
            $lines += ('skill: {0} 次' -f $sk.total)
            foreach ($s in @($sk.byName | Select-Object -First 5)) {
                $lines += ('  {0} ×{1}' -f $s.name, $s.calls)
            }
        } else {
            $lines += 'skill: 近7天无调用'
        }
        $mc = $script:tools.mcp
        if ($mc -and $mc.detected) {
            $lines += ('MCP: {0} 次 ({1} 个工具)' -f $mc.total, $mc.byTool.Count)
            foreach ($t in @($mc.byTool | Select-Object -First 5)) {
                $lines += ('  {0} ×{1}' -f $t.tool, $t.calls)
            }
        } else {
            $lines += 'MCP: 未检测到调用'
        }
        if ($script:tools.byDay -and $script:tools.byDay.Count -gt 0) {
            $dayStr = (@($script:tools.byDay | ForEach-Object { ('{0}({1})' -f $_.date.Substring(5), $_.calls) }) -join ' ')
            $lines += ('每日: {0}' -f $dayStr)
        }
    }
    return ($lines -join "`n")
}

# ---------- launch ----------
Log 'widget launching'
try {
    Start-MonitorBackend
    Log 'backend started ok'
} catch {
    Log "START FAILED: $($_.Exception.ToString())"
    try { $_.Exception.ToString() | Out-File -FilePath (Join-Path $scriptDir 'widget.err.log') -Encoding UTF8 } catch {}
    [System.Windows.MessageBox]::Show(('启动监测后端失败：{0}' -f $_), 'Tokscale 悬浮窗', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit 1
}
Log 'showing window'
$window.Add_Closed({
    $script:timer.Stop()
    if ($script:nodeProc -and -not $script:nodeProc.HasExited) {
        Stop-Process -Id $script:nodeProc.Id -Force -ErrorAction SilentlyContinue
    }
})
$script:dbl.Restart()
$script:timer.Start()
try { Refresh-Stats; Log 'initial refresh ok' } catch { Log "initial refresh threw: $($_.Exception.ToString())" }

$window.Show() | Out-Null
$window.Activate() | Out-Null
Log 'dispatcher running'
[System.Windows.Threading.Dispatcher]::Run()