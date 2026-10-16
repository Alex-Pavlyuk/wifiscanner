import Foundation
import CoreWLAN

// MARK: - Data Models

struct NetworkInfo {
    let ssid: String
    let bssid: String
    let channel: Int
    let band: String        // "2.4GHz" or "5GHz"
    let width: Int           // channel width in MHz
    let rssi: Int            // signal strength in dBm
    let noise: Int           // noise level in dBm
    let security: String

    var snr: Int { rssi - noise }

    /// Returns the range of 5GHz channel numbers this network occupies
    var occupiedChannels: Set<Int> {
        if band == "2.4GHz" {
            // 2.4GHz: each channel 22MHz wide, 5MHz spacing
            var set = Set<Int>()
            for ch in 1...13 {
                if abs(ch - channel) * 5 < (width > 20 ? width / 2 : 11) {
                    set.insert(ch)
                }
            }
            return set
        } else {
            // 5GHz: channels are 20MHz apart
            let count = width / 20
            // Determine the base channel of the bonded group
            let chIndex5 = [36,40,44,48,52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144,149,153,157,161,165]
            guard let idx = chIndex5.firstIndex(of: channel) else { return [channel] }
            // Bonded groups align to boundaries of `count` channels
            let groupStart = (idx / count) * count
            var set = Set<Int>()
            for i in groupStart..<min(groupStart + count, chIndex5.count) {
                set.insert(chIndex5[i])
            }
            return set
        }
    }
}

/// A specific router configuration option: channel + width
struct RouterOption: Comparable {
    let channel: Int
    let width: Int
    let isDFS: Bool

    // Networks that interfere
    var interferingNets: [NetworkInfo] = []
    var interferenceScore: Double = 0  // 0 = clean, higher = worse
    var effectiveSpeed: Double = 0     // estimated relative throughput
    var rating: String = ""

    static func < (lhs: RouterOption, rhs: RouterOption) -> Bool {
        lhs.effectiveSpeed > rhs.effectiveSpeed  // higher speed = better = first
    }

    static func == (lhs: RouterOption, rhs: RouterOption) -> Bool {
        lhs.channel == rhs.channel && lhs.width == rhs.width
    }

    /// The set of 20MHz channels this option occupies
    var occupiedChannels: Set<Int> {
        let chIndex5 = [36,40,44,48,52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144,149,153,157,161,165]
        let count = width / 20
        guard let idx = chIndex5.firstIndex(of: channel) else { return [channel] }
        let groupStart = (idx / count) * count
        var set = Set<Int>()
        for i in groupStart..<min(groupStart + count, chIndex5.count) {
            set.insert(chIndex5[i])
        }
        return set
    }
}

// MARK: - Scanner

func scanNetworks() -> [NetworkInfo] {
    guard let iface = CWWiFiClient.shared().interface() else {
        print("❌ Не удалось получить WiFi интерфейс")
        exit(1)
    }

    var networks: Set<CWNetwork> = []
    do {
        networks = try iface.scanForNetworks(withSSID: nil)
    } catch {
        print("❌ Ошибка сканирования: \(error.localizedDescription)")
        print("   Убедитесь, що WiFi увімкнено.")
        exit(1)
    }

    var results: [NetworkInfo] = []
    for net in networks {
        let ssid = net.ssid ?? "<приховано>"
        let bssid = net.bssid ?? "?"
        let chan = net.wlanChannel
        let chNum = chan?.channelNumber ?? 0
        let band: String
        if let b = chan?.channelBand {
            switch b {
            case .band2GHz: band = "2.4GHz"
            case .band5GHz: band = "5GHz"
            case .band6GHz: band = "6GHz"
            default: band = "?"
            }
        } else {
            band = "?"
        }
        let width: Int
        if let w = chan?.channelWidth {
            switch w {
            case .width20MHz: width = 20
            case .width40MHz: width = 40
            case .width80MHz: width = 80
            case .width160MHz: width = 160
            default: width = 0
            }
        } else {
            width = 0
        }

        let rssi = net.rssiValue
        let noise = net.noiseMeasurement

        let security: String
        if net.supportsSecurity(.wpa3Personal) || net.supportsSecurity(.wpa3Enterprise) {
            security = net.supportsSecurity(.wpa3Enterprise) ? "WPA3-Ent" : "WPA3"
        } else if net.supportsSecurity(.wpa2Personal) || net.supportsSecurity(.wpa2Enterprise) {
            security = net.supportsSecurity(.wpa2Enterprise) ? "WPA2-Ent" : "WPA2"
        } else if net.supportsSecurity(.wpaPersonal) || net.supportsSecurity(.wpaEnterprise) {
            security = net.supportsSecurity(.wpaEnterprise) ? "WPA-Ent" : "WPA"
        } else if net.supportsSecurity(.WEP) {
            security = "WEP"
        } else if net.supportsSecurity(.none) {
            security = "Open"
        } else {
            security = "?"
        }

        results.append(NetworkInfo(
            ssid: ssid, bssid: bssid,
            channel: chNum, band: band, width: width,
            rssi: rssi, noise: noise,
            security: security
        ))
    }

    return results.sorted { $0.channel < $1.channel }
}

