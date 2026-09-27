function Get-CodexErrorKind([string]$Text) {
    if ($Text -match '(?i)thread-store conflict|already has an active writer|active writer') { return 'session_busy' }
    if ($Text -match '(?i)thread.?id mismatch|unexpected thread.?id') { return 'identity_mismatch' }
    if ($Text -match '(?i)usage_limit_reached|rate_limit_exceeded|usage limit reached|rate limit exceeded|too many requests|http\s*429|you.ve hit.*(?:limit|quota)|limit has been reached|限额|达到.*限制') { return 'rate_limit' }
    if ($Text -match '(?i)unauthorized|not authenticated|authentication required|login required|token expired|401') { return 'authentication' }
    if ($Text -match '(?i)approval required|waiting for approval|needs approval') { return 'approval' }
    if ($Text -match '(?i)connection reset|connection refused|timed out|temporarily unavailable|network error|dns') { return 'network' }
    return 'unknown'
}

function Get-OwnerRetryDelaySeconds([int]$ConflictCount) {
    if ($ConflictCount -le 1) { return 15 }
    if ($ConflictCount -eq 2) { return 30 }
    return 60
}

function Get-ResumeArguments([string]$ThreadId, [string]$Prompt) {
    if ($ThreadId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw 'A valid original thread ID is required; refusing to create a new session.'
    }
    return @('exec', 'resume', '--json', $ThreadId, $Prompt)
}

function Get-SessionReset([string]$Root, [string]$SessionId, [datetime]$Now = (Get-Date)) {
    $all = @()
    try {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw '会话日志目录不存在' }
        $all = @([IO.Directory]::GetFiles($Root, '*.jsonl', [IO.SearchOption]::AllDirectories))
    } catch {
        return [pscustomobject]@{ ResetAt = $null; ObservedAt = $null; Source = ''; Scanned = 0; Total = 0; Error = $_.Exception.Message; SessionId = $SessionId; LimitConfirmed = $false }
    }
    $total = $all.Count
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        $paths = @($all | Sort-Object { [IO.File]::GetLastWriteTimeUtc($_) } -Descending | Select-Object -First 8)
    } else {
        $escaped = [regex]::Escape($SessionId)
        $paths = @($all | Where-Object { [IO.Path]::GetFileName($_) -match $escaped })
    }
    if ($paths.Count -eq 0) {
        $errorText = if ($total -eq 0) { '没有找到 Codex 会话日志' } else { '找不到与原会话 ID 匹配的日志文件' }
        return [pscustomobject]@{ ResetAt = $null; ObservedAt = $null; Source = ''; Scanned = 0; Total = $total; Error = $errorText; SessionId = $SessionId; LimitConfirmed = $false }
    }
    $best = $null; $bestObserved = [datetime]::MinValue; $source = ''; $scanError = ''
    $lastUserAt = [datetime]::MinValue; $limitErrorAt = [datetime]::MinValue
    $scanned = 0
    foreach ($path in $paths) {
        $scanned++
        try {
            $fileTime = [IO.File]::GetLastWriteTime($path)
            $rows = @(Get-Content -LiteralPath $path -Tail 120 -ErrorAction Stop)
            for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
                $row = $rows[$rowIndex]
                try { $event = ConvertFrom-Json -InputObject $row -ErrorAction Stop } catch { continue }
                $payload = $event.payload
                $eventAt = $fileTime
                foreach ($field in @('timestamp', 'created_at')) {
                    if ($event.PSObject.Properties[$field]) { try { $eventAt = ([DateTimeOffset]::Parse([string]$event.$field)).LocalDateTime; break } catch {} }
                }
                if ((($event.type -eq 'event_msg' -and $payload.type -eq 'user_message') -or ($event.type -eq 'response_item' -and $payload.role -eq 'user')) -and $eventAt -ge $lastUserAt) { $lastUserAt = $eventAt }
                $quotaText = $row -match '(?i)usage_limit_reached|rate_limit_exceeded|usage limit reached|rate limit exceeded|you.ve hit.{0,80}(?:limit|quota)|limit has been reached|达到.{0,12}限制|用量限制'
                $errorEvent = ($payload.type -match '(?i)failed|error') -or ($payload.error -and (($payload.error.code -match '(?i)usage_limit|rate_limit') -or ($payload.error.type -match '(?i)usage_limit|rate_limit')))
                if ($quotaText -and $errorEvent -and $eventAt -ge $limitErrorAt) { $limitErrorAt = $eventAt }
                if ($row -notmatch 'rate_limits') { continue }
                $limits = $null
                if ($payload -and $payload.rate_limits) { $limits = $payload.rate_limits }
                elseif ($event.rate_limits) { $limits = $event.rate_limits }
                if (-not $limits) { continue }
                $observed = $eventAt
                foreach ($name in @('primary', 'secondary', '5h', 'five_hour')) {
                    $window = $limits.$name
                    if (-not $window) { continue }
                    $minutes = 0
                    try { $minutes = [int]$window.window_minutes } catch {}
                    if ($minutes -ne 300 -and $name -notin @('5h', 'five_hour')) { continue }
                    $stamp = $null
                    if ($window.PSObject.Properties['resets_at']) { $stamp = $window.resets_at }
                    elseif ($window.PSObject.Properties['reset_at']) { $stamp = $window.reset_at }
                    if (-not $stamp) { continue }
                    try { $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$stamp).LocalDateTime } catch { continue }
                    if ($observed -ge $bestObserved) { $best = $reset; $bestObserved = $observed; $source = [IO.Path]::GetFileName($path) }
                }
            }
        } catch { $scanError = $_.Exception.Message }
    }
    $limitConfirmed = $limitErrorAt -gt $lastUserAt
    return [pscustomobject]@{ ResetAt = $best; ObservedAt = $bestObserved; Source = $source; Scanned = $scanned; Total = $total; Error = $scanError; SessionId = $SessionId; LimitConfirmed = $limitConfirmed }
}

