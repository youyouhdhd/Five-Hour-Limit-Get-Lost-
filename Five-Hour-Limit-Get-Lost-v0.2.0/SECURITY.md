# Security

Please do not include private Codex transcripts, session files, authentication data, API keys, or unredacted scheduler logs in a public issue.

For a suspected security problem, open a private report through the repository's GitHub security contact if one is configured. Otherwise, create an issue containing only a minimal, sanitized description and wait for maintainer guidance before publishing details.

The scheduler is local-only by design. It invokes the Codex CLI already installed and authenticated for the current Windows user; it does not accept or transmit API keys.
