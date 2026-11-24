## What and why

<!-- What does this change, and why is it needed? -->

Closes #

## Checklist

- [ ] CI (`validate`) is green
- [ ] Secrets only as SOPS-encrypted files under `clusters/*/secrets/`, nothing in plain text
- [ ] No tokens, passwords, keys or personal data in code, docs or screenshots (tailnet and host names and internal IPs are documented on purpose, see `SECURITY.md`)
- [ ] Images and charts use fixed versions (no `latest`)
- [ ] Docs and `CHANGELOG.md` updated if behaviour changes
