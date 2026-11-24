## What and why

<!-- What does this change, and why is it needed? -->

Closes #

## Checklist

- [ ] CI (`validate`) is green
- [ ] Secrets only as SOPS-encrypted files under `clusters/*/secrets/`, nothing in plain text
- [ ] No real hostnames, tailnet names, IP addresses, tokens or personal data in code, docs or screenshots
- [ ] Images and charts use fixed versions (no `latest`)
- [ ] Docs and `CHANGELOG.md` updated if behaviour changes
