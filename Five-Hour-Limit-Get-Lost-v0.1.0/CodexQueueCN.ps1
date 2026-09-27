# Codex Queue CN - lightweight local Windows scheduler (no network service).
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:DataDir=Join-Path $env:LOCALAPPDATA 'CodexQueueCN';$script:StateFile=Join-Path $script:DataDir 'queue.json';$script:RunDir=Join-Path $script:DataDir 'runs'
$script:Codex=$null
New-Item -ItemType Directory -Force -Path $script:DataDir,$script:RunDir|Out-Null
function Load-State{if(Test-Path $script:StateFile){try{$x=Get-Content -Raw $script:StateFile|ConvertFrom-Json;if($x.items){return @($x.items)}}catch{}};return @()}
function Save-State{$clean=@();foreach($i in @($script:Items)){$clean+=[ordered]@{id=$i.id;title=$i.title;prompt=$i.prompt;cwd=$i.cwd;session=$i.session;status=$i.status;monitorOnly=$i.monitorOnly;mode=$i.mode;bufferMinutes=$i.bufferMinutes;manualResetAt=$i.manualResetAt;created=$i.created;attempts=$i.attempts;waitUntil=$i.waitUntil;lastError=$i.lastError;started=$i.started;finished=$i.finished;lastOutput=$i.lastOutput}};$o=[ordered]@{version=2;updated=(Get-Date).ToUniversalTime().ToString('o');items=$clean};$tmp="$script:StateFile.tmp";Set-Content -LiteralPath $tmp -Value (ConvertTo-Json -InputObject $o -Depth 8) -Encoding UTF8;Move-Item -Force $tmp $script:StateFile}
function New-Id{[guid]::NewGuid().ToString('N').Substring(0,8)}
function Resolve-Codex{$cmd=Get-Command codex.exe -ErrorAction SilentlyContinue;if($cmd -and $cmd.Path -and (Test-Path -LiteralPath $cmd.Path)){return $cmd.Path};$base=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin';if(Test-Path -LiteralPath $base){try{$candidates=@();foreach($p in [IO.Directory]::GetFiles($base,'codex.exe',[IO.SearchOption]::AllDirectories)){try{$candidates+=[pscustomobject]@{Path=$p;When=[IO.File]::GetLastWriteTimeUtc($p)}}catch{}};foreach($c in @($candidates|Sort-Object When -Descending)){if(Test-Path -LiteralPath $c.Path){return $c.Path}}}catch{}};return $null}
$script:Codex=Resolve-Codex;if(-not $script:Codex){$script:Codex='codex.exe'}
function Get-ExistingSessions{$idx=Join-Path $env:USERPROFILE '.codex\session_index.jsonl';$root=Join-Path $env:USERPROFILE '.codex\sessions';$out=@();if(-not(Test-Path $idx)){return $out};$lines=@(Get-Content $idx -Encoding UTF8 -ErrorAction SilentlyContinue);$start=[Math]::Max(0,$lines.Count-60);$records=@();for($li=$start;$li -lt $lines.Count;$li++){try{$records+=ConvertFrom-Json -InputObject $lines[$li]}catch{}};$paths=@();try{$paths=[IO.Directory]::GetFiles($root,'*.jsonl',[IO.SearchOption]::AllDirectories)}catch{};$byId=@{};foreach($path in $paths){$name=[IO.Path]::GetFileName($path);if($name -match '(?<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$'){$byId[$matches.id]=$path}};foreach($r in $records){try{$id=[string]$r.id;if(-not$id){continue};$cwd='';if($byId.ContainsKey($id)){try{$m=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $byId[$id] -Encoding UTF8 -TotalCount 1);if($m.payload.cwd){$cwd=$m.payload.cwd}}catch{}};$title=[string]$r.thread_name;if(-not$title){$title='未命名任务'};$out+=[pscustomobject]@{Display="$title  ·  $cwd";id=$id;title=$title;cwd=$cwd;updated=$r.updated_at}}catch{}};return @($out|Sort-Object updated -Descending|Sort-Object id -Unique)}
function Latest-Reset{$now=Get-Date;if($script:ResetCacheAt -and (($now-$script:ResetCacheAt).TotalSeconds -lt 60)){return $script:ResetCache};$root=Join-Path $env:USERPROFILE '.codex\sessions';if(-not(Test-Path $root)){return $null};$primaryBest=$null;$fallbackBest=$null;try{$paths=[IO.Directory]::GetFiles($root,'*.jsonl',[IO.SearchOption]::AllDirectories)}catch{return $null};$recent=@();foreach($path in $paths){try{$recent+=[pscustomobject]@{Path=$path;When=[IO.File]::GetLastWriteTimeUtc($path)}}catch{}};foreach($f in @($recent|Sort-Object When -Descending|Select-Object -First 8)){try{$rows=@(Get-Content -LiteralPath $f.Path -Tail 80 -ErrorAction Stop);foreach($row in $rows){if($row -notmatch 'rate_limits'){continue};try{$j=ConvertFrom-Json -InputObject $row}catch{continue};$r=$null;if($j.payload -and $j.payload.rate_limits){$r=$j.payload.rate_limits}elseif($j.rate_limits){$r=$j.rate_limits};if($r){foreach($n in @('primary','secondary','5h','five_hour')){$w=$r.$n;if($w -and $w.reset_at){try{$d=[DateTimeOffset]::FromUnixTimeSeconds([int64]$w.reset_at).LocalDateTime;if($w.window_minutes -eq 300 -or $n -in @('5h','five_hour')){if((-not $primaryBest)-or $d -gt $primaryBest){$primaryBest=$d}}elseif((-not $fallbackBest)-or $d -gt $fallbackBest){$fallbackBest=$d}}catch{}}}}}}catch{}};$best=if($primaryBest){$primaryBest}else{$fallbackBest};$script:ResetCacheAt=$now;$script:ResetCache=$best;if($best -and $best -gt(Get-Date)){return $best};return $null}
function Get-BufferMinutes($i){$b=2;try{if($null -ne $i.bufferMinutes){$b=[int]$i.bufferMinutes}}catch{};if($b -lt 0){$b=0};if($b -gt 60){$b=60};return $b}
function Parse-ManualReset($text){$t=[string]$text;if([string]::IsNullOrWhiteSpace($t)){throw '请选择下一次恢复时间（小时和分钟）'};$t=$t.Trim();if($t -notmatch '^\s*(\d{1,2}):(\d{2})\s*$'){throw '时间格式不正确，请选择 HH:mm'};$hh=[int]$matches[1];$mm=[int]$matches[2];if($hh -gt 23 -or $mm -gt 59){throw '时间格式不正确，请选择 HH:mm'};return (Get-Date).Date.AddHours($hh).AddMinutes($mm)}
function Normalize-ManualReset($d,$buffer){$next=[datetime]$d;$now=Get-Date;while($next.AddMinutes($buffer) -le $now){$next=$next.AddHours(5)};return $next}
function Cycle-Preview($d,$count){$parts=@();for($k=0;$k -lt $count;$k++){$parts+=([datetime]$d).AddHours(5*$k).ToString('HH:mm')};return ($parts -join ' → ')}
function Display-Time($v){if($v){try{return ([datetime]$v).ToString('HH:mm')}catch{}};return ''}
function Set-ManualWaiting($i){$b=Get-BufferMinutes $i;$next=[datetime]::MinValue;try{if($i.manualResetAt){$next=[datetime]$i.manualResetAt}}catch{};if($next -eq [datetime]::MinValue){$next=(Get-Date)};do{$next=$next.AddHours(5)}while($next.AddMinutes($b) -le (Get-Date));$i.manualResetAt=$next.ToString('o');$i.waitUntil=$next.AddMinutes($b).ToString('o');$i.status='waiting';$i.monitorOnly=$false}
function Is-LimitText($s){$s -match '(?i)usage limit|rate limit|you.ve hit|限额|达到.*限制|reset'}
function Arg($s){'"'+(($s -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1')+'"'}
function Start-Item($i){$resolved=Resolve-Codex;if($resolved){$script:Codex=$resolved}else{throw '找不到 codex.exe，请确认 Codex 已安装并重新打开调度器'};$psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$script:Codex;$work=if($i.cwd -and (Test-Path -LiteralPath $i.cwd)){[string]$i.cwd}else{(Get-Location).Path};$psi.WorkingDirectory=$work;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$a=@('exec','--json');if($i.session){$a+=@('resume',$i.session)};$a+=$i.prompt;$args=@();foreach($v in $a){$args+=Arg $v};$psi.Arguments=$args -join ' ';$p=New-Object Diagnostics.Process;$p.StartInfo=$psi;if(-not$p.Start()){throw '无法启动 codex.exe'};$i.status='running';$i.pid=$p.Id;$i.started=(Get-Date).ToString('o');$i|Add-Member -NotePropertyName _process -NotePropertyValue $p -Force;Save-State;Refresh-Grid}
function Finish-Item($i){$p=$i._process;if(-not$p){return};if(-not$p.HasExited){return};$t=(($p.StandardOutput.ReadToEnd())+"`n"+($p.StandardError.ReadToEnd()));if($t.Length -gt 20000){$t=$t.Substring($t.Length-20000)};$i.lastOutput=$t;foreach($line in($t -split "`r?`n")){try{$j=ConvertFrom-Json -InputObject $line;if($j.type -eq 'thread.started' -and $j.thread_id){$i.session=$j.thread_id}}catch{}};if($p.ExitCode -eq 0){$i.status='done';$i.finished=(Get-Date).ToString('o')}elseif((Is-LimitText $t) -or ([string]$i.mode -eq 'manual')){if([string]$i.mode -eq 'manual'){Set-ManualWaiting $i}else{$i.status='waiting';$r=Latest-Reset;$b=Get-BufferMinutes $i;if($r){$i.waitUntil=$r.AddMinutes($b).ToString('o')}else{$i.waitUntil=(Get-Date).AddHours(5).AddMinutes($b).ToString('o')}};$i.attempts=[int]$i.attempts+1}else{$i.status='error';$i.lastError="codex 退出码 $($p.ExitCode)"};$i._process=$null;Save-State;Refresh-Grid}
function Tick{$running=$false;foreach($i in @($script:Items)){if($i.status -eq 'running'){$running=$true;Finish-Item $i};if($i.status -eq 'monitoring' -and ([string]$i.mode -ne 'manual')){$r=Latest-Reset;if($r){$b=Get-BufferMinutes $i;$i.status='waiting';$i.waitUntil=$r.AddMinutes($b).ToString('o');$i.monitorOnly=$false;Save-State;Refresh-Grid}}};if($script:Paused -or $running){return};$now=Get-Date;foreach($i in @($script:Items)){if($i.status -eq 'waiting'){if((-not $i.waitUntil) -or ([datetime]$i.waitUntil) -le $now){$i.status='pending';$i.waitUntil=$null;Save-State}}};$n=$null;foreach($i in @($script:Items)){if($i.status -eq 'pending'){if((-not $n) -or ([datetime]$i.created) -lt ([datetime]$n.created)){$n=$i}}};if($n){try{Start-Item $n}catch{$err=$_.Exception.Message;if([string]$n.mode -eq 'manual'){ $n.lastError='本轮未能启动：'+$err;Set-ManualWaiting $n }else{$n.status='error';$n.lastError=$err};Save-State;Refresh-Grid}}}
function Status-CN($s,$mode){switch($s){'pending'{'等待执行'}'monitoring'{if($mode -eq 'manual'){'手动监控中'}else{'自动监控中（等待限额提示）'}}'running'{'执行中'}'waiting'{if($mode -eq 'manual'){'手动等待额度'}else{'等待额度恢复'}}'done'{'已完成'}'error'{'出错'}default{$s}}}
function Refresh-Grid{
    if(-not $script:Grid){return}
    try{
        $script:Grid.SuspendLayout()
        $script:Grid.Rows.Clear()
        $pending=0
        $running=0
        $waiting=0
        $count=0
        foreach($i in @($script:Items)){
            $count++
            if($i.status -eq 'pending'){$pending++}
            elseif($i.status -eq 'running'){$running++}
            elseif($i.status -eq 'waiting' -or $i.status -eq 'monitoring'){$waiting++}
            $name=if($i.title){[string]$i.title}else{[string]$i.prompt}
            $values=[object[]]@([string]$i.id,[string](Status-CN $i.status $i.mode),$name,[string]$i.cwd,[string]$i.session,(Display-Time $i.waitUntil))
            [void]$script:Grid.Rows.Add($values)
        }
        if($script:ManualTime){$nextManual=$null;foreach($i in @($script:Items)){if([string]$i.mode -eq 'manual' -and $i.manualResetAt){try{$candidate=[datetime]$i.manualResetAt;if((-not $nextManual) -or $candidate -lt $nextManual){$nextManual=$candidate}}catch{}}};if($nextManual){$script:ManualTime.Value=$nextManual}}
        if($script:MonitorInfo){$script:MonitorInfo.Text="当前监控：$count 个任务（列表中可右键删除）"}
        $script:Status.Text=if($script:Paused){'已暂停（当前任务完成后不再启动新任务）'}else{"调度器运行中 · $count 个任务 · 执行中 $running · 等待中 $waiting · 待处理 $pending"}
        $script:Grid.Visible=$true
        $script:Grid.BringToFront()
        $script:Grid.Refresh()
    }catch{
        if($script:Status){$script:Status.Text="列表刷新失败：$($_.Exception.Message)"}
    }finally{$script:Grid.ResumeLayout()}
}
function Begin-Monitor($e,$mode,$manualText,$buffer){$b=[int]$buffer;$matches=@();foreach($candidate in @($script:Items)){if([string]$candidate.session -eq [string]$e.id -and $candidate.status -notin @('done','error')){$matches+=,$candidate}};if($matches.Count -gt 0){$item=$matches[0];if($matches.Count -gt 1){$keep=[string]$item.id;$left=@();foreach($candidate in @($script:Items)){if([string]$candidate.id -eq $keep -or [string]$candidate.session -ne [string]$e.id){$left+=,$candidate}};$script:Items=@($left)}}else{$item=[pscustomobject]@{id=(New-Id);title=$e.title;prompt='继续完成上一个任务：先检查当前状态，再继续原计划。';cwd=$e.cwd;session=$e.id;status='monitoring';monitorOnly=$true;mode='auto';bufferMinutes=2;manualResetAt=$null;created=(Get-Date).ToString('o');attempts=0;waitUntil=$null;lastError='';_process=$null};$script:Items=@($script:Items)+@($item)};$item.title=$e.title;$item.cwd=$e.cwd;$item.session=$e.id;$item.mode=$mode;$item.bufferMinutes=$b;$item.lastError='';if($mode -eq 'manual'){$d=Normalize-ManualReset (Parse-ManualReset $manualText) $b;$item.manualResetAt=$d.ToString('o');$item.waitUntil=$d.AddMinutes($b).ToString('o');if(-not($item._process -and -not $item._process.HasExited)){$item.status='waiting'};$item.monitorOnly=$false}else{$item.manualResetAt=$null;$item.waitUntil=$null;if(-not($item._process -and -not $item._process.HasExited)){$item.status='monitoring'};$item.monitorOnly=$true};Save-State;Refresh-Grid;return $item}
$script:Items=@(Load-State);foreach($i in @($script:Items)){$i|Add-Member -NotePropertyName _process -NotePropertyValue $null -Force;if(-not $i.mode){$i|Add-Member -NotePropertyName mode -NotePropertyValue 'auto' -Force};if($null -eq $i.bufferMinutes){$i|Add-Member -NotePropertyName bufferMinutes -NotePropertyValue 2 -Force};if(-not($i.PSObject.Properties.Name -contains 'manualResetAt')){$i|Add-Member -NotePropertyName manualResetAt -NotePropertyValue $null -Force}};foreach($i in @($script:Items)){if([string]$i.mode -eq 'manual' -and [string]$i.status -eq 'error' -and [string]$i.lastError -match '启动|Start|codex.exe|找不到'){Set-ManualWaiting $i;$i.lastError=''}};Save-State;$script:ResetCacheAt=$null;$script:ResetCache=$null;$script:Paused=$false;$form=New-Object Windows.Forms.Form;$form.Text='Five-Hour Limit, Get Lost!';$form.Size=New-Object Drawing.Size(1120,650);$form.StartPosition='CenterScreen';$script:IconFile=Join-Path $PSScriptRoot 'five_hour_limit_icon.ico';if(Test-Path -LiteralPath $script:IconFile){try{$form.Icon=[Drawing.Icon]::new($script:IconFile)}catch{}}
$top=New-Object Windows.Forms.Panel
$top.Dock='Top'
$top.Height=155
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
$monitorInfo=New-Object Windows.Forms.Label
$monitorInfo.Text='当前监控：0 个任务'
$monitorInfo.Location='10,103'
$monitorInfo.AutoSize=$true
$monitorInfo.ForeColor=[Drawing.Color]::DimGray
$top.Controls.Add($monitorInfo)
$scheduleInfo=New-Object Windows.Forms.Label
$scheduleInfo.Text='自动检测模式：不会预先计算固定时间'
$scheduleInfo.Location='10,126'
$scheduleInfo.AutoSize=$true
$scheduleInfo.ForeColor=[Drawing.Color]::DimGray
$top.Controls.Add($scheduleInfo)
$content=New-Object Windows.Forms.Panel;$content.Dock='Fill';$content.BackColor=[Drawing.Color]::White;$form.Controls.Add($content)
$grid=New-Object Windows.Forms.DataGridView;$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false;$grid.AutoSizeColumnsMode='Fill';$grid.Dock='Fill';$grid.Visible=$true;$grid.BackgroundColor=[Drawing.Color]::White;$grid.GridColor=[Drawing.Color]::LightGray;$grid.ForeColor=[Drawing.Color]::Black;$grid.ColumnHeadersVisible=$true;$grid.RowHeadersVisible=$false;$grid.EnableHeadersVisualStyles=$false;$grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::Gainsboro;$grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::Black;$grid.DefaultCellStyle.BackColor=[Drawing.Color]::White;$grid.DefaultCellStyle.ForeColor=[Drawing.Color]::Black;$grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::SteelBlue;$grid.DefaultCellStyle.SelectionForeColor=[Drawing.Color]::White;$grid.RowTemplate.Height=26;$grid.ColumnHeadersHeight=28;$content.Controls.Add($grid);foreach($c in @(@('ID',70),@('状态',120),@('任务名',320),@('自动识别的目录',180),@('会话',180),@('等待至',150))){$col=New-Object Windows.Forms.DataGridViewTextBoxColumn;$col.HeaderText=$c[0];$col.Width=$c[1];[void]$grid.Columns.Add($col)}
$bottom=New-Object Windows.Forms.StatusStrip;$form.Controls.Add($bottom);$status=New-Object Windows.Forms.ToolStripStatusLabel;$bottom.Items.Add($status)|Out-Null;$form.Controls.SetChildIndex($content,0);$script:Grid=$grid;$script:Status=$status;$script:MonitorInfo=$monitorInfo;$script:ScheduleInfo=$scheduleInfo;$script:ManualTime=$manualTime
$refresh.Add_Click({try{$script:Existing=@(Get-ExistingSessions);$sessionBox.Items.Clear();if($script:Existing.Count -gt 0){[void]$sessionBox.Items.AddRange([object[]]$script:Existing);$sessionBox.SelectedIndex=0;$script:Status.Text=('已找到 '+$script:Existing.Count+' 个本地任务，请选择后点击开始监控')}else{[Windows.Forms.MessageBox]::Show('没有找到本机 Codex 会话。请先在 Codex 中打开或运行一次任务，然后再刷新。','没有任务')}}catch{[Windows.Forms.MessageBox]::Show("读取任务失败：$($_.Exception.Message)",'刷新失败')}})
$modeBox.Add_SelectedIndexChanged({$manual=$modeBox.SelectedIndex -eq 1;$manualTime.Enabled=$manual;$bufferBox.Enabled=$manual;if($manual){$scheduleInfo.Text='五小时恢复计划：'+(Cycle-Preview $manualTime.Value 6)+'（运行时间=恢复后+'+$bufferBox.Value+'分钟）'}else{$scheduleInfo.Text='自动检测模式：不会预先计算固定时间'}})
$manualTime.Add_ValueChanged({if($modeBox.SelectedIndex -eq 1){$scheduleInfo.Text='五小时恢复计划：'+(Cycle-Preview $manualTime.Value 6)+'（运行时间=恢复后+'+$bufferBox.Value+'分钟）'}})
$bufferBox.Add_ValueChanged({if($modeBox.SelectedIndex -eq 1){$scheduleInfo.Text='五小时恢复计划：'+(Cycle-Preview $manualTime.Value 6)+'（运行时间=恢复后+'+$bufferBox.Value+'分钟）'}})
$watch.Add_Click({try{$e=$sessionBox.SelectedItem;if(-not$e){[Windows.Forms.MessageBox]::Show('请先选择一个已有任务。');return};$mode=if($modeBox.SelectedIndex -eq 1){'manual'}else{'auto'};$manualText=$manualTime.Value.ToString('HH:mm');$item=Begin-Monitor $e $mode $manualText ([int]$bufferBox.Value);if($mode -eq 'manual'){$d=[datetime]$item.manualResetAt;$when=$d.AddMinutes([int]$item.bufferMinutes);$plan=Cycle-Preview $d 6;[Windows.Forms.MessageBox]::Show("已启用手动五小时循环：$($e.title)`n`n恢复计划：$plan`n首次运行时间：$($when.ToString('HH:mm'))`n之后每次自动顺延 5 小时，并预留 $($item.bufferMinutes) 分钟。`n`n时间依据：本机系统时间（不联网）。",'手动监控已启用')}else{[Windows.Forms.MessageBox]::Show("已启用自动检测：$($e.title)`n`n如果本地日志读不到限额信息，可切换为手动五小时循环。",'自动监控已启用')}}catch{[Windows.Forms.MessageBox]::Show("监控任务失败：$($_.Exception.Message)",'操作失败')}})
$deleteAction={try{$row=$script:Grid.CurrentRow;if(-not$row){[Windows.Forms.MessageBox]::Show('请先选择要删除的监控任务。');return};$id=[string]$row.Cells[0].Value;$target=$null;foreach($i in @($script:Items)){if([string]$i.id -eq $id){$target=$i;break}};if(-not$target){return};$msg='只删除调度器中的监控记录，不会删除 Codex 原任务。'+[Environment]::NewLine+[Environment]::NewLine+'确定删除任务：'+$target.title+'？';$ok=[Windows.Forms.MessageBox]::Show($msg,'确认删除','YesNo','Warning');if($ok -ne 'Yes'){return};$new=@();foreach($i in @($script:Items)){if($i -ne $target){$new+=$i}};$script:Items=@($new);Save-State;Refresh-Grid}catch{[Windows.Forms.MessageBox]::Show("删除失败：$($_.Exception.Message)",'操作失败')}};$deleteAllAction={try{$count=@($script:Items).Count;if($count -eq 0){[Windows.Forms.MessageBox]::Show('当前没有监控记录。','一键全删');return};$msg='确定删除全部 '+$count+' 条监控记录吗？'+[Environment]::NewLine+'不会删除 Codex 原任务或项目文件。';$ok=[Windows.Forms.MessageBox]::Show($msg,'确认一键全删','YesNo','Warning');if($ok -ne 'Yes'){return};foreach($i in @($script:Items)){if($i._process -and -not$i._process.HasExited){$i._process.Kill()}};$script:Items=@();Save-State;Refresh-Grid}catch{[Windows.Forms.MessageBox]::Show("一键全删失败：$($_.Exception.Message)",'操作失败')}};$delete.Add_Click($deleteAllAction)
$menu=New-Object Windows.Forms.ContextMenuStrip;$mi=New-Object Windows.Forms.ToolStripMenuItem;$mi.Text='删除此监控任务';$menu.Items.Add($mi)|Out-Null;$mi.Add_Click($deleteAction);$grid.ContextMenuStrip=$menu;$grid.Add_CellMouseDown({param($sender,$e);if($e.Button -eq 'Right' -and $e.RowIndex -ge 0){$grid.ClearSelection();$grid.Rows[$e.RowIndex].Selected=$true;$grid.CurrentCell=$grid.Rows[$e.RowIndex].Cells[0]}})
$manualCount=0;foreach($i in @($script:Items)){if([string]$i.mode -eq 'manual'){$manualCount++}};if($manualCount -gt 0){$modeBox.SelectedIndex=1;$manualTime.Enabled=$true;$bufferBox.Enabled=$true}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=10000;$timer.Add_Tick({try{$clockLabel.Text='本机时间：'+(Get-Date).ToString('HH:mm:ss');Tick}catch{$script:Status.Text="自动检查出错，已暂停本轮检查：$($_.Exception.Message)";$timer.Stop()}});$timer.Start();$form.Add_FormClosing({$timer.Stop();foreach($i in @($script:Items)){if($i._process -and -not$i._process.HasExited){$i._process.Kill()}};Save-State});Refresh-Grid;[void]$form.ShowDialog()
