# WiFi Scanner & Channel Advisor for macOS

A small macOS utility that scans the WiFi neighbourhood and tells you which **channel and channel width** to set on your router. It comes as a SwiftUI app (`WiFiScannerApp.app`) and a command-line tool (`wifiscanner`), both built from single Swift files with the stock command-line toolchain — no Xcode project required.

## What it does differently

Most channel pickers count beacons on each channel. That produces unstable, misleading advice, so this tool:

- **Scans several times** (3 passes by default). macOS caches scan results for ~10 s and a single scan misses networks, especially on DFS channels; passes are merged per BSSID and the median RSSI is used.
- **Excludes your own router** from the interference calculation (detected via the connected SSID/BSSID, or marked manually), so it never steers you away from your current channel just because your own AP is the strongest signal.
- **Models airtime, not just signal sums.** A neighbour above the 802.11 clear-channel threshold costs you airtime; a weaker one only raises the noise floor while it transmits. The AP-advertised BSS Load is used where available.
- **Accounts for width and DFS honestly.** Wider channels spread the same power thinner (−3 dB per doubling), and DFS channels require Transmit Power Control and are avoided by many clients — the usual reason a "clear" channel ends up with a weaker signal. You pick the width you will set on the router; the app ranks channels for that width and keeps DFS out of the recommendation unless you allow it.

## Build

```sh
./build.sh
open WiFiScannerApp.app
```

Requires macOS 13+ and the Swift command-line tools (`xcode-select --install`).

On first launch macOS asks for **Location Services** access. Without it CoreWLAN hides network names and the app can only guess which network is yours; grant it for reliable results.

## CLI

```sh
./wifiscanner
```

Prints the visible networks, a 5 GHz occupancy map and per-width router recommendations in the terminal.

## Author

[Alex Pavlyuk](https://github.com/Alex-Pavlyuk)

## License

MIT — see [LICENSE](LICENSE).
