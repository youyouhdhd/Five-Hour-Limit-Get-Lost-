$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repo 'Five-Hour-Limit-Get-Lost-v0.2.0\CodexQueueCN.ps1'
. (Join-Path $repo 'Five-Hour-Limit-Get-Lost-v0.2.0\QueueCore.ps1')

$astTokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($app, [ref]$astTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Application parser errors prevent runner test.' }
$wanted = @('Arg', 'Start-Item', 'Finish-Item')
$definitions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $node.Name }, $true)
if ($definitions.Count -ne $wanted.Count) { throw 'Could not load the production runner functions.' }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('QueueRunner-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fakeExe = Join-Path $temp 'fake-codex.exe'
$argsFile = Join-Path $temp 'prompt.txt'
$homeFile = Join-Path $temp 'codex-home.txt'
$threadId = '66666666-6666-6666-6666-666666666666'
$cs = @"
using System;
using System.IO;
public static class QueueRunnerFakeCodex {
    public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--version") { Console.WriteLine("codex-cli test"); return 0; }
        string path = Environment.GetEnvironmentVariable("FAKE_CODEX_PROMPT_FILE");
        if (!String.IsNullOrEmpty(path) && args.Length > 4) File.WriteAllText(path, args[4]);
        string homePath = Environment.GetEnvironmentVariable("FAKE_CODEX_HOME_FILE");
        if (!String.IsNullOrEmpty(homePath)) File.WriteAllText(homePath, Environment.GetEnvironmentVariable("CODEX_HOME") ?? "");
        if (Environment.GetEnvironmentVariable("FAKE_CODEX_BEHAVIOR") == "busy") {
            Console.Error.WriteLine("thread-store conflict: thread already has an active writer");
            return 1;
        }
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"$threadId\"}");
        Console.WriteLine("{\"type\":\"turn.started\",\"turn_id\":\"test-turn-1\"}");
        Console.WriteLine("resumed original conversation");
        return 0;
    }
}
"@
try {
    $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $compiler = New-Object System.CodeDom.Compiler.CompilerParameters
    $compiler.GenerateExecutable = $true
    $compiler.OutputAssembly = $fakeExe
    $compiler.ReferencedAssemblies.Add('System.dll') | Out-Null
    $compileResult = $provider.CompileAssemblyFromSource($compiler, $cs)
    if ($compileResult.Errors.HasErrors) { throw (($compileResult.Errors | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine) }
    $provider.Dispose()
    $script:Codex = $fakeExe
    $script:CodexHome = $temp
    $script:DefaultPrompt = 'continue'
    $script:RunDir = $temp
    $script:ResetCache = $null
    $script:ResetCacheAt = $null
    $script:Items = @()
    $script:Saved = 0
    function Resolve-Codex { return $script:Codex }
    function Test-WhiteSpace($value) { [string]::IsNullOrWhiteSpace([string]$value) }
    function Save-State { $script:Saved++ }
    function Refresh-Grid {}
    function Get-BufferMinutes($item) { return 2 }
    foreach ($definition in $definitions) { Invoke-Expression $definition.Extent.Text }

    $prompt = "继续原任务：`"保留会话`"`n下一行"
    $item = [pscustomobject]@{ id = 'runner01'; session = $threadId; originalThreadId = $threadId; title = 'runner test'; cwd = $temp; prompt = $prompt; status = 'pending'; mode = 'auto'; bufferMinutes = 2; created = (Get-Date).ToString('o'); attempts = 0; lastError = ''; lastOutput = ''; limitConfirmed = $false }
    $null = Initialize-QueueItem $item
    $script:Items = @($item)
    $env:FAKE_CODEX_PROMPT_FILE = $argsFile
    $env:FAKE_CODEX_HOME_FILE = $homeFile
    $env:FAKE_CODEX_BEHAVIOR = 'busy'
    Start-Item $item
    $item._process.WaitForExit()
    Finish-Item $item
    if ($item.status -ne 'waiting_owner' -or $item.errorKind -ne 'session_busy') { throw 'active writer did not enter waiting_owner' }
    if ($item.session -ne $threadId -or $item.originalThreadId -ne $threadId) { throw 'busy retry changed the original session id' }
    if (-not $item.retryAt -or -not (Test-Path -LiteralPath $item.outputPath)) { throw 'busy retry metadata or full output log missing' }

    $env:FAKE_CODEX_BEHAVIOR = 'success'
    $item.status = 'pending'
    Start-Item $item
    $item._process.WaitForExit()
    Finish-Item $item
    if ($item.status -ne 'done' -or $item.session -ne $threadId -or $item.turnId -ne 'test-turn-1') { throw 'released-session continuation did not finish on the original thread' }
    if ([IO.File]::ReadAllText($argsFile) -cne $prompt) { throw 'quoted multiline custom prompt did not survive ProcessStartInfo argument quoting' }
    if ([IO.File]::ReadAllText($homeFile) -cne $temp) { throw 'runner did not preserve the recorded Codex Home' }
    'Runner tests passed: busy handoff, same-thread resume, prompt quoting, streamed output, and turn ID capture'
} finally {
    if ($provider) { $provider.Dispose() }
    Remove-Item Env:FAKE_CODEX_PROMPT_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CODEX_HOME_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CODEX_BEHAVIOR -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($temp)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and $resolved -match 'QueueRunner-') {
        [IO.Directory]::Delete($resolved, $true)
    }
}
