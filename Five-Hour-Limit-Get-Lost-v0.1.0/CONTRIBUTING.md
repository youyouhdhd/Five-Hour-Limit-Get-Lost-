# Contributing

Bug reports and small improvements are welcome.

Before opening an issue:

1. Reproduce the problem with a clean copy of the repository.
2. Include Windows and Codex CLI versions.
3. Remove usernames, project paths, transcripts, tokens, and other private data from screenshots and logs.

For code changes, keep the project dependency-free and local-only. Test PowerShell parsing with:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "[scriptblock]::Create((Get-Content -Raw .\CodexQueueCN.ps1)) | Out-Null; 'parse-ok'"
```

Do not add provider bypasses, hidden credentials, or unrestricted execution modes.