// MARK: - Analysis: Router Option Combinations

/// DFS channels (52-144)
let dfsChannelSet = Set(52...144)

/// Build all possible router options for the 5GHz dropdown
func build5GHzOptions(networks: [NetworkInfo]) -> [RouterOption] {
    let routerChannels = [36, 40, 44, 48, 52] // from router dropdown (52 is DFS)
    let widths = [20, 40, 80, 160]
    let nets5 = networks.filter { $0.band == "5GHz" }

    // Valid bonding groups for each width:
    // 20MHz: any single channel
    // 40MHz: 36-40, 44-48, 52-56, ...
    // 80MHz: 36-48, 52-64, 100-112, ...
    // 160MHz: 36-64, 100-128, ...
    let chIndex5 = [36,40,44,48,52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144,149,153,157,161,165]

    var options: [RouterOption] = []

    for ch in routerChannels {
        for w in widths {
            // Check if this channel can be a start of a bonded group of this width
            let count = w / 20
            guard let idx = chIndex5.firstIndex(of: ch) else { continue }
            let groupStart = (idx / count) * count
            // The router channel should be in a valid group
            let groupChannels: Set<Int> = {
                var s = Set<Int>()
                for i in groupStart..<min(groupStart + count, chIndex5.count) {
                    s.insert(chIndex5[i])
                }
                return s
            }()

            // Skip if group doesn't have enough channels
            if groupChannels.count < count { continue }

            let isDFS = !groupChannels.intersection(dfsChannelSet).isEmpty && ch >= 52

            // Find interfering networks: any network whose occupied channels overlap ours
            let interfering = nets5.filter { net in
                !net.occupiedChannels.intersection(groupChannels).isEmpty
            }

            // Interference score based on signal strength of interferers
            // Stronger interferers (higher RSSI, closer to 0) = worse
            var intScore = 0.0
            for net in interfering {
                // How much overlap (fraction of our channels they touch)
                let overlapFraction = Double(net.occupiedChannels.intersection(groupChannels).count) / Double(groupChannels.count)
                // Signal impact: -40 dBm is very strong (penalty ~60), -90 is weak (penalty ~10)
                let signalPenalty = max(0, Double(net.rssi + 100))
                intScore += signalPenalty * overlapFraction
            }

            // Effective speed model:
            // Base throughput scales roughly with width (20→1x, 40→2x, 80→4x, 160→8x)
            let baseMultiplier = Double(w) / 20.0
            // Interference reduces effective throughput via airtime contention
            // Each strong interferer can cut throughput significantly
            let contentionFactor = max(0.1, 1.0 - intScore / 100.0)
            let effectiveSpeed = baseMultiplier * contentionFactor

            var opt = RouterOption(channel: ch, width: w, isDFS: isDFS)
            opt.interferingNets = interfering
            opt.interferenceScore = intScore
            opt.effectiveSpeed = effectiveSpeed

            // Rating
            if intScore < 5 {
                opt.rating = "чисто"
            } else if intScore < 20 {
                opt.rating = "мало завад"
            } else if intScore < 40 {
                opt.rating = "помірно"
            } else if intScore < 60 {
                opt.rating = "завантажено"
            } else {
                opt.rating = "перевантажено"
            }

            options.append(opt)
        }
    }

    return options.sorted()
}

