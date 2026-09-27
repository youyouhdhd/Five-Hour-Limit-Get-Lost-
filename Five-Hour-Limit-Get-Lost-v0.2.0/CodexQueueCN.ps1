# Codex Queue CN - lightweight local Windows scheduler (no network service).
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:DataDir=Join-Path $env:LOCALAPPDATA 'CodexQueueCN';$script:StateFile=Join-Path $script:DataDir 'queue.json';$script:RunDir=Join-Path $script:DataDir 'runs'
$script:CodexHome=if([string]::IsNullOrWhiteSpace($env:CODEX_HOME)){Join-Path $env:USERPROFILE '.codex'}else{[IO.Path]::GetFullPath($env:CODEX_HOME)}
$script:Codex=$null
New-Item -ItemType Directory -Force -Path $script:DataDir,$script:RunDir|Out-Null
. (Join-Path $PSScriptRoot 'QueueCore.ps1')
function Load-State{if(Test-Path $script:StateFile){try{$x=Get-Content -Raw $script:StateFile|ConvertFrom-Json;if($x.items){return @($x.items)}}catch{}};return @()}
function Save-State{$clean=@();foreach($i in @($script:Items)){$clean+=[ordered]@{id=$i.id;title=$i.title;prompt=$i.prompt;promptSnapshot=$i.promptSnapshot;cwd=$i.cwd;session=$i.session;originalThreadId=$i.originalThreadId;status=$i.status;monitorOnly=$i.monitorOnly;mode=$i.mode;bufferMinutes=$i.bufferMinutes;manualResetAt=$i.manualResetAt;limitConfirmed=$i.limitConfirmed;detectedResetAt=$i.detectedResetAt;detectedAt=$i.detectedAt;detectedSource=$i.detectedSource;created=$i.created;attempts=$i.attempts;waitUntil=$i.waitUntil;retryAt=$i.retryAt;retryCount=$i.retryCount;ownerConflictCount=$i.ownerConflictCount;ownerKind=$i.ownerKind;ownerPid=$i.ownerPid;ownerStartedAt=$i.ownerStartedAt;executionMode=$i.executionMode;codexHome=$i.codexHome;errorKind=$i.errorKind;lastError=$i.lastError;lastExitCode=$i.lastExitCode;attemptId=$i.attemptId;turnId=$i.turnId;submissionState=$i.submissionState;codexPath=$i.codexPath;codexVersion=$i.codexVersion;workerPid=$i.workerPid;workerStartedAt=$i.workerStartedAt;outputPath=$i.outputPath;started=$i.started;finished=$i.finished;lastOutput=$i.lastOutput}};$o=[ordered]@{version=3;updated=(Get-Date).ToUniversalTime().ToString('o');items=$clean};$tmp="$script:StateFile.tmp";Set-Content -LiteralPath $tmp -Value (ConvertTo-Json -InputObject $o -Depth 8) -Encoding UTF8;Move-Item -Force $tmp $script:StateFile}
function New-Id{[guid]::NewGuid().ToString('N').Substring(0,8)}
function Ensure-Props($i){$null=Initialize-QueueItem $i}
function Resolve-Codex{$cmd=Get-Command codex.exe -ErrorAction SilentlyContinue;if($cmd -and $cmd.Path -and (Test-Path -LiteralPath $cmd.Path)){return $cmd.Path};$base=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin';if(Test-Path -LiteralPath $base){try{$candidates=@();foreach($p in [IO.Directory]::GetFiles($base,'codex.exe',[IO.SearchOption]::AllDirectories)){try{$candidates+=[pscustomobject]@{Path=$p;When=[IO.File]::GetLastWriteTimeUtc($p)}}catch{}};foreach($c in @($candidates|Sort-Object When -Descending)){if(Test-Path -LiteralPath $c.Path){return $c.Path}}}catch{}};return $null}
$script:Codex=Resolve-Codex;if(-not $script:Codex){$script:Codex='codex.exe'}
function Get-ExistingSessions{$idx=Join-Path $script:CodexHome 'session_index.jsonl';$root=Join-Path $script:CodexHome 'sessions';$out=@();if(-not(Test-Path $idx)){return $out};$lines=@(Get-Content $idx -Encoding UTF8 -ErrorAction SilentlyContinue);$start=[Math]::Max(0,$lines.Count-60);$records=@();for($li=$start;$li -lt $lines.Count;$li++){try{$records+=ConvertFrom-Json -InputObject $lines[$li]}catch{}};$paths=@();try{$paths=[IO.Directory]::GetFiles($root,'*.jsonl',[IO.SearchOption]::AllDirectories)}catch{};$byId=@{};foreach($path in $paths){$name=[IO.Path]::GetFileName($path);if($name -match '(?<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$'){$byId[$matches.id]=$path}};foreach($r in $records){try{$id=[string]$r.id;if(-not$id){continue};$cwd='';if($byId.ContainsKey($id)){try{$m=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $byId[$id] -Encoding UTF8 -TotalCount 1);if($m.payload.cwd){$cwd=$m.payload.cwd}}catch{}};$title=[string]$r.thread_name;if(-not$title){$title='未命名任务'};$out+=[pscustomobject]@{Display="$title  ·  $cwd";id=$id;title=$title;cwd=$cwd;updated=$r.updated_at}}catch{}};$seen=@{};$uniq=@();foreach($s in @($out|Sort-Object updated -Descending)){if(-not $seen.ContainsKey([string]$s.id)){$seen[[string]$s.id]=$true;$uniq+=$s}};return @($uniq)}
function Latest-Reset([string]$SessionId,[string]$CodexHome){
    $now=Get-Date
    if([string]::IsNullOrWhiteSpace($CodexHome)){$CodexHome=$script:CodexHome}
    if($script:ResetCacheAt -and [string]$script:ResetCacheSession -eq [string]$SessionId -and [string]$script:ResetCacheHome -eq [string]$CodexHome -and (($now-$script:ResetCacheAt).TotalSeconds -lt 60)){
        if($script:ResetCache -and $script:ResetCache.ResetAt -and $script:ResetCache.ResetAt -gt $now){return $script:ResetCache}
        return $null
    }
    $root=Join-Path $CodexHome 'sessions'
    $script:ResetCache=Get-SessionReset $root $SessionId $now
    $script:ResetCacheAt=$now
    $script:ResetCacheSession=$SessionId
    $script:ResetCacheHome=$CodexHome
    if($script:ResetCache.ResetAt -and $script:ResetCache.ResetAt -gt (Get-Date)){return $script:ResetCache}
    return $null
}
function Update-DetectInfo{
    if(-not $script:ScheduleInfo){return}
    if($modeBox -and $modeBox.SelectedIndex -ne 0){return}
    $stamp=$script:ResetCacheAt
    if(-not $stamp){$script:ScheduleInfo.Text='自动检测：等待首次扫描原会话日志';return}
    $cache=$script:ResetCache
    $when=$stamp.ToString('HH:mm:ss')
    if($cache -and $cache.Error){
        $script:ScheduleInfo.Text='自动检测：'+$when+' 扫描失败：'+$cache.Error
    }elseif($cache -and $cache.ResetAt){
        $source=[string]$cache.Source
        if($source.Length -gt 36){$source=$source.Substring(0,36)+'…'}
        if(-not $cache.LimitConfirmed){
            $script:ScheduleInfo.Text='自动检测：读到原会话额度窗口 '+$cache.ResetAt.ToString('MM-dd HH:mm')+'，未发现限额失败事件；暂不续跑'
        }elseif($cache.ResetAt -gt (Get-Date)){
            $script:ScheduleInfo.Text='自动检测：'+$when+' 读取到五小时重置 '+$cache.ResetAt.ToString('MM-dd HH:mm')+'（'+$source+'）'
        }else{
            $script:ScheduleInfo.Text='自动检测：'+$when+' 原会话日志中的重置时间 '+$cache.ResetAt.ToString('MM-dd HH:mm')+' 已过期'
        }
    }else{
        $scanned=0;$total=0
        if($cache){$scanned=[int]$cache.Scanned;$total=[int]$cache.Total}
        $script:ScheduleInfo.Text='自动检测：'+$when+' 检查原会话日志 '+$scanned+'/'+$total+'，未发现五小时重置信息'
    }
}
function Get-BufferMinutes($i){$b=2;try{if($null -ne $i.bufferMinutes){$b=[int]$i.bufferMinutes}}catch{};if($b -lt 0){$b=0};if($b -gt 60){$b=60};return $b}
function Parse-ManualReset($text){$t=[string]$text;if([string]::IsNullOrWhiteSpace($t)){throw '请选择下一次恢复时间（小时和分钟）'};$t=$t.Trim();if($t -notmatch '^\s*(\d{1,2}):(\d{2})\s*$'){throw '时间格式不正确，请选择 HH:mm'};$hh=[int]$matches[1];$mm=[int]$matches[2];if($hh -gt 23 -or $mm -gt 59){throw '时间格式不正确，请选择 HH:mm'};$t=(Get-Date).Date.AddHours($hh).AddMinutes($mm);if($t -le (Get-Date)){$t=$t.AddDays(1)};return $t}
function Normalize-ManualReset($d,$buffer){$next=[datetime]$d;$now=Get-Date;while($next.AddMinutes($buffer) -le $now){$next=$next.AddHours(5)};return $next}
function Cycle-Preview($d,$count){$parts=@();for($k=0;$k -lt $count;$k++){$parts+=([datetime]$d).AddHours(5*$k).ToString('HH:mm')};return ($parts -join ' → ')}
function Display-Time($v){if($v){try{return ([datetime]$v).ToString('HH:mm')}catch{}};return ''}
function Set-ManualWaiting($i){$b=Get-BufferMinutes $i;$next=[datetime]::MinValue;try{if($i.manualResetAt){$next=[datetime]$i.manualResetAt}}catch{};if($next -eq [datetime]::MinValue){$next=(Get-Date)};while($next.AddMinutes($b) -le (Get-Date)){$next=$next.AddHours(5)};$i.manualResetAt=$next.ToString('o');$i.waitUntil=$next.AddMinutes($b).ToString('o');$i.status='waiting';$i.monitorOnly=$false;$i.retryAt=$null}
$script:DefaultPrompt='继续完成上一个任务：先检查当前状态，再继续原计划。'
function Test-WhiteSpace($s){[string]::IsNullOrWhiteSpace([string]$s)}
function Arg($s){'"'+(($s -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1')+'"'}
function Start-Item($i){
    $threadId=[string]$i.originalThreadId
    if([string]::IsNullOrWhiteSpace($threadId) -or $threadId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'){throw '原会话 ID 缺失或格式无效；为防止创建新会话，已阻止启动。'}
    if([string]$i.codexPath -and -not(Test-Path -LiteralPath $i.codexPath)){throw '上次使用的 codex.exe 已不存在；请检查安装后手动重试原会话。'}
    if($i.codexPath){$script:Codex=[string]$i.codexPath}else{$resolved=Resolve-Codex;if(-not$resolved){throw '找不到 codex.exe'};$script:Codex=$resolved;$i.codexPath=$resolved}
    if([string]::IsNullOrWhiteSpace([string]$i.codexHome)){$i.codexHome=$script:CodexHome}
    if(-not(Test-Path -LiteralPath $i.codexHome -PathType Container)){throw '上次使用的 Codex Home 不存在；为避免切换到另一份会话数据，已阻止启动。'}
    if(-not$i.executionMode){$i.executionMode='managedResume'}
    if(-not$i.cwd -or -not(Test-Path -LiteralPath $i.cwd -PathType Container)){throw '原任务工作目录不存在；已阻止在其他目录启动。'}
    $prompt=[string]$i.prompt
    if(Test-WhiteSpace $prompt){$prompt=$script:DefaultPrompt}
    $i.promptSnapshot=$prompt
    $i.attemptId=[guid]::NewGuid().ToString('N')
    $i.turnId=''
    $i.submissionState='launching'
    $i.ownerKind='schedulerOwned'
    $i.ownerPid=$null
    $i.ownerStartedAt=$null
    $i.status='running'
    $i.errorKind=''
    $i.lastError=''
    $i.retryAt=$null
    $i.started=(Get-Date).ToString('o')
    $runDir=Join-Path $script:RunDir ([string]$i.id)
    New-Item -ItemType Directory -Force -Path $runDir|Out-Null
    $i.outputPath=Join-Path $runDir ($i.attemptId+'.log')
    if(-not$i.codexVersion){
        try{$i.codexVersion=((& $script:Codex --version 2>$null | Select-Object -First 1) -join '').Trim()}catch{$i.codexVersion='unknown'}
    }
    Save-State
    Refresh-Grid
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$script:Codex
    $psi.WorkingDirectory=[string]$i.cwd
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=[Text.Encoding]::UTF8
    $psi.StandardErrorEncoding=[Text.Encoding]::UTF8
    $psi.EnvironmentVariables['CODEX_HOME']=[string]$i.codexHome
    $argList=Get-ResumeArguments $threadId $prompt
    $quoted=@();foreach($arg in $argList){$quoted+=Arg $arg}
    $psi.Arguments=$quoted -join ' '
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$psi
    try{
        if(-not$process.Start()){throw '无法启动 codex.exe'}
        $i.workerPid=$process.Id
        $i.ownerPid=$process.Id
        try{$i.workerStartedAt=$process.StartTime.ToString('o');$i.ownerStartedAt=$i.workerStartedAt}catch{$i.workerStartedAt=$i.started;$i.ownerStartedAt=$i.started}
        $i.submissionState='process_started'
        $i|Add-Member -NotePropertyName _process -NotePropertyValue $process -Force
        $i|Add-Member -NotePropertyName _soTask -NotePropertyValue ($process.StandardOutput.ReadToEndAsync()) -Force
        $i|Add-Member -NotePropertyName _seTask -NotePropertyValue ($process.StandardError.ReadToEndAsync()) -Force
        Save-State
        Refresh-Grid
    }catch{
        try{$process.Dispose()}catch{}
        $i|Add-Member -NotePropertyName _process -NotePropertyValue $null -Force
        throw
    }
}
function Finish-Item($i){
    $process=$i._process
    if(-not$process -or -not$process.HasExited){return}
    $stdout='';$stderr=''
    if($i._soTask){try{$stdout=[string]$i._soTask.Result}catch{$stdout='读取 stdout 失败：'+$_.Exception.Message}}
    if($i._seTask){try{$stderr=[string]$i._seTask.Result}catch{$stderr='读取 stderr 失败：'+$_.Exception.Message}}
    $fullOutput=$stdout+[Environment]::NewLine+$stderr
    if($i.outputPath){
        try{[IO.File]::WriteAllText([string]$i.outputPath,$fullOutput,[Text.UTF8Encoding]::new($false))}catch{}
    }
    $threadMismatch=$false
    foreach($line in([regex]::Split($fullOutput,'\r?\n'))){
        try{
            $event=ConvertFrom-Json -InputObject $line -ErrorAction Stop
            if($event.type -eq 'thread.started' -and $event.thread_id){
                if([string]$event.thread_id -ne [string]$i.originalThreadId){$threadMismatch=$true}
            }
            if($event.type -eq 'turn.started' -and $event.turn_id){$i.turnId=[string]$event.turn_id}
        }catch{}
    }
    if($fullOutput.Length -gt 50000){$i.lastOutput=$fullOutput.Substring($fullOutput.Length-50000)}else{$i.lastOutput=$fullOutput}
    $exitCode=[int]$process.ExitCode
    $i.lastExitCode=$exitCode
        if($threadMismatch){
        $null=Set-QueueItemFailure $i ('unexpected thread id returned; '+$fullOutput) $exitCode
    }elseif($exitCode -eq 0){
        $i.status='done';$i.errorKind='';$i.submissionState='completed';$i.finished=(Get-Date).ToString('o');$i.lastError='';$i.retryAt=$null;$i.ownerKind=''
    }else{
        $null=Set-QueueItemFailure $i $fullOutput $exitCode
        if($i.errorKind -eq 'rate_limit'){$i.limitConfirmed=$true}
        if($i.errorKind -eq 'rate_limit' -and [string]$i.mode -eq 'auto'){
            $reset=Latest-Reset ([string]$i.originalThreadId) ([string]$i.codexHome)
            if($reset){$buffer=Get-BufferMinutes $i;$i.detectedResetAt=$reset.ResetAt.ToString('o');$i.detectedAt=(Get-Date).ToString('o');$i.detectedSource=[string]$reset.Source;$i.waitUntil=$reset.ResetAt.AddMinutes($buffer).ToString('o')}
            else{$i.waitUntil=$null}
        }elseif([string]$i.mode -eq 'manual' -and $i.errorKind -eq 'rate_limit'){
            Set-ManualWaiting $i
        }
    }
    $i.workerPid=$null;$i.workerStartedAt=$null;$i.ownerPid=$null;$i.ownerStartedAt=$null
    $i|Add-Member -NotePropertyName _process -NotePropertyValue $null -Force
    try{$process.Dispose()}catch{}
    Save-State
    Refresh-Grid
}
function Tick{
    $hasRunning=$false
    $now=Get-Date
    foreach($item in @($script:Items)){
        if($item.status -eq 'running'){
            $hasRunning=$true
            Finish-Item $item
        }
        if($item.status -eq 'monitoring' -and [string]$item.mode -eq 'auto'){
            $reset=Latest-Reset ([string]$item.originalThreadId) ([string]$item.codexHome)
            Update-DetectInfo
            if($reset -and $reset.ResetAt -gt $now -and $reset.LimitConfirmed){
                $buffer=Get-BufferMinutes $item
                $item.detectedResetAt=$reset.ResetAt.ToString('o')
                $item.detectedAt=(Get-Date).ToString('o')
                $item.detectedSource=[string]$reset.Source
                $item.limitConfirmed=$true
                $item.status='waiting'
                $item.waitUntil=$reset.ResetAt.AddMinutes($buffer).ToString('o')
                $item.retryAt=$null
                $item.monitorOnly=$false
                Save-State
                Refresh-Grid
            }
        }
        if($item.status -eq 'waiting' -and [string]$item.mode -eq 'auto' -and -not $item.waitUntil -and (-not $item.retryAt -or [datetime]$item.retryAt -le $now)){
            $reset=Latest-Reset ([string]$item.originalThreadId) ([string]$item.codexHome)
            Update-DetectInfo
            if($reset -and $reset.ResetAt -gt $now -and ($item.limitConfirmed -or $reset.LimitConfirmed)){
                $item.detectedResetAt=$reset.ResetAt.ToString('o')
                $item.detectedAt=(Get-Date).ToString('o')
                $item.detectedSource=[string]$reset.Source
                $item.limitConfirmed=$true
                $item.waitUntil=$reset.ResetAt.AddMinutes((Get-BufferMinutes $item)).ToString('o')
                $item.retryAt=$null
                $item.lastError=''
            }else{
                $item.retryAt=$now.AddMinutes(1).ToString('o')
                $item.lastError='额度错误已确认；尚未从原会话日志读到未来的五小时重置时间，将于一分钟后重查。'
            }
            Save-State
            Refresh-Grid
        }
        if($item.status -eq 'waiting_owner' -and $item.retryAt -and [datetime]$item.retryAt -le $now){
            $item.status='pending'
            $item.submissionState='retry_authorized'
            Save-State
        }
        if($item.status -eq 'waiting' -and $item.waitUntil -and [datetime]$item.waitUntil -le $now){
            $item.status='pending'
            $item.waitUntil=$null
            $item.submissionState='retry_authorized'
            Save-State
        }
    }
    if($script:Paused -or $hasRunning){return}
    $next=$null
    foreach($item in @($script:Items)){
        if($item.status -eq 'pending' -and (-not $next -or [datetime]$item.created -lt [datetime]$next.created)){$next=$item}
    }
    if(-not$next){return}
    try{Start-Item $next}
    catch{
        $next.status='needs_attention'
        $next.errorKind='startup'
        $next.submissionState='rejected'
        $next.lastError='未能启动原会话：'+$_.Exception.Message
        $next.lastOutput=$_.Exception.ToString()
        $next.retryAt=$null
        Save-State
        Refresh-Grid
    }
}
function Status-CN($s,$mode){return Get-QueueStatusText ($s) ($mode)}
function Refresh-Grid{
    if(-not $script:Grid){return}
    try{
        $script:Grid.SuspendLayout()
        $script:Grid.Rows.Clear()
        $pending=0
        $running=0
        $waiting=0
        $owner=0
        $attention=0
        $count=0
        foreach($i in @($script:Items)){
            $count++
            if($i.status -eq 'pending'){$pending++}
            elseif($i.status -eq 'running'){$running++}
            elseif($i.status -eq 'waiting' -or $i.status -eq 'monitoring'){$waiting++}
            elseif($i.status -eq 'waiting_owner'){$owner++}
            elseif($i.status -eq 'needs_attention' -or $i.status -eq 'reconciling'){$attention++}
            $name=if($i.title){[string]$i.title}else{[string]$i.prompt}
            $values=[object[]]@([string]$i.id,[string](Get-QueueStatusText ([string]$i.status) ([string]$i.mode)),$name,[string]$i.cwd,[string]$i.session,(Display-Time $i.detectedResetAt),(Display-Time $i.waitUntil))
            [void]$script:Grid.Rows.Add($values);$row=$script:Grid.Rows[$script:Grid.Rows.Count-1];$tip=[string]$i.prompt;if($i.detectedResetAt -and $i.waitUntil){$row.Cells[6].ToolTipText='重置 '+([datetime]$i.detectedResetAt).ToString('MM-dd HH:mm')+' + 缓冲 '+(Get-BufferMinutes $i)+' 分钟 = '+([datetime]$i.waitUntil).ToString('MM-dd HH:mm')+' 启动'};if($i.lastError){$row.Cells[1].ToolTipText=[string]$i.lastError+[Environment]::NewLine+'类别：'+[string]$i.errorKind+[Environment]::NewLine+'原会话：'+[string]$i.originalThreadId+[Environment]::NewLine+'退出码：'+[string]$i.lastExitCode;$row.Cells[0].ToolTipText=$row.Cells[1].ToolTipText};if(Test-WhiteSpace $tip){$tip=$script:DefaultPrompt};$row.Cells[2].ToolTipText='续跑指令：'+$tip
        }
        if($script:ManualTime){$nextManual=$null;foreach($i in @($script:Items)){if([string]$i.mode -eq 'manual' -and $i.manualResetAt){try{$candidate=[datetime]$i.manualResetAt;if((-not $nextManual) -or $candidate -lt $nextManual){$nextManual=$candidate}}catch{}}};if($nextManual){$script:ManualTime.Value=$nextManual}}
        if($script:MonitorInfo){$script:MonitorInfo.Text="当前监控：$count 个任务（列表中可右键删除）"}
        $script:Status.Text=if($script:Paused){'已暂停（当前任务完成后不再启动新任务）'}else{"调度器运行中 · $count 个任务 · 执行中 $running · 等待额度 $waiting · 等待释放 $owner · 需处理 $attention · 待处理 $pending"}
        $script:Grid.Visible=$true
        $script:Grid.BringToFront()
        $script:Grid.Refresh()
    }catch{
        if($script:Status){$script:Status.Text="列表刷新失败：$($_.Exception.Message)"}
    }finally{$script:Grid.ResumeLayout()}
}
function Get-Selected-QueueItem{
    $row=$script:Grid.CurrentRow
    if(-not$row){return $null}
    $id=[string]$row.Cells[0].Value
    foreach($item in @($script:Items)){if([string]$item.id -eq $id){return $item}}
    return $null
}
function Show-QueueDetails{
    $item=Get-Selected-QueueItem
    if(-not$item){[Windows.Forms.MessageBox]::Show('请先选择一个任务。','查看任务详情')|Out-Null;return}
    $output=[string]$item.lastOutput
    if($item.outputPath -and (Test-Path -LiteralPath $item.outputPath)){try{$output=[IO.File]::ReadAllText([string]$item.outputPath)}catch{}}
    $text='状态：'+(Get-QueueStatusText ([string]$item.status) ([string]$item.mode))+[Environment]::NewLine+
        '错误类别：'+[string]$item.errorKind+[Environment]::NewLine+
        '错误说明：'+[string]$item.lastError+[Environment]::NewLine+
        '退出码：'+[string]$item.lastExitCode+[Environment]::NewLine+
        '原会话 ID：'+[string]$item.originalThreadId+[Environment]::NewLine+
        '执行方式：'+[string]$item.executionMode+[Environment]::NewLine+
        'Codex Home：'+[string]$item.codexHome+[Environment]::NewLine+
        '最近所有者：'+[string]$item.ownerKind+' PID '+[string]$item.ownerPid+[Environment]::NewLine+
        '尝试 ID：'+[string]$item.attemptId+[Environment]::NewLine+
        'Codex：'+[string]$item.codexPath+' '+[string]$item.codexVersion+[Environment]::NewLine+
        '开始时间：'+[string]$item.started+[Environment]::NewLine+
        '下次检查：'+[string]$item.retryAt+[Environment]::NewLine+
        '日志文件：'+[string]$item.outputPath+[Environment]::NewLine+[Environment]::NewLine+
        '--- Codex 输出 ---'+[Environment]::NewLine+$output
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='任务详情与错误日志'
    $dialog.Size=New-Object Drawing.Size(850,560)
    $dialog.StartPosition='CenterParent'
    $box=New-Object Windows.Forms.TextBox
    $box.Multiline=$true;$box.ReadOnly=$true;$box.ScrollBars='Both';$box.WordWrap=$false;$box.Dock='Fill';$box.Text=$text
    $dialog.Controls.Add($box)
    [void]$dialog.ShowDialog($form)
}
function Retry-OriginalSession{
    $item=Get-Selected-QueueItem
    if(-not$item){[Windows.Forms.MessageBox]::Show('请先选择一个任务。','重试原会话')|Out-Null;return}
    if([string]$item.status -notin @('needs_attention','reconciling','error')){[Windows.Forms.MessageBox]::Show('该任务当前不需要人工重试。','重试原会话')|Out-Null;return}
    if([string]::IsNullOrWhiteSpace([string]$item.originalThreadId) -or [string]$item.session -ne [string]$item.originalThreadId){[Windows.Forms.MessageBox]::Show('原会话 ID 缺失或不一致，已阻止重试。','会话校验失败')|Out-Null;return}
    $confirm='将继续使用原会话 ID：'+[string]$item.originalThreadId+[Environment]::NewLine+[Environment]::NewLine+
        '只有在你确认上一轮没有成功提交（或已在原会话核对结果）时才继续。重复点击可能重复执行任务。'+[Environment]::NewLine+[Environment]::NewLine+
        '是否把任务放回队列？'
    if([Windows.Forms.MessageBox]::Show($confirm,'核对后重试原会话','YesNo','Warning') -ne 'Yes'){return}
    $item.status='pending';$item.errorKind='';$item.lastError='';$item.retryAt=$null;$item.submissionState='retry_authorized'
    Save-State;Refresh-Grid;Tick
}function Begin-Monitor($e,$mode,$manualText,$buffer,$customPrompt){$b=[int]$buffer;$pp=[string]$customPrompt;if(Test-WhiteSpace $pp){$pp=$script:DefaultPrompt};$matches=@();foreach($candidate in @($script:Items)){if([string]$candidate.session -eq [string]$e.id){$matches+=,$candidate}};if($matches.Count -gt 0){$item=$matches[0];if($matches.Count -gt 1){$keep=[string]$item.id;$left=@();foreach($candidate in @($script:Items)){if([string]$candidate.id -eq $keep -or [string]$candidate.session -ne [string]$e.id){$left+=,$candidate}};$script:Items=@($left)}}else{$item=[pscustomobject]@{id=(New-Id);title=$e.title;prompt=$pp;cwd=$e.cwd;session=$e.id;originalThreadId=$e.id;status='monitoring';monitorOnly=$true;mode='auto';bufferMinutes=2;manualResetAt=$null;created=(Get-Date).ToString('o');attempts=0;waitUntil=$null;lastError='';detectedResetAt=$null;detectedAt=$null;detectedSource='';_process=$null};$script:Items=@($script:Items)+@($item)};Ensure-Props $item;if($item.status -eq 'running' -or ($item._process -and -not $item._process.HasExited)){throw '该原会话当前有调度器任务正在运行，不能重复开始监控'};$item.title=$e.title;$item.cwd=$e.cwd;$item.session=$e.id;$item.originalThreadId=$e.id;$item.codexHome=$script:CodexHome;$item.executionMode='managedResume';$item.mode=$mode;$item.bufferMinutes=$b;$item.prompt=$pp;$item.promptSnapshot='';$item.lastError='';$item.errorKind='';$item.retryAt=$null;$item.retryCount=0;$item.ownerConflictCount=0;$item.waitUntil=$null;$item.detectedResetAt=$null;$item.detectedAt=$null;$item.detectedSource='';$item.limitConfirmed=$false;if($mode -eq 'manual'){$d=Normalize-ManualReset (Parse-ManualReset $manualText) $b;$item.manualResetAt=$d.ToString('o');$item.waitUntil=$d.AddMinutes($b).ToString('o');$item.status='waiting';$item.monitorOnly=$false}else{$item.manualResetAt=$null;$item.status='monitoring';$item.monitorOnly=$true};Save-State;Refresh-Grid;return $item}
$mutexName='Local\FiveHourLimitGetLost-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:InstanceMutex=New-Object Threading.Mutex($false,$mutexName)
try{$mutexAcquired=$script:InstanceMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$mutexAcquired=$true}
if(-not $mutexAcquired){[Windows.Forms.MessageBox]::Show('调度器已经运行。为避免重复提交同一 Codex 会话，本实例将退出。','已在运行','OK','Information')|Out-Null;$script:InstanceMutex.Dispose();exit}
$script:Items=@(Load-State)
foreach($item in @($script:Items)){
    $item|Add-Member -NotePropertyName _process -NotePropertyValue $null -Force
    Ensure-Props $item
    if(-not$item.mode){$item.mode='auto'}
    if([string]::IsNullOrWhiteSpace([string]$item.codexHome)){$item.codexHome=$script:CodexHome}
    if(-not$item.executionMode){$item.executionMode='managedResume'}
    if($null -eq $item.bufferMinutes){$item.bufferMinutes=2}
    if(-not($item.PSObject.Properties.Name -contains 'manualResetAt')){$item|Add-Member -NotePropertyName manualResetAt -NotePropertyValue $null -Force}
    if($item.status -eq 'waiting' -and [string]$item.mode -eq 'auto' -and -not$item.waitUntil -and -not$item.retryAt){$item.retryAt=(Get-Date).ToString('o')}
}
Save-State
$script:ResetCacheAt=$null
$script:ResetCache=$null
$script:ResetCacheSession=''
$script:ResetCacheHome=$script:CodexHome
$script:Paused=$false
$form=New-Object Windows.Forms.Form
$form.Text='Five-Hour Limit, Get Lost! v0.2.0'
$form.Size=New-Object Drawing.Size(1120,650)
$form.StartPosition='CenterScreen'
$script:IconFile=Join-Path $PSScriptRoot 'five_hour_limit_icon.ico'
if(Test-Path -LiteralPath $script:IconFile){try{$form.Icon=[Drawing.Icon]::new($script:IconFile)}catch{}}
$top=New-Object Windows.Forms.Panel
$top.Dock='Top'
$top.Height=205
$form.Controls.Add($top)
$l=New-Object Windows.Forms.Label
$l.Text='监管已有 Codex 任务：选择任务后点击“开始监控”'
$l.Location='10,10'
$l.AutoSize=$true
$top.Controls.Add($l)
$sessionBox=New-Object Windows.Forms.ComboBox
$sessionBox.DropDownStyle='DropDownList'
$sessionBox.Location='10,35'
$sessionBox.Size='700,25'
$sessionBox.DisplayMember='Display'
$top.Controls.Add($sessionBox)
$refresh=New-Object Windows.Forms.Button
$refresh.Text='刷新任务'
$refresh.Location='720,33'
$refresh.Size='100,28'
$top.Controls.Add($refresh)
$watch=New-Object Windows.Forms.Button
$watch.Text='开始监控'
$watch.Location='830,33'
$watch.Size='110,28'
$top.Controls.Add($watch)
$delete=New-Object Windows.Forms.Button
$delete.Text='一键全删'
$delete.Location='950,33'
$delete.Size='110,28'
$top.Controls.Add($delete)
$modeLabel=New-Object Windows.Forms.Label
$modeLabel.Text='调度模式：'
$modeLabel.Location='10,70'
$modeLabel.AutoSize=$true
$top.Controls.Add($modeLabel)
$modeBox=New-Object Windows.Forms.ComboBox
$modeBox.DropDownStyle='DropDownList'
$modeBox.Location='78,66'
$modeBox.Size='190,25'
[void]$modeBox.Items.Add('自动检测（读取本地日志）')
[void]$modeBox.Items.Add('手动五小时循环（推荐）')
$modeBox.SelectedIndex=0
$top.Controls.Add($modeBox)
$resetLabel=New-Object Windows.Forms.Label
$resetLabel.Text='下一次恢复：'
$resetLabel.Location='285,70'
$resetLabel.AutoSize=$true
$top.Controls.Add($resetLabel)
$manualTime=New-Object Windows.Forms.DateTimePicker
$manualTime.Location='365,66'
$manualTime.Size='95,25'
$manualTime.Format='Custom'
$manualTime.CustomFormat='HH:mm'
$manualTime.ShowUpDown=$true
$manualTime.Value=(Get-Date).AddHours(5)
$manualTime.Enabled=$false
$top.Controls.Add($manualTime)
$bufferLabel=New-Object Windows.Forms.Label
$bufferLabel.Text='缓冲分钟：'
$bufferLabel.Location='475,70'
$bufferLabel.AutoSize=$true
$top.Controls.Add($bufferLabel)
$bufferBox=New-Object Windows.Forms.NumericUpDown
$bufferBox.Location='550,66'
$bufferBox.Size='55,25'
$bufferBox.Minimum=0
$bufferBox.Maximum=60
$bufferBox.Value=2
$bufferBox.Enabled=$false
$top.Controls.Add($bufferBox)
$bufferHint=New-Object Windows.Forms.Label
$bufferHint.Text='（只按本机系统时间，不联网）'
$bufferHint.Location='610,70'
$bufferHint.AutoSize=$true
$bufferHint.ForeColor=[Drawing.Color]::DimGray
$top.Controls.Add($bufferHint)
$clockLabel=New-Object Windows.Forms.Label
$clockLabel.Text='本机时间：'+(Get-Date).ToString('HH:mm:ss')
$clockLabel.Location='835,70'
$clockLabel.AutoSize=$true
$clockLabel.ForeColor=[Drawing.Color]::DimGray
$top.Controls.Add($clockLabel)
$promptLabel=New-Object Windows.Forms.Label
$promptLabel.Text='续跑指令：'
$promptLabel.Location='10,108'
$promptLabel.AutoSize=$true
$top.Controls.Add($promptLabel)
$promptBox=New-Object Windows.Forms.TextBox
$promptBox.Multiline=$true
$promptBox.ScrollBars='Vertical'
$promptBox.Location='78,103'
$promptBox.Size='980,42'
$promptBox.Text=$script:DefaultPrompt
$promptBox.Font=[Drawing.Font]::new('Microsoft YaHei UI',9)
$top.Controls.Add($promptBox)
$monitorInfo=New-Object Windows.Forms.Label
$monitorInfo.Text='当前监控：0 个任务'
$monitorInfo.Location='10,153'
$monitorInfo.AutoSize=$true
$monitorInfo.ForeColor=[Drawing.Color]::DimGray
$top.Controls.Add($monitorInfo)
$scheduleInfo=New-Object Windows.Forms.Label
$scheduleInfo.Text='自动检测模式：不会预先计算固定时间'
$scheduleInfo.Location='10,176'
$scheduleInfo.AutoSize=$true
$scheduleInfo.ForeColor=[Drawing.Color]::DimGray
$top.Controls.Add($scheduleInfo)
$content=New-Object Windows.Forms.Panel;$content.Dock='Fill';$content.BackColor=[Drawing.Color]::White;$form.Controls.Add($content)
$grid=New-Object Windows.Forms.DataGridView;$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false;$grid.AutoSizeColumnsMode='Fill';$grid.Dock='Fill';$grid.Visible=$true;$grid.BackgroundColor=[Drawing.Color]::White;$grid.GridColor=[Drawing.Color]::LightGray;$grid.ForeColor=[Drawing.Color]::Black;$grid.ColumnHeadersVisible=$true;$grid.RowHeadersVisible=$false;$grid.EnableHeadersVisualStyles=$false;$grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::Gainsboro;$grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::Black;$grid.DefaultCellStyle.BackColor=[Drawing.Color]::White;$grid.DefaultCellStyle.ForeColor=[Drawing.Color]::Black;$grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::SteelBlue;$grid.DefaultCellStyle.SelectionForeColor=[Drawing.Color]::White;$grid.RowTemplate.Height=26;$grid.ColumnHeadersHeight=28;$grid.ShowCellToolTips=$true;$content.Controls.Add($grid);foreach($c in @(@('ID',70),@('状态',120),@('任务名',320),@('自动识别的目录',180),@('会话',180),@('限额重置于',150),@('等待至',150))){$col=New-Object Windows.Forms.DataGridViewTextBoxColumn;$col.HeaderText=$c[0];$col.Width=$c[1];[void]$grid.Columns.Add($col)}
$bottom=New-Object Windows.Forms.StatusStrip;$form.Controls.Add($bottom);$status=New-Object Windows.Forms.ToolStripStatusLabel;$bottom.Items.Add($status)|Out-Null;$form.Controls.SetChildIndex($content,0);$script:Grid=$grid;$script:Status=$status;$script:MonitorInfo=$monitorInfo;$script:ScheduleInfo=$scheduleInfo;$script:ManualTime=$manualTime
function Update-PromptBox($e){if(-not$e){return};$found=$null;foreach($i in @($script:Items)){if([string]$i.session -eq [string]$e.id){$found=$i;break}};if($found -and -not(Test-WhiteSpace ([string]$found.prompt))){$promptBox.Text=[string]$found.prompt}else{$promptBox.Text=$script:DefaultPrompt}}
$sessionBox.Add_SelectedIndexChanged({try{Update-PromptBox $sessionBox.SelectedItem}catch{}})
$refresh.Add_Click({try{$script:Existing=@(Get-ExistingSessions);$sessionBox.Items.Clear();if($script:Existing.Count -gt 0){[void]$sessionBox.Items.AddRange([object[]]$script:Existing);$sessionBox.SelectedIndex=0;$script:Status.Text=('已找到 '+$script:Existing.Count+' 个本地任务，请选择后点击开始监控')}else{[Windows.Forms.MessageBox]::Show('没有找到本机 Codex 会话。请先在 Codex 中打开或运行一次任务，然后再刷新。','没有任务')}}catch{[Windows.Forms.MessageBox]::Show("读取任务失败：$($_.Exception.Message)",'刷新失败')}})
$modeBox.Add_SelectedIndexChanged({$manual=$modeBox.SelectedIndex -eq 1;$manualTime.Enabled=$manual;$bufferBox.Enabled=$manual;if($manual){$scheduleInfo.Text='五小时恢复计划：'+(Cycle-Preview $manualTime.Value 6)+'（运行时间=恢复后+'+$bufferBox.Value+'分钟）'}else{$scheduleInfo.Text='自动检测模式：不会预先计算固定时间';Update-DetectInfo}})
$manualTime.Add_ValueChanged({if($modeBox.SelectedIndex -eq 1){$scheduleInfo.Text='五小时恢复计划：'+(Cycle-Preview $manualTime.Value 6)+'（运行时间=恢复后+'+$bufferBox.Value+'分钟）'}})
$bufferBox.Add_ValueChanged({if($modeBox.SelectedIndex -eq 1){$scheduleInfo.Text='五小时恢复计划：'+(Cycle-Preview $manualTime.Value 6)+'（运行时间=恢复后+'+$bufferBox.Value+'分钟）'}})
$watch.Add_Click({try{$e=$sessionBox.SelectedItem;if(-not$e){[Windows.Forms.MessageBox]::Show('请先选择一个已有任务。');return};$mode=if($modeBox.SelectedIndex -eq 1){'manual'}else{'auto'};$manualText=$manualTime.Value.ToString('HH:mm');$pp=$promptBox.Text;if(Test-WhiteSpace $pp){$pp=$script:DefaultPrompt};$item=Begin-Monitor $e $mode $manualText ([int]$bufferBox.Value) $pp;if($mode -eq 'manual'){$d=[datetime]$item.manualResetAt;$when=$d.AddMinutes([int]$item.bufferMinutes);$plan=Cycle-Preview $d 6;[Windows.Forms.MessageBox]::Show("已启用手动五小时循环：$($e.title)`n`n恢复计划：$plan`n首次运行时间：$($when.ToString('HH:mm'))`n之后每次自动顺延 5 小时，并预留 $($item.bufferMinutes) 分钟。`n`n时间依据：本机系统时间（不联网）。",'手动监控已启用')}else{[Windows.Forms.MessageBox]::Show("已启用自动检测：$($e.title)`n`n如果本地日志读不到限额信息，可切换为手动五小时循环。",'自动监控已启用')}}catch{[Windows.Forms.MessageBox]::Show("监控任务失败：$($_.Exception.Message)",'操作失败')}})
$deleteAction={try{$row=$script:Grid.CurrentRow;if(-not$row){[Windows.Forms.MessageBox]::Show('请先选择要删除的监控任务。');return};$id=[string]$row.Cells[0].Value;$target=$null;foreach($i in @($script:Items)){if([string]$i.id -eq $id){$target=$i;break}};if(-not$target){return};$msg='只删除调度器中的监控记录，不会删除 Codex 原任务。'+[Environment]::NewLine+[Environment]::NewLine+'确定删除任务：'+$target.title+'？';$ok=[Windows.Forms.MessageBox]::Show($msg,'确认删除','YesNo','Warning');if($ok -ne 'Yes'){return};$new=@();foreach($i in @($script:Items)){if($i -ne $target){$new+=$i}};$script:Items=@($new);Save-State;Refresh-Grid}catch{[Windows.Forms.MessageBox]::Show("删除失败：$($_.Exception.Message)",'操作失败')}};$deleteAllAction={try{$count=@($script:Items).Count;if($count -eq 0){[Windows.Forms.MessageBox]::Show('当前没有监控记录。','一键全删');return};$msg='确定删除全部 '+$count+' 条监控记录吗？'+[Environment]::NewLine+'不会删除 Codex 原任务或项目文件。';$ok=[Windows.Forms.MessageBox]::Show($msg,'确认一键全删','YesNo','Warning');if($ok -ne 'Yes'){return};foreach($i in @($script:Items)){if($i._process -and -not$i._process.HasExited){$i._process.Kill()}};$script:Items=@();Save-State;Refresh-Grid}catch{[Windows.Forms.MessageBox]::Show("一键全删失败：$($_.Exception.Message)",'操作失败')}};$delete.Add_Click($deleteAllAction)
$menu=New-Object Windows.Forms.ContextMenuStrip;$mi=New-Object Windows.Forms.ToolStripMenuItem;$mi.Text='删除此监控任务';$menu.Items.Add($mi)|Out-Null;$mi.Add_Click($deleteAction);$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))|Out-Null;$mi2=New-Object Windows.Forms.ToolStripMenuItem;$mi2.Text='编辑续跑指令…';$menu.Items.Add($mi2)|Out-Null;$mi2.Add_Click({try{$row=$script:Grid.CurrentRow;if(-not$row){[Windows.Forms.MessageBox]::Show('请先选择一个任务。');return};$id=[string]$row.Cells[0].Value;$target=$null;foreach($i in @($script:Items)){if([string]$i.id -eq $id){$target=$i;break}};if(-not$target){return};$cur=[string]$target.prompt;if(Test-WhiteSpace $cur){$cur=$script:DefaultPrompt};$dlg=New-Object Windows.Forms.Form;$dlg.Text='编辑续跑指令';$dlg.Size=New-Object Drawing.Size(640,340);$dlg.StartPosition='CenterScreen';$dlg.MinimizeBox=$false;$dlg.MaximizeBox=$false;$tb=New-Object Windows.Forms.TextBox;$tb.Multiline=$true;$tb.ScrollBars='Vertical';$tb.Dock='Fill';$tb.Text=$cur;$dlg.Controls.Add($tb);$bp=New-Object Windows.Forms.Panel;$bp.Dock='Bottom';$bp.Height=44;$dlg.Controls.Add($bp);$bok=New-Object Windows.Forms.Button;$bok.Text='保存';$bok.Location='440,6';$bok.Size='85,30';$bp.Controls.Add($bok);$bc=New-Object Windows.Forms.Button;$bc.Text='取消';$bc.Location='535,6';$bc.Size='85,30';$bp.Controls.Add($bc);$bok.Add_Click({$dlg.Tag=$true;$dlg.Close()});$bc.Add_Click({$dlg.Close()});$dlg.AcceptButton=$bok;$dlg.CancelButton=$bc;[void]$dlg.ShowDialog($form);$v=$tb.Text;if($dlg.Tag -and -not(Test-WhiteSpace $v)){$target.prompt=$v.Trim();Save-State;Refresh-Grid;Update-PromptBox $sessionBox.SelectedItem}}catch{[Windows.Forms.MessageBox]::Show('保存失败：'+$_.Exception.Message,'操作失败')}});$miDetails=New-Object Windows.Forms.ToolStripMenuItem;$miDetails.Text='查看错误详情与日志';$menu.Items.Add($miDetails)|Out-Null;$miDetails.Add_Click({Show-QueueDetails});$miRetry=New-Object Windows.Forms.ToolStripMenuItem;$miRetry.Text='核对后重试原会话';$menu.Items.Add($miRetry)|Out-Null;$miRetry.Add_Click({Retry-OriginalSession});$grid.ContextMenuStrip=$menu;$grid.Add_CellMouseDown({param($sender,$e);if($e.Button -eq 'Right' -and $e.RowIndex -ge 0){$grid.ClearSelection();$grid.Rows[$e.RowIndex].Selected=$true;$grid.CurrentCell=$grid.Rows[$e.RowIndex].Cells[0]}})
$manualCount=0;foreach($i in @($script:Items)){if([string]$i.mode -eq 'manual'){$manualCount++}};if($manualCount -gt 0){$modeBox.SelectedIndex=1;$manualTime.Enabled=$true;$bufferBox.Enabled=$true}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=10000;$timer.Add_Tick({try{$clockLabel.Text='本机时间：'+(Get-Date).ToString('HH:mm:ss');Tick}catch{$script:Status.Text="本轮调度检查出错（计时器继续运行）：$($_.Exception.Message)"}});$timer.Start();$form.Add_FormClosing({$timer.Stop();foreach($i in @($script:Items)){if($i._process -and -not$i._process.HasExited){$i.status='reconciling';$i.errorKind='unknown_result';$i.submissionState='unknown';$i.lastError='窗口关闭时本轮尚未确认；重新打开后先核对结果再重试。';$i._process.Kill()}};Save-State;try{$script:InstanceMutex.ReleaseMutex()}catch{};$script:InstanceMutex.Dispose()});Refresh-Grid;[void]$form.ShowDialog()
