$ErrorActionPreference = 'Stop'
$core = Join-Path (Split-Path -Parent $PSScriptRoot) 'Five-Hour-Limit-Get-Lost-v0.2.0\QueueCore.ps1'
. $core

if ((Get-CodexErrorKind 'thread-store conflict: already has an active writer') -ne 'session_busy') { throw 'active writer classification failed' }
if ((Get-CodexErrorKind 'reset at 2026-09-27') -ne 'unknown') { throw 'generic reset text must not be treated as a limit' }
if ((Get-CodexErrorKind 'usage limit reached') -ne 'rate_limit') { throw 'rate limit classification failed' }
if ((Get-OwnerRetryDelaySeconds 1) -ne 15 -or (Get-OwnerRetryDelaySeconds 2) -ne 30 -or (Get-OwnerRetryDelaySeconds 8) -ne 60) { throw 'owner backoff failed' }

$now = [datetime]'2026-09-27T20:00:00'
$item = [pscustomobject]@{session='11111111-1111-1111-1111-111111111111';status='running';lastOutput='';ownerConflictCount=0}
$null = Initialize-QueueItem $item $now
if ($item.status -ne 'reconciling' -or $item.originalThreadId -ne $item.session) { throw 'restart migration must preserve ID and avoid duplicate submit' }

$busy = [pscustomobject]@{session='22222222-2222-2222-2222-222222222222';status='running';lastOutput='';ownerConflictCount=0;retryCount=0}
$null = Initialize-QueueItem $busy $now
$null = Set-QueueItemFailure $busy 'thread-store conflict: already has an active writer' 1 $now
if ($busy.status -ne 'waiting_owner' -or $busy.retryAt -ne $now.AddSeconds(15).ToString('o') -or $busy.session -ne $busy.originalThreadId -or $busy.submissionState -ne 'rejected') { throw 'safe owner retry transition failed' }

$unknown = [pscustomobject]@{session='33333333-3333-3333-3333-333333333333';status='running';lastOutput='';ownerConflictCount=0;retryCount=0}
$null = Initialize-QueueItem $unknown $now
$null = Set-QueueItemFailure $unknown 'connection reset by peer' 1 $now
if ($unknown.status -ne 'needs_attention' -or $unknown.retryAt -or $unknown.submissionState -ne 'unknown') { throw 'ambiguous result must not be retried automatically' }

if ((Get-QueueStatusText 'waiting_owner' 'auto') -ne '等待原会话释放') { throw 'waiting-owner UI status missing' }

$threadId = '44444444-4444-4444-4444-444444444444'
$args = Get-ResumeArguments $threadId "继续`n原任务"
if ($args.Count -ne 5 -or $args[0] -ne 'exec' -or $args[1] -ne 'resume' -or $args[3] -ne $threadId -or $args[4] -notmatch "原任务") { throw 'resume must use the exact original ID and prompt' }
$refused = $false
try { $null = Get-ResumeArguments '' 'prompt' } catch { $refused = $true }
if (-not $refused) { throw 'missing thread ID must never start a new session' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('QueueCore-' + [guid]::NewGuid().ToString('N'))
$sessionRoot = Join-Path $root 'sessions'
New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null
try {
    $otherId = '55555555-5555-5555-5555-555555555555'
    $future = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 7200
    $old = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 7200
    $aPath = Join-Path $sessionRoot ('rollout-' + $threadId + '.jsonl')
    $continuationPath = Join-Path $sessionRoot ('rollout-continuation-' + $threadId + '_branch.jsonl')
    $bPath = Join-Path $sessionRoot ('rollout-' + $otherId + '.jsonl')
    $aEvent = [ordered]@{ timestamp = [DateTimeOffset]::UtcNow.ToString('o'); payload = @{ rate_limits = @{ primary = @{ window_minutes = 300; resets_at = $future }; secondary = @{ window_minutes = 10080; resets_at = $future + 86400 } } } }
    $bEvent = [ordered]@{ timestamp = [DateTimeOffset]::UtcNow.ToString('o'); payload = @{ rate_limits = @{ primary = @{ window_minutes = 300; resets_at = $future + 3600 } } } }
    [IO.File]::WriteAllText($aPath, ($aEvent | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine)
    [IO.File]::WriteAllText($bPath, ($bEvent | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine)
    $reset = Get-SessionReset $sessionRoot $threadId $now
    if (-not $reset.ResetAt -or [int64]([DateTimeOffset]$reset.ResetAt).ToUnixTimeSeconds() -ne $future -or $reset.Scanned -ne 1 -or $reset.Total -ne 2 -or $reset.LimitConfirmed) { throw 'rate-limit telemetry alone must not trigger a resume' }
    $baseStamp = [DateTimeOffset]::UtcNow
    $userEvent = [ordered]@{ timestamp = $baseStamp.AddSeconds(1).ToString('o'); type = 'event_msg'; payload = @{ type = 'user_message'; message = 'synthetic test prompt' } }
    $assistantText = [ordered]@{ timestamp = $baseStamp.AddSeconds(2).ToString('o'); type = 'response_item'; payload = @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Usage limit reached is a phrase in this explanation, not an API failure.' }) } }
    $errorEvent = [ordered]@{ timestamp = $baseStamp.AddSeconds(3).ToString('o'); type = 'event_msg'; payload = @{ type = 'turn_failed'; error = @{ code = 'usage_limit_reached'; message = 'Usage limit reached' } } }
    [IO.File]::WriteAllText($continuationPath, ($userEvent | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine + ($assistantText | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine)
    $textOnly = Get-SessionReset $sessionRoot $threadId $now
    if ($textOnly.LimitConfirmed) { throw 'assistant prose mentioning a limit must not trigger a resume' }
    [IO.File]::AppendAllText($continuationPath, ($errorEvent | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine)
    $confirmed = Get-SessionReset $sessionRoot $threadId $now
    if (-not $confirmed.LimitConfirmed) { throw 'explicit limit failure after the latest user turn must be recognized' }
    $laterUser = [ordered]@{ timestamp = $baseStamp.AddSeconds(4).ToString('o'); type = 'event_msg'; payload = @{ type = 'user_message'; message = 'later turn' } }
    [IO.File]::AppendAllText($continuationPath, ($laterUser | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine)
    $superseded = Get-SessionReset $sessionRoot $threadId $now
    if ($superseded.LimitConfirmed) { throw 'a later user turn must supersede the old limit error' }
    $aEvent.payload.rate_limits.primary.resets_at = $old
    [IO.File]::WriteAllText($aPath, ($aEvent | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine)
    $past = Get-SessionReset $sessionRoot $threadId $now
    if ($past.ResetAt -ge $now -or $past.LimitConfirmed) { throw 'expired reset or later user turn must not be scheduled' }
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and $resolved -match 'QueueCore-') {
        [IO.Directory]::Delete($resolved, $true)
    }
}
'QueueCore tests passed'