// MARK: - Output

func rssiBar(_ rssi: Int) -> String {
    let strength = max(0, min(5, (rssi + 100) / 10))
    return String(repeating: "█", count: strength) + String(repeating: "░", count: 5 - strength)
}

func signalQuality(_ rssi: Int) -> String {
    switch rssi {
    case -50...0: return "відмінно"
    case -60...(-51): return "добре"
    case -70...(-61): return "норм"
    case -80...(-71): return "слабко"
    default: return "погано"
    }
}

func speedBar(_ speed: Double, maxSpeed: Double) -> String {
    let normalized = Int((speed / maxSpeed) * 15)
    let filled = max(1, min(15, normalized))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: 15 - filled)
}

func printHeader(_ text: String) {
    let line = String(repeating: "═", count: 78)
    print("\n\(line)")
    print("  \(text)")
    print(line)
}

func printNetworks(_ networks: [NetworkInfo]) {
    printHeader("📡 ЗНАЙДЕНІ WiFi МЕРЕЖІ (\(networks.count) шт.)")

    let nets24 = networks.filter { $0.band == "2.4GHz" }.sorted { $0.rssi > $1.rssi }
    let nets5 = networks.filter { $0.band == "5GHz" }.sorted { $0.rssi > $1.rssi }

    if !nets24.isEmpty {
        print("\n  ── 2.4 GHz (\(nets24.count) мереж) ──\n")
        print("  \("SSID".padding(toLength: 22, withPad: " ", startingAt: 0))  Кан  Шир   Сигнал      dBm   SNR  Зайняті канали")
        print("  \(String(repeating: "─", count: 72))")
        for net in nets24 {
            let ssidStr = String(net.ssid.prefix(20)).padding(toLength: 22, withPad: " ", startingAt: 0)
            let chStr = String(net.channel).padding(toLength: 3, withPad: " ", startingAt: 0)
            let wStr = "\(net.width)M".padding(toLength: 5, withPad: " ", startingAt: 0)
            let occupied = net.occupiedChannels.sorted().map { String($0) }.joined(separator: ",")
            print("  \(ssidStr)  \(chStr)  \(wStr) \(rssiBar(net.rssi)) \(signalQuality(net.rssi).padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(net.rssi).padding(toLength: 4, withPad: " ", startingAt: 0))  \(net.snr)dB  [\(occupied)]")
        }
    }

    if !nets5.isEmpty {
        print("\n  ── 5 GHz (\(nets5.count) мереж) ──\n")
        print("  \("SSID".padding(toLength: 22, withPad: " ", startingAt: 0))  Кан  Шир   Сигнал      dBm   SNR  Зайняті канали")
        print("  \(String(repeating: "─", count: 72))")
        for net in nets5 {
            let ssidStr = String(net.ssid.prefix(20)).padding(toLength: 22, withPad: " ", startingAt: 0)
            let chStr = String(net.channel).padding(toLength: 3, withPad: " ", startingAt: 0)
            let wStr = "\(net.width)M".padding(toLength: 5, withPad: " ", startingAt: 0)
            let occupied = net.occupiedChannels.sorted().map { String($0) }.joined(separator: ",")
            print("  \(ssidStr)  \(chStr)  \(wStr) \(rssiBar(net.rssi)) \(signalQuality(net.rssi).padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(net.rssi).padding(toLength: 4, withPad: " ", startingAt: 0))  \(net.snr)dB  [\(occupied)]")
        }
    }
}