function Initialize-QueueItem($Item, [datetime]$Now = (Get-Date)) {
    $defaults = [ordered]@{
        title = ''
        prompt = ''
        cwd = ''
        originalThreadId = [string]$Item.session
        status = 'monitoring'
        mode = 'auto'
        monitorOnly = $true
        bufferMinutes = 2
        manualResetAt = $null
        waitUntil = $null
        retryAt = $null
        retryCount = 0
        attempts = 0
        lastError = ''
        errorKind = ''
        limitConfirmed = $false
        lastExitCode = $null
        ownerConflictCount = 0
        ownerKind = ''
        ownerPid = $null
        ownerStartedAt = $null
        executionMode = 'managedResume'
        codexHome = ''
        attemptId = ''
        turnId = ''
        submissionState = 'idle'
        codexPath = ''
        codexVersion = ''
        workerPid = $null
        workerStartedAt = $null
        outputPath = ''
        promptSnapshot = ''
        detectedResetAt = $null
        detectedAt = $null
        detectedSource = ''
        started = $null
        finished = $null
        lastOutput = ''
    }
    foreach ($name in $defaults.Keys) {
        if (-not ($Item.PSObject.Properties.Name -contains $name)) {
            $Item | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name]
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Item.originalThreadId)) { $Item.originalThreadId = [string]$Item.session }
    if ([string]$Item.originalThreadId) { $Item.session = [string]$Item.originalThreadId }
    if ($null -eq $Item.retryCount) { $Item.retryCount = 0 }
    if ($null -eq $Item.ownerConflictCount) { $Item.ownerConflictCount = 0 }

    # Never turn an unconfirmed old run into a new submission after a restart.
    if ([string]$Item.status -eq 'running') {
        $Item.status = 'reconciling'
        $Item.errorKind = 'unknown_result'
        $Item.submissionState = 'unknown'
        $Item.lastError = '调度器重启时上一轮结果未确认；核对原会话后再重试。'
    } elseif ([string]$Item.status -eq 'error' -and [string]$Item.lastOutput -match '(?i)thread-store conflict|already has an active writer') {
        $Item.status = 'waiting_owner'
        $Item.errorKind = 'session_busy'
        $Item.submissionState = 'rejected'
        $Item.ownerConflictCount = [Math]::Max(1, [int]$Item.ownerConflictCount)
        $Item.retryAt = $Now.AddSeconds((Get-OwnerRetryDelaySeconds $Item.ownerConflictCount)).ToString('o')
        $Item.lastError = '原会话仍被其他 Codex 实例占用；保留原会话，等待释放后重试。'
    }
    return $Item
}

function Set-QueueItemFailure($Item, [string]$Text, [int]$ExitCode, [datetime]$Now = (Get-Date)) {
    $Item.lastExitCode = $ExitCode
    $Item.finished = $Now.ToString('o')
    $Item.lastOutput = $Text
    $kind = Get-CodexErrorKind $Text
    $Item.errorKind = $kind
    $Item.submissionState = 'rejected'
    switch ($kind) {
        'session_busy' {
            $Item.submissionState = 'rejected'
            $Item.ownerKind = 'externalUnknown'
            $Item.ownerPid = $null
            $Item.ownerStartedAt = $null
            $Item.ownerConflictCount = [int]$Item.ownerConflictCount + 1
            $Item.retryCount = [int]$Item.retryCount + 1
            $Item.status = 'waiting_owner'
            $Item.retryAt = $Now.AddSeconds((Get-OwnerRetryDelaySeconds $Item.ownerConflictCount)).ToString('o')
            $Item.lastError = '原会话仍被其他 Codex 实例占用；未创建新会话，将于 ' + ([datetime]$Item.retryAt).ToString('HH:mm:ss') + ' 再检查。'
        }
        'rate_limit' {
            $Item.submissionState = 'rejected'
            $Item.status = 'waiting'
            $Item.retryAt = $Now.AddMinutes(1).ToString('o')
            $Item.lastError = 'Codex 再次报告用量限制；正在查找该会话的五小时恢复时间。'
        }
        default {
            $Item.submissionState = 'unknown'
            $Item.ownerKind = ''
            $Item.ownerPid = $null
            $Item.ownerStartedAt = $null
            $Item.status = 'needs_attention'
            $Item.retryAt = $null
            $Item.lastError = switch ($kind) {
                'identity_mismatch' { 'Codex 返回的会话 ID 与原会话不一致，已停止自动重试。' }
                'authentication' { 'Codex 登录状态异常；修复登录后再重试原会话。' }
                'approval' { 'Codex 正在等待审批；请在 Codex 界面完成审批后再核对任务。' }
                'network' { '网络错误导致本轮结果无法确认；为避免重复提交，已暂停自动重试。' }
                default { 'Codex 运行失败，自动重试已暂停；请查看错误详情。' }
            }
        }
    }
    return $Item
}

function Get-QueueStatusText([string]$Status, [string]$Mode) {
    switch ($Status) {
        'pending' { return '等待执行' }
        'monitoring' { if ($Mode -eq 'manual') { return '手动监控中' }; return '自动监控中' }
        'running' { return '续跑中' }
        'waiting' { if ($Mode -eq 'manual') { return '等待额度' }; return '等待额度/检测' }
        'waiting_owner' { return '等待原会话释放' }
        'reconciling' { return '核对上次结果' }
        'needs_attention' { return '需要处理' }
        'done' { return '本轮完成' }
        'error' { return '出错' }
        default { return $Status }
    }
}
