---
name: Device report
about: Tell us what worked on your phone (helps fill the "not yet verified" list)
labels: device-report
---

**Device / Android version / root manager:**

Please tick what you checked:

- [ ] `tests/headless-proof.sh` says OK (hook `ask` holds in bypass mode)
- [ ] The `c` key in a login dialog puts a clean link into the Android clipboard
- [ ] `/mcp` or `/login` opens the Android browser by itself
- [ ] The redirect to `localhost` after login works
- [ ] An `authenticate` tool result (claude.ai connector) opened the browser; shape of `tool_response` (paste the keys only, no tokens):
- [ ] `androidsu 'id'` shows a prompt in Claude Code and returns `uid=0` after Yes, nothing after No

**Notes:**