func printChannelMap(_ networks: [NetworkInfo]) {
    printHeader("🗺  КАРТА КАНАЛІВ 5 GHz — ХТО ЩО ЗАЙМАЄ")

    let nets5 = networks.filter { $0.band == "5GHz" }
    let allCh = [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 149, 153, 157, 161, 165]

    // Print channel numbers header
    print("")
    var header = "  Канал:  "
    for ch in allCh {
        header += String(ch).padding(toLength: 4, withPad: " ", startingAt: 0)
    }
    print(header)

    let dfsStart = allCh.firstIndex(of: 52)!
    let dfsEnd = allCh.firstIndex(of: 140)!
    var dfsLine = "          "
    for (i, _) in allCh.enumerated() {
        if i >= dfsStart && i <= dfsEnd {
            dfsLine += "DFS "
        } else {
            dfsLine += "    "
        }
    }
    print(dfsLine)
    print("  \(String(repeating: "─", count: 4 * allCh.count + 8))")

    // For each network, show which channels it occupies
    for net in nets5.sorted(by: { $0.rssi > $1.rssi }) {
        let occupied = net.occupiedChannels
        var line = "  "
        let label = "\(String(net.ssid.prefix(6))) \(net.rssi)dBm".padding(toLength: 8, withPad: " ", startingAt: 0)
        line += label
        for ch in allCh {
            if occupied.contains(ch) {
                line += "████"
            } else {
                line += " ·  "
            }
        }
        print(line)
    }

    if nets5.isEmpty {
        print("  (немає мереж на 5 GHz)")
    }
}

func printRouterOptions(_ options: [RouterOption], networks: [NetworkInfo]) {
    printHeader("⚙️  ВАРІАНТИ НАЛАШТУВАНЬ РОУТЕРА (5 GHz)")
    print("  Відповідає опціям Channel та Channel Width у налаштуваннях роутера\n")

    let maxSpeed = options.map { $0.effectiveSpeed }.max() ?? 1.0

    // Group by width for clarity
    let widths = [20, 40, 80, 160]

    for w in widths {
        let group = options.filter { $0.width == w }.sorted { $0.effectiveSpeed > $1.effectiveSpeed }
        if group.isEmpty { continue }

        print("  ┌─ Channel Width: \(w) MHz \(w == 20 ? "(повільно але стабільно)" : w == 40 ? "(баланс)" : w == 80 ? "(рекомендовано)" : "(макс. швидкість)") ─┐")
        print("  │")
        print("  │  Канал  DFS  Завади        Ефект. швидкість                  Оцінка")
        print("  │  \(String(repeating: "─", count: 68))")

        for opt in group {
            let chStr = String(opt.channel).padding(toLength: 5, withPad: " ", startingAt: 0)
            let dfs = opt.isDFS ? " ⚠️ " : "  ─ "
            let intStr: String
            if opt.interferingNets.isEmpty {
                intStr = "немає".padding(toLength: 12, withPad: " ", startingAt: 0)
            } else {
                let names = opt.interferingNets.prefix(2).map { "\(String($0.ssid.prefix(8)))(\($0.rssi))" }.joined(separator: " ")
                intStr = String(names.prefix(12)).padding(toLength: 12, withPad: " ", startingAt: 0)
            }

            let bar = speedBar(opt.effectiveSpeed, maxSpeed: maxSpeed)
            let speedPct = String(format: "%.0f%%", (opt.effectiveSpeed / maxSpeed) * 100)

            let best = opt.effectiveSpeed == group.first?.effectiveSpeed ? " ★" : ""

            print("  │  \(chStr) \(dfs)  \(intStr)  \(bar) \(speedPct.padding(toLength: 5, withPad: " ", startingAt: 0))  \(opt.rating)\(best)")

            // Show interfering details
            if !opt.interferingNets.isEmpty {
                for net in opt.interferingNets {
                    let overlap = net.occupiedChannels.intersection(opt.occupiedChannels)
                    let overlapStr = overlap.sorted().map { String($0) }.joined(separator: ",")
                    print("  │         └ \(String(net.ssid.prefix(15))) кан.\(net.channel)/\(net.width)MHz \(net.rssi)dBm → перекриття: [\(overlapStr)]")
                }
            }
        }
        print("  │")
        print("  └\(String(repeating: "─", count: 72))┘\n")
    }
}

