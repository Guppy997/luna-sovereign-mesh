# Security Policy

## Supported versions

Only the current state of `main` is supported. This repository describes a single running cluster, so there are no releases.

## Reporting a vulnerability

Please do **not** open a public issue. Report it privately through GitHub instead: **Security** tab, then **Report a vulnerability**. Only I can see the report.

Helpful details:
- the affected file, manifest or commit,
- steps to reproduce,
- what an attacker could achieve, for example reading data or reaching a service from outside the tailnet.

I will reply once I have seen the report and let you know when a fix is merged.

## Scope and known properties

- All services are reachable only inside a Tailscale tailnet. Nothing is exposed to the internet or the local network, see [docs/security.md](docs/security.md).
- Secrets are encrypted with SOPS and Age. The CI rejects plaintext secrets, private keys and tokens.
- Tailnet and machine names (`*.ts.net`) and internal IP addresses appear in the manifests on purpose. They are not secrets: Tailscale HTTPS certificates publish machine and tailnet names in public Certificate Transparency logs anyway, and the addresses are only routable inside the home network or the tailnet.
- Vulnerabilities in third-party components (Argo CD, Kyverno, Traefik and others) belong upstream. A note here is still welcome if this configuration makes one exploitable.
