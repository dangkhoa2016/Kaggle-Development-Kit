# Security Policy

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](SECURITY.vi.md)

## Supported use

This project targets a **single-user** development notebook environment, especially
Kaggle. Do not reuse the configuration unchanged for multi-user production.

PostgreSQL uses local `trust` authentication and Redis has no default password
because both bind to loopback only. Never expose those database ports directly
to the Internet.

## SSH / ngrok

`setup.sh` is intentionally safe to publish and contains no hard-coded
credentials. Credentials are resolved in this order:

1. environment variables;
2. `.kaggle-ssh/private.env`;
3. Kaggle Secrets.

sshd binds only to `127.0.0.1` and requires public-key authentication.
Passwords, PAM, keyboard-interactive authentication, agent forwarding, X11,
`GatewayPorts`, and SSH tunnel devices are disabled. Local TCP forwarding stays
enabled for VS Code Remote-SSH and development-service forwarding.

Keep these private:

- `.kaggle-ssh/private.env`;
- `.kaggle-ssh/host-keys/*_key`;
- `.kaggle-ssh/connection.txt`;
- `.kaggle-ssh/logs/`;
- all SSH client private keys;
- `NGROK_AUTHTOKEN` and other tokens/API keys.

`SSH_PUBLIC_KEY` is not a private key, but it is still personal environment
metadata and does not need to be committed.

`setup.sh --save-secrets` stores credentials base64 encoded in a mode `0600`
file. Base64 **is not encryption**. If a private bundle leaks, rotate the ngrok
token and remove/regenerate the SSH host keys before using it again.

The temporary ngrok config containing the token is removed after the tunnel has
published its endpoint.

## Local SSH ControlMaster sockets

`connect-kaggle.sh` keeps one long-lived SSH ControlMaster per profile. Its socket is a local privileged resource: anyone who can reach it can reuse an authenticated connection. Generated sockets therefore live in a private per-user directory (mode `0700`) rather than directly in a shared temp root; the script rejects a symlink planted at that directory path and tightens a widened mode back to `0700`. Do not point `KAGGLE_CONNECT_CONTROL_PATH` into a directory other users can write to.

## Logs and connection metadata

ngrok/sshd logs, endpoints, and connection metadata can contain IP addresses,
hostnames, ports, and activity information. Redact them before publishing.

## Reporting a vulnerability

Never post credentials, tokens, database dumps, or sensitive information to a
public issue. When creating the GitHub repository, enable private vulnerability
reporting in Security settings and use that channel for reports.

## Before publishing logs or artifacts

Remove at minimum:

- `.kaggle-ssh/` and `.system/`;
- environment variables, `.env*`, and `private.env`;
- private keys, access tokens, API keys, and credential-bearing URLs;
- `connection.txt` and ngrok/sshd logs;
- database dumps;
- logs containing queries or user data.