func printFinalRecommendation(_ options: [RouterOption], _ networks: [NetworkInfo]) {
    printHeader("🏆 РЕКОМЕНДАЦІЯ — ЩО ВИБРАТИ В РОУТЕРІ")

    // Best overall
    guard let best = options.first else {
        print("  Немає даних для рекомендації")
        return
    }

    // Best per width
    let widths = [160, 80, 40, 20]
    let maxSpeed = options.map { $0.effectiveSpeed }.max() ?? 1.0

    print("")
    for w in widths {
        let bestForWidth = options.filter { $0.width == w }.first
        guard let b = bestForWidth else { continue }
        let pct = String(format: "%.0f%%", (b.effectiveSpeed / maxSpeed) * 100)
        let marker = b.channel == best.channel && b.width == best.width ? "  ◀◀◀ НАЙКРАЩИЙ" : ""
        let dfsNote = b.isDFS ? " (DFS ⚠️)" : ""
        print("  Найкращий для \(String(w).padding(toLength: 3, withPad: " ", startingAt: 0)) MHz:  Channel = \(b.channel)\(dfsNote),  ефективність \(pct),  \(b.interferingNets.count) завад\(marker)")
    }

    print("\n  ╔═══════════════════════════════════════════════════════════╗")
    print("  ║  ВСТАНОВІТЬ В РОУТЕРІ:                                   ║")
    print("  ║                                                           ║")
    print("  ║    Channel:       \(String(best.channel).padding(toLength: 38, withPad: " ", startingAt: 0))║")
    print("  ║    Channel Width: \(String(best.width).padding(toLength: 3, withPad: " ", startingAt: 0)) MHz\(String(repeating: " ", count: 33))║")
    if best.isDFS {
        print("  ║                                                           ║")
        print("  ║    ⚠️  DFS канал — роутер може перемикатися при          ║")
        print("  ║       виявленні радара. Якщо зв'язок нестабільний,        ║")
        print("  ║       оберіть найкращий не-DFS варіант нижче.             ║")
        if let bestNonDFS = options.first(where: { !$0.isDFS }) {
            let pct = String(format: "%.0f%%", (bestNonDFS.effectiveSpeed / maxSpeed) * 100)
            print("  ║                                                           ║")
            print("  ║    Альтернатива (без DFS):                                ║")
            print("  ║      Channel: \(String(bestNonDFS.channel).padding(toLength: 3, withPad: " ", startingAt: 0)), Width: \(String(bestNonDFS.width).padding(toLength: 3, withPad: " ", startingAt: 0)) MHz, ефективність \(pct.padding(toLength: 15, withPad: " ", startingAt: 0))║")
        }
    }
    print("  ║                                                           ║")
    print("  ╚═══════════════════════════════════════════════════════════╝")

    // Explanation
    print("\n  Як читати результати:")
    print("  ─────────────────────")
    print("  • Ефект. швидкість — відносна оцінка пропускної здатності")
    print("    з урахуванням ширини каналу ТА завад від сусідів.")
    print("  • 160 MHz = макс. швидкість, але більше шансів зловити завади")
    print("  • 80 MHz  = золота середина для більшості випадків")
    print("  • DFS канали (52+) — зазвичай вільніші, але роутер мусить")
    print("    робити radar detection і може тимчасово відключатися")
    print("  • ★ = найкращий варіант для даної ширини каналу")
}

// MARK: - Main

print("╔══════════════════════════════════════════════════════════════════════════════╗")
print("║              WiFi Scanner & Channel Advisor для macOS                       ║")
print("║              Аналіз завантаженості каналів + рекомендації для роутера        ║")
print("╚══════════════════════════════════════════════════════════════════════════════╝")
print("\n⏳ Сканування WiFi мереж...")

let networks = scanNetworks()

if networks.isEmpty {
    print("❌ Не знайдено жодної WiFi мережі. Перевірте, що WiFi увімкнено.")
    exit(1)
}

printNetworks(networks)
printChannelMap(networks)

let options = build5GHzOptions(networks: networks)
printRouterOptions(options, networks: networks)
printFinalRecommendation(options, networks)

print("\n" + String(repeating: "═", count: 78))
print("  Сканування завершено. Знайдено \(networks.count) мереж.")
print(String(repeating: "═", count: 78) + "\n")
