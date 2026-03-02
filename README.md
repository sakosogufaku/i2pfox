# I2Pfox 🦊

**A self-contained, fully auditable privacy browser for I2P — based on Tor Browser.**

> ⚠️ **Alpha build.** Functional but under active development.

---

## What it is

I2Pfox bundles everything you need to browse I2P, Tor, and clearnet in a single hardened browser:

- **Bundled i2pd router** — no system i2pd required; starts automatically, stops with the browser
- **Unified network routing** — `.i2p` → i2pd proxy, `.onion` + clearnet → system Tor (SOCKS5 9050)
- **Blue fox theme** — custom dark blue UI, readable URL bar, clean tabs
- **Live status page** — new tab shows i2p router status (peers, tunnels, bandwidth)
- **4get search** — default search via 4get's Tor hidden service (no tracking)
- **Privacy hardened** — based on Tor Browser with WebRTC, telemetry, and geo disabled
- **Single auditable installer** — one bash script, no binaries fetched at runtime except i2pd

## Requirements

- **Tor Browser** installed (default: `~/Desktop/tor-browser`)
- **System Tor** running at `127.0.0.1:9050` (for clearnet + .onion routing)
- Debian/Ubuntu Linux (x86_64)

## Install

```bash
bash i2pfox-install.sh
```

Or with a custom Tor Browser path:

```bash
bash i2pfox-install.sh --tb-dir /path/to/tor-browser
```

Then launch with:

```bash
i2pfox
```

## Network routing

| Destination | Route |
|-------------|-------|
| `.i2p` sites | i2pd HTTP proxy `:14444` |
| `.onion` sites | Tor SOCKS5 `:9050` |
| Clearnet | Tor SOCKS5 `:9050` |

## What's in the installer

Everything is embedded inline — the installer writes:

- `~/.local/share/i2pfox/` — browser profile, i2pd config, assets
- `~/bin/i2pfox` — launcher script
- Tor Browser `distribution/policies.json` — sets 4get as default search
- Tor Browser `i2pfox.cfg` — autoconfig for network-aware tab coloring

## Status

- [x] Bundled i2pd router (from AppImage extract)
- [x] PAC-based unified routing (I2P + Tor + clearnet)
- [x] Blue fox theme
- [x] Live new tab status page
- [x] 4get.ca search (via Tor onion)
- [ ] Network-aware tab color coding (in progress)
- [ ] Verified i2pd binary hash
- [ ] End-to-end install test on fresh machine

## License

MIT
