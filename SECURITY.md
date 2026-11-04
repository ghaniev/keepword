# Security policy

Keepword keeps recordings, transcripts and notes on your computer. Data leaves the machine only when you choose a cloud transcription or AI provider, connect a calendar feed, download a model or connect an MCP server.

## Reporting a vulnerability

Please do not open a public issue. Report it privately through **Security → Report a vulnerability** on the GitHub repository, with:

- what the problem is and what an attacker could do with it;
- steps to reproduce, and the app version and OS;
- whether it is already public.

You will get an answer within a week. Fixes are released for the latest version.

## In scope

- data reaching the network without the user choosing a provider for it;
- the local MCP server (`127.0.0.1`) accepting requests without its token, or exposing more than intended;
- credentials (API keys, calendar addresses) stored outside the Keychain / Windows Credential Manager or written to logs;
- crafted audio, video, ICS or attachment files that make the app run code or touch files outside its library.
