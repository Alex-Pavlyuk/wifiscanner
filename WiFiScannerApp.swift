import SwiftUI
import CoreWLAN
import CoreLocation
import AppKit

// MARK: - Data Models

struct ScannedNetwork: Identifiable {
    let id: String
    let ssid: String
    let bssid: String
    let channel: Int
    let band: String
    let width: Int
    let rssi: Int          // median over all scan passes
    let rssiMin: Int
    let rssiMax: Int
    let noise: Int
    let seenCount: Int
    let passCount: Int
    let utilization: Int?  // BSS Load channel utilization reported by the AP, %
    let stationCount: Int?
    var isMine: Bool

    var snr: Int { rssi - noise }
    var hasName: Bool { !ssid.isEmpty }
    var displayName: String { hasName ? ssid : "<hidden>" }
    var spreadCount: Int { max(1, width / 20) }

    var occupiedChannels5: Set<Int> {
        WiFiScanner.bondedGroup(channel: channel, width: width)
    }

    var occupiedChannels24: Set<Int> {
        WiFiScanner.subChannels24(channel: channel, width: width)
    }
}

struct ChannelWidthOption: Identifiable {
    let id: String
    let channel: Int
    let width: Int
    let band: String
    let isDFS: Bool
    let occupiedChannels: Set<Int>
    let interferingNets: [ScannedNetwork]
    let contentionNets: [ScannedNetwork]
    let airtimeBusy: Double       // 0..1 share of airtime neighbours take from us
    let noiseFloor: Double        // dBm per 20 MHz incl. weak neighbours
    let baseNoise: Double         // dBm receiver noise floor
    let ownRSSI: Int
    let ownRSSIAssumed: Bool
    let snr: Double               // dB per 20 MHz sub-channel, width penalty applied
    let capacity: Double          // relative throughput units

    var maxInterfererRSSI: Int { interferingNets.map { $0.rssi }.max() ?? -100 }
    var interferenceRise: Double { noiseFloor - baseNoise }

    var congestionLevel: CongestionLevel {
        if airtimeBusy < 0.03 && interferenceRise < 1 { return .free }
        if airtimeBusy < 0.12 && interferenceRise < 4 { return .low }
        if airtimeBusy < 0.30 && interferenceRise < 8 { return .moderate }
        if airtimeBusy < 0.50 { return .high }
        return .overloaded
    }
}

enum CongestionLevel: String {
    case free = "Clear"
    case low = "Low"
    case moderate = "Moderate"
    case high = "Busy"
    case overloaded = "Crowded"

    var color: Color {
        switch self {
        case .free: return .green
        case .low: return Color(red: 0.4, green: 0.8, blue: 0.2)
        case .moderate: return .yellow
        case .high: return .orange
        case .overloaded: return .red
        }
    }
}

struct DFSChannelResult: Identifiable {
    let id = UUID()
    let channel: Int
    let networksFound: Int
    let strongestRSSI: Int?
    let networkNames: [String]

    var status: String {
        if networksFound == 0 { return "Clear" }
        if networksFound <= 2 { return "Low use" }
        return "Active"
    }

    var statusColor: Color {
        if networksFound == 0 { return .green }
        if networksFound <= 2 { return .yellow }
        return .orange
    }
}

struct DFSTestResult {
    let channels: [DFSChannelResult]
    let activeChannelCount: Int
    let clearChannelCount: Int
    let currentChannel: Int
    let currentlyOnDFS: Bool
}

struct RawNet {
    let ssid: String
    let bssid: String
    let channel: Int
    let band: String
    let width: Int
    let rssi: Int
    let noise: Int
    let utilization: Int?
    let stationCount: Int?

    init(_ net: CWNetwork) {
        ssid = net.ssid ?? ""
        bssid = net.bssid ?? ""
        let chan = net.wlanChannel
        channel = chan?.channelNumber ?? 0
        switch chan?.channelBand {
        case .band2GHz: band = "2.4GHz"
        case .band5GHz: band = "5GHz"
        case .band6GHz: band = "6GHz"
        default: band = "?"
        }
        switch chan?.channelWidth {
        case .width20MHz: width = 20
        case .width40MHz: width = 40
        case .width80MHz: width = 80
        case .width160MHz: width = 160
        default: width = 20
        }
        rssi = net.rssiValue
        noise = net.noiseMeasurement
        let load = RawNet.parseBSSLoad(net.informationElementData)
        utilization = load?.utilization
        stationCount = load?.stations
    }

    // IEEE 802.11 BSS Load element (ID 11): station count, channel utilization (0-255)
    static func parseBSSLoad(_ data: Data?) -> (stations: Int, utilization: Int)? {
        guard let data = data else { return nil }
        let b = [UInt8](data)
        var i = 0
        while i + 2 <= b.count {
            let id = Int(b[i]), len = Int(b[i + 1])
            if i + 2 + len > b.count { break }
            if id == 11 && len >= 3 {
                let sta = Int(b[i + 2]) | (Int(b[i + 3]) << 8)
                let util = Int((Double(b[i + 4]) / 255.0 * 100.0).rounded())
                return (sta, util)
            }
            i += 2 + len
        }
        return nil
    }
}

// MARK: - Scanner

class WiFiScanner: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var networks: [ScannedNetwork] = []
    @Published var options5: [ChannelWidthOption] = []
    @Published var options24: [ChannelWidthOption] = []
    @Published var isScanning = false
    @Published var progressText = ""
    @Published var errorMessage: String?
    @Published var namesHidden = false
    @Published var locationDenied = false
    @Published var ownSSID: String?
    @Published var connectedChannel = 0
    @Published var connectedBand = ""
    @Published var passesDone = 0
    @Published var dfsTestResult: DFSTestResult?
    @Published var showDFSSheet = false
    @Published var selectedTab = 0

    @Published var plannedWidth5: Int { didSet { save("plannedWidth5", plannedWidth5); recompute() } }
    @Published var plannedWidth24: Int { didSet { save("plannedWidth24", plannedWidth24); recompute() } }
    @Published var allowDFS: Bool { didSet { save("allowDFS", allowDFS) } }
    @Published var scanPasses: Int { didSet { save("scanPasses", scanPasses) } }
    @Published var manualOwnSSID: String { didSet { save("manualOwnSSID", manualOwnSSID); reidentify() } }
    private var manualMine: Set<String> { didSet { save("manualMine", Array(manualMine)) } }
    private var manualNotMine: Set<String> { didSet { save("manualNotMine", Array(manualNotMine)) } }

    private let locationManager = CLLocationManager()
    private var rawPasses: [[RawNet]] = []
    private var lastFreshScan: Date?

    // Scan results are cached by macOS for roughly this long; re-scanning sooner returns the same snapshot.
    static let scanCacheSeconds: TimeInterval = 10.5

    override init() {
        let d = UserDefaults.standard
        plannedWidth5 = d.object(forKey: "plannedWidth5") as? Int ?? 80
        plannedWidth24 = d.object(forKey: "plannedWidth24") as? Int ?? 20
        allowDFS = d.object(forKey: "allowDFS") as? Bool ?? false
        scanPasses = d.object(forKey: "scanPasses") as? Int ?? 3
        manualOwnSSID = d.string(forKey: "manualOwnSSID") ?? ""
        manualMine = Set(d.stringArray(forKey: "manualMine") ?? [])
        manualNotMine = Set(d.stringArray(forKey: "manualNotMine") ?? [])
        super.init()
        locationManager.delegate = self
        locationDenied = locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: Location permission (needed for SSID/BSSID visibility)

    func requestLocation() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .denied || status == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            self.locationDenied = status == .denied || status == .restricted
            if (status == .authorizedAlways || status == .authorized) && !self.isScanning && !self.networks.isEmpty {
                self.scan()
            }
        }
    }

    // MARK: Own network

    var ownNetworks: [ScannedNetwork] { networks.filter { $0.isMine } }

    var knownSSIDs: [String] {
        Array(Set(networks.map { $0.ssid }.filter { !$0.isEmpty })).sorted()
    }

    func setMine(_ net: ScannedNetwork, _ mine: Bool) {
        if mine { manualMine.insert(net.id); manualNotMine.remove(net.id) }
        else { manualNotMine.insert(net.id); manualMine.remove(net.id) }
        reidentify()
    }

    private func reidentify() {
        guard !networks.isEmpty else { return }
        let iface = CWWiFiClient.shared().interface()
        networks = identifyMine(networks, iface: iface)
        recompute()
    }

    private func identifyMine(_ nets: [ScannedNetwork], iface: CWInterface?) -> [ScannedNetwork] {
        let ifaceSSID = iface?.ssid()
        let ifaceBSSID = iface?.bssid()
        let chosenSSID = !manualOwnSSID.isEmpty ? manualOwnSSID : ifaceSSID
        let connChannel = iface?.wlanChannel()?.channelNumber ?? 0
        let connRSSI = iface?.rssiValue() ?? 0

        var result = nets.map { n -> ScannedNetwork in
            var n = n
            if manualMine.contains(n.id) { n.isMine = true }
            else if manualNotMine.contains(n.id) { n.isMine = false }
            else if let s = chosenSSID, !s.isEmpty, n.ssid == s { n.isMine = true }
            else if let b = ifaceBSSID, !b.isEmpty, n.bssid == b { n.isMine = true }
            else { n.isMine = false }
            return n
        }

        // Without Location permission names are hidden: fall back to matching the
        // connected channel and RSSI to find at least the AP we are connected to.
        if chosenSSID == nil || chosenSSID!.isEmpty, connChannel > 0, !result.contains(where: { $0.isMine }) {
            let candidates = result.indices.filter {
                result[$0].channel == connChannel && !manualNotMine.contains(result[$0].id)
            }
            if let best = candidates.min(by: { abs(result[$0].rssi - connRSSI) < abs(result[$1].rssi - connRSSI) }),
               abs(result[best].rssi - connRSSI) <= 10 {
                result[best].isMine = true
            }
        }
        return result
    }

    // MARK: DFS test

    func testDFS() {
        guard !networks.isEmpty else { return }
        let nets5 = networks.filter { $0.band == "5GHz" && !$0.isMine }
        let dfsChannels = [52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140]

        var channelResults: [DFSChannelResult] = []
        for ch in dfsChannels {
            let netsOnChannel = nets5.filter { $0.occupiedChannels5.contains(ch) }
            channelResults.append(DFSChannelResult(
                channel: ch,
                networksFound: netsOnChannel.count,
                strongestRSSI: netsOnChannel.map { $0.rssi }.max(),
                networkNames: netsOnChannel.map { $0.displayName }
            ))
        }

        let iface = CWWiFiClient.shared().interface()
        let currentChannel = iface?.wlanChannel()?.channelNumber ?? 0

        dfsTestResult = DFSTestResult(
            channels: channelResults,
            activeChannelCount: channelResults.filter { $0.networksFound > 0 }.count,
            clearChannelCount: channelResults.filter { $0.networksFound == 0 }.count,
            currentChannel: currentChannel,
            currentlyOnDFS: Self.dfsSet.contains(currentChannel)
        )
        showDFSSheet = true
    }

    // MARK: Scanning

    private func progress(_ text: String) {
        DispatchQueue.main.async { self.progressText = text }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        passesDone = 0
        let passes = max(1, scanPasses)
        progressText = "Scanning…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let iface = CWWiFiClient.shared().interface() else {
                DispatchQueue.main.async {
                    self.errorMessage = "Could not access WiFi interface"
                    self.isScanning = false
                }
                return
            }

            var collected: [[RawNet]] = []
            for pass in 1...passes {
                if let last = self.lastFreshScan {
                    var wait = Self.scanCacheSeconds - Date().timeIntervalSince(last)
                    while wait > 0 {
                        self.progress("Pass \(pass) of \(passes) — waiting \(Int(wait.rounded(.up))) s for macOS to allow a fresh scan…")
                        Thread.sleep(forTimeInterval: min(1.0, wait))
                        wait = Self.scanCacheSeconds - Date().timeIntervalSince(last)
                    }
                }
                self.progress("Pass \(pass) of \(passes) — scanning…")

                var result: Set<CWNetwork> = []
                var attempt = 0
                while true {
                    let t0 = Date()
                    do {
                        result = try iface.scanForNetworks(withSSID: nil)
                    } catch {
                        DispatchQueue.main.async {
                            self.errorMessage = "Scan error: \(error.localizedDescription)"
                            self.isScanning = false
                        }
                        return
                    }
                    let fresh = Date().timeIntervalSince(t0) > 0.4
                    if fresh || pass == 1 || attempt >= 4 {
                        self.lastFreshScan = fresh ? t0 : Date()
                        break
                    }
                    attempt += 1
                    Thread.sleep(forTimeInterval: 2.0)
                }
                collected.append(result.map(RawNet.init))
                DispatchQueue.main.async { self.passesDone = pass }
            }

            let merged = Self.merge(collected)
            let identified = self.identifyMine(merged, iface: iface)
            let hidden = identified.contains { !$0.hasName } && iface.ssid() == nil
            let connCh = iface.wlanChannel()?.channelNumber ?? 0
            let connBand: String
            switch iface.wlanChannel()?.channelBand {
            case .band2GHz: connBand = "2.4GHz"
            case .band5GHz: connBand = "5GHz"
            default: connBand = ""
            }

            DispatchQueue.main.async {
                self.rawPasses = collected
                self.networks = identified.sorted { $0.rssi > $1.rssi }
                self.namesHidden = hidden
                self.ownSSID = iface.ssid()
                self.connectedChannel = connCh
                self.connectedBand = connBand
                self.recompute()
                self.isScanning = false
                self.progressText = ""
            }
        }
    }

    /// Merge several scan passes into one network list keyed by BSSID (or, when
    /// BSSIDs are hidden, by band/channel/width plus a close RSSI).
    static func merge(_ passes: [[RawNet]]) -> [ScannedNetwork] {
        struct Cluster {
            var proto: RawNet
            var rssis: [Int] = []
            var noises: [Int] = []
            var utilization: Int?
            var stations: Int?
            var matchedThisPass = false
        }
        var clusters: [Cluster] = []

        for pass in passes {
            for i in clusters.indices { clusters[i].matchedThisPass = false }
            for raw in pass.sorted(by: { $0.rssi > $1.rssi }) {
                let idx = clusters.firstIndex { c in
                    if c.matchedThisPass { return false }
                    if !raw.bssid.isEmpty || !c.proto.bssid.isEmpty { return raw.bssid == c.proto.bssid && raw.band == c.proto.band }
                    return c.proto.band == raw.band && c.proto.channel == raw.channel
                        && c.proto.width == raw.width && c.proto.ssid == raw.ssid
                        && abs((c.rssis.last ?? raw.rssi) - raw.rssi) <= 8
                }
                if let idx = idx {
                    clusters[idx].rssis.append(raw.rssi)
                    clusters[idx].noises.append(raw.noise)
                    clusters[idx].matchedThisPass = true
                    if raw.utilization != nil { clusters[idx].utilization = raw.utilization; clusters[idx].stations = raw.stationCount }
                    if !raw.ssid.isEmpty || raw.channel != clusters[idx].proto.channel { clusters[idx].proto = raw }
                } else {
                    clusters.append(Cluster(proto: raw, rssis: [raw.rssi], noises: [raw.noise],
                                            utilization: raw.utilization, stations: raw.stationCount, matchedThisPass: true))
                }
            }
        }

        func median(_ xs: [Int]) -> Int {
            let s = xs.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }

        return clusters.enumerated().map { (i, c) in
            let p = c.proto
            let id = !p.bssid.isEmpty ? p.bssid : "\(p.band)|\(p.ssid)|\(p.channel)|\(p.width)|\(i)"
            return ScannedNetwork(
                id: id, ssid: p.ssid, bssid: p.bssid, channel: p.channel, band: p.band, width: p.width,
                rssi: median(c.rssis), rssiMin: c.rssis.min() ?? 0, rssiMax: c.rssis.max() ?? 0,
                noise: median(c.noises), seenCount: c.rssis.count, passCount: passes.count,
                utilization: c.utilization, stationCount: c.stations, isMine: false
            )
        }
    }

    // MARK: Channel model

    static let routerChannels5: [Int] = [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140]
    static let routerWidths5: [Int] = [20, 40, 80, 160]
    static let dfsSet = Set(52...144)
    static let chIndex5 = [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165]

    static func bondedGroup(channel: Int, width: Int) -> Set<Int> {
        let groups40 = [[36,40],[44,48],[52,56],[60,64],[100,104],[108,112],[116,120],[124,128],[132,136],[140,144],[149,153],[157,161]]
        let groups80 = [[36,40,44,48],[52,56,60,64],[100,104,108,112],[116,120,124,128],[132,136,140,144],[149,153,157,161]]
        let groups160 = [[36,40,44,48,52,56,60,64],[100,104,108,112,116,120,124,128]]
        let groups: [[Int]]
        switch width {
        case 40: groups = groups40
        case 80: groups = groups80
        case 160: groups = groups160
        default: return [channel]
        }
        return Set(groups.first { $0.contains(channel) } ?? [channel])
    }

    /// 20 MHz sub-channel centres (as 2.4 GHz channel numbers) a transmitter uses.
    static func subChannels24(channel: Int, width: Int) -> Set<Int> {
        guard width >= 40 else { return [channel] }
        let secondary = channel <= 9 ? channel + 4 : channel - 4
        return [channel, secondary]
    }

    static func adjacent5(_ a: Int, _ b: Int) -> Bool {
        guard let ia = chIndex5.firstIndex(of: a), let ib = chIndex5.firstIndex(of: b) else { return false }
        return abs(ia - ib) == 1 && abs(a - b) == 4
    }

    private static func mw(_ dBm: Double) -> Double { pow(10.0, dBm / 10.0) }
    private static func dBm(_ mw: Double) -> Double { mw > 0 ? 10.0 * log10(mw) : -120 }

    /// Airtime a neighbour consumes: its advertised BSS Load if present, otherwise a
    /// typical idle-home-AP figure (beacons + light traffic).
    private static func assumedAirtime(_ net: ScannedNetwork) -> Double {
        if let u = net.utilization { return max(0.02, Double(u) / 100.0) }
        return 0.10
    }

    struct Contribution {
        var busy: Double = 0
        var noiseMw: Double = 0
    }

    /// What one neighbour does to one of our 20 MHz sub-channels.
    /// A neighbour we can hear above the clear-channel threshold makes us wait (busy airtime);
    /// a weaker one only raises the noise floor while it transmits. Preamble detection
    /// (-82 dBm) only works when its primary channel is our primary; otherwise we rely on
    /// energy detection (-72 dBm, -62 dBm for partially overlapping 2.4 GHz channels) and
    /// collide more often, which costs extra airtime.
    private static func contribute(power: Double, ourPrimary: Bool, theirPrimary: Bool, partial: Bool, airtime: Double, into c: inout Contribution) -> Bool {
        let threshold: Double
        var collisionFactor = 1.0
        if partial {
            threshold = -62
            collisionFactor = 1.5
        } else if ourPrimary && theirPrimary {
            threshold = -82
        } else if ourPrimary {
            threshold = -72
            collisionFactor = 1.5
        } else {
            threshold = -72
        }
        if power >= threshold {
            c.busy += airtime * collisionFactor
            return true
        }
        c.noiseMw += mw(power) * airtime
        return false
    }

    static func buildOptions(band: String, networks: [ScannedNetwork], ownRSSI: Int, ownAssumed: Bool, widthFilter: [Int]) -> [ChannelWidthOption] {
        let neighbours = networks.filter { $0.band == band && !$0.isMine }
        let noises = networks.filter { $0.band == band }.map { $0.noise }.filter { $0 < -60 }.sorted()
        let baseNoise = Double(noises.isEmpty ? (band == "5GHz" ? -95 : -92) : noises[noises.count / 2])

        var options: [ChannelWidthOption] = []
        let channels = band == "5GHz" ? routerChannels5 : Array(1...13)

        for ch in channels {
            for w in widthFilter {
                let ours: Set<Int>
                if band == "5GHz" {
                    ours = bondedGroup(channel: ch, width: w)
                    if w >= 40 && ours.count < w / 20 { continue }
                } else {
                    if w == 40 && ch > 9 { continue }
                    ours = subChannels24(channel: ch, width: w)
                }

                var perSub: [Int: Contribution] = [:]
                for c in ours { perSub[c] = Contribution() }
                var interfering = Set<String>()
                var contending = Set<String>()

                for net in neighbours {
                    let theirs = band == "5GHz" ? net.occupiedChannels5 : net.occupiedChannels24
                    let perSubPower = Double(net.rssi) - 10.0 * log10(Double(theirs.count))
                    let airtime = assumedAirtime(net)
                    var touched = false
                    for c in ours {
                        var contrib = perSub[c]!
                        if band == "5GHz" {
                            if theirs.contains(c) {
                                touched = true
                                if contribute(power: perSubPower, ourPrimary: c == ch, theirPrimary: net.channel == c, partial: false, airtime: airtime, into: &contrib) { contending.insert(net.id) }
                            } else if theirs.contains(where: { adjacent5($0, c) }) {
                                // adjacent-channel leakage, ~25 dB down
                                contrib.noiseMw += mw(perSubPower - 25) * airtime
                            }
                        } else {
                            for m in theirs {
                                let delta = abs(c - m)
                                guard delta < 4 else { continue }
                                touched = true
                                let overlap = 1.0 - Double(delta) * 5.0 / 20.0
                                let p = perSubPower + 10.0 * log10(overlap)
                                if contribute(power: p, ourPrimary: c == ch, theirPrimary: net.channel == m, partial: delta > 1, airtime: airtime, into: &contrib) { contending.insert(net.id) }
                            }
                        }
                        perSub[c] = contrib
                    }
                    if touched { interfering.insert(net.id) }
                }

                let n = Double(ours.count)
                let ownPerSub = Double(ownRSSI) - 10.0 * log10(n)
                var capacity = 0.0
                var busySum = 0.0
                var noiseSum = 0.0
                var snrSum = 0.0
                for c in ours {
                    let contrib = perSub[c]!
                    let busy = min(0.95, contrib.busy)
                    let noise = dBm(mw(baseNoise) + contrib.noiseMw)
                    let snr = ownPerSub - noise
                    let bits = snr > 0 ? min(10.0, log2(1.0 + mw(snr))) : 0.0
                    capacity += 20.0 * bits * (1.0 - busy)
                    busySum += busy
                    noiseSum += mw(noise)
                    snrSum += snr
                }

                let interferingNets = neighbours.filter { interfering.contains($0.id) }.sorted { $0.rssi > $1.rssi }
                let contentionNets = neighbours.filter { contending.contains($0.id) }.sorted { $0.rssi > $1.rssi }

                options.append(ChannelWidthOption(
                    id: "\(band)-\(ch)-\(w)",
                    channel: ch, width: w, band: band,
                    isDFS: band == "5GHz" && !ours.intersection(dfsSet).isEmpty,
                    occupiedChannels: ours,
                    interferingNets: interferingNets,
                    contentionNets: contentionNets,
                    airtimeBusy: busySum / n,
                    noiseFloor: dBm(noiseSum / n),
                    baseNoise: baseNoise,
                    ownRSSI: ownRSSI,
                    ownRSSIAssumed: ownAssumed,
                    snr: snrSum / n,
                    capacity: capacity
                ))
            }
        }
        return options
    }

    func ownSignal(band: String) -> (rssi: Int, assumed: Bool) {
        let mine = networks.filter { $0.isMine && $0.band == band }.map { $0.rssi }.sorted()
        if !mine.isEmpty { return (mine[mine.count / 2], false) }
        if connectedBand == band, let r = CWWiFiClient.shared().interface()?.rssiValue(), r < 0 { return (r, false) }
        return (-60, true)
    }

    func recompute() {
        let own5 = ownSignal(band: "5GHz")
        let own24 = ownSignal(band: "2.4GHz")
        options5 = Self.buildOptions(band: "5GHz", networks: networks, ownRSSI: own5.rssi, ownAssumed: own5.assumed, widthFilter: Self.routerWidths5)
        options24 = Self.buildOptions(band: "2.4GHz", networks: networks, ownRSSI: own24.rssi, ownAssumed: own24.assumed, widthFilter: [20, 40])
    }

    // MARK: Recommendations

    func best(in options: [ChannelWidthOption], width: Int, dfs: Bool?) -> ChannelWidthOption? {
        options.filter { $0.width == width && (dfs == nil || $0.isDFS == dfs!) }
            .max { $0.capacity < $1.capacity }
    }

    var recommended5: ChannelWidthOption? {
        best(in: options5, width: plannedWidth5, dfs: allowDFS ? nil : false)
    }

    var recommendedDFS5: ChannelWidthOption? {
        best(in: options5, width: plannedWidth5, dfs: true)
    }

    var recommended24: ChannelWidthOption? {
        best(in: options24, width: plannedWidth24, dfs: nil)
    }

    /// Capacity of the best option at the same width, for per-column percentages.
    func columnMax(_ options: [ChannelWidthOption], width: Int) -> Double {
        options.filter { $0.width == width }.map { $0.capacity }.max() ?? 1
    }
}

// MARK: - App Icon Generator

func generateAppIcon() -> NSImage {
    let size = NSSize(width: 256, height: 256)
    let image = NSImage(size: size)
    image.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext

    // Background: rounded rect with gradient
    let bgRect = CGRect(x: 8, y: 8, width: 240, height: 240)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 48, cornerHeight: 48, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [
        CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1.0),
        CGColor(red: 0.05, green: 0.15, blue: 0.35, alpha: 1.0)
    ]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 128, y: 248), end: CGPoint(x: 128, y: 8), options: [])
    }

    // WiFi arcs
    let center = CGPoint(x: 128, y: 100)
    let arcColor = CGColor(red: 0.3, green: 0.8, blue: 1.0, alpha: 1.0)
    ctx.setStrokeColor(arcColor)
    ctx.setLineCap(.round)

    for (i, radius) in [35.0, 60.0, 85.0].enumerated() {
        let alpha = 1.0 - Double(i) * 0.2
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.8, blue: 1.0, alpha: alpha))
        ctx.setLineWidth(8)
        ctx.addArc(center: center, radius: radius, startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        ctx.strokePath()
    }

    // Center dot
    ctx.setFillColor(CGColor(red: 0.3, green: 0.9, blue: 0.5, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: 120, y: 92, width: 16, height: 16))

    // Bar chart at the bottom
    let barColors: [CGColor] = [
        CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0),
        CGColor(red: 0.9, green: 0.8, blue: 0.1, alpha: 1.0),
        CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1.0),
        CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1.0),
        CGColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0),
    ]
    let barHeights: [CGFloat] = [50, 35, 25, 55, 65]
    let barWidth: CGFloat = 28
    let barSpacing: CGFloat = 8
    let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barSpacing
    let startX = (256 - totalWidth) / 2

    for (i, h) in barHeights.enumerated() {
        let x = startX + CGFloat(i) * (barWidth + barSpacing)
        let rect = CGRect(x: x, y: 24, width: barWidth, height: h)
        ctx.setFillColor(barColors[i])
        ctx.fill(rect)
    }

    image.unlockFocus()
    return image
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var scanner = WiFiScanner()

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if scanner.isScanning {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(scanner.progressText.isEmpty ? "Scanning WiFi networks…" : scanner.progressText)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    if scanner.scanPasses > 1 {
                        Text("macOS caches scan results for ~10 s, so several passes take about \(scanner.scanPasses * 12) s. Networks that only show up in some passes are still counted.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }
                }
                .padding()
                Spacer()
            } else if scanner.networks.isEmpty {
                Spacer()
                emptyStateView
                Spacer()
            } else {
                if scanner.namesHidden { locationBanner }
                settingsBar

                Picker("", selection: $scanner.selectedTab) {
                    Text("5 GHz").tag(0)
                    Text("2.4 GHz").tag(1)
                    Text("Networks").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                ScrollView {
                    VStack(spacing: 16) {
                        if scanner.selectedTab == 0 {
                            band5View
                        } else if scanner.selectedTab == 1 {
                            band24View
                        } else {
                            networkListView
                        }
                        if scanner.selectedTab == 0 || scanner.selectedTab == 1 {
                            legendView
                        }

                        recommendationsView
                            .padding(.bottom, 20)
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 720)
        .onAppear {
            NSApp.applicationIconImage = generateAppIcon()
            scanner.requestLocation()
            scanner.scan()
        }
    }

    // MARK: - Header

    var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("WiFi Scanner")
                    .font(.system(size: 20, weight: .bold))
                Text("Channel congestion analysis & router advisor")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !scanner.networks.isEmpty {
                let passes = scanner.networks.first?.passCount ?? 1
                Text("\(scanner.networks.count) networks · \(passes) \(passes == 1 ? "pass" : "passes")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Picker("", selection: $scanner.scanPasses) {
                Text("Quick (1 pass)").tag(1)
                Text("Accurate (3 passes)").tag(3)
                Text("Thorough (5 passes)").tag(5)
            }
            .frame(width: 170)
            .disabled(scanner.isScanning)
            if !scanner.networks.isEmpty {
                Button(action: { scanner.testDFS() }) {
                    Label("Test DFS", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            Button(action: { scanner.scan() }) {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .disabled(scanner.isScanning)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $scanner.showDFSSheet) {
            dfsSheetView
        }
    }

    // MARK: - Location banner

    var locationBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "location.slash")
                .foregroundColor(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Network names are hidden — macOS requires Location Services access for that")
                    .font(.system(size: 12, weight: .semibold))
                Text("Without names the app can only guess which network is yours (by the channel and signal of the AP you are connected to). Grant Location access so your own router is reliably excluded from the interference calculation on both bands.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(scanner.locationDenied ? "Open Settings" : "Allow Location") { scanner.requestLocation() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.orange.opacity(0.3)), alignment: .bottom)
    }

    // MARK: - Settings bar

    var settingsBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Text("My network:").font(.system(size: 11, weight: .semibold))
                if scanner.knownSSIDs.isEmpty {
                    let mine = scanner.ownNetworks
                    Text(mine.isEmpty ? "not identified — mark it in the Networks tab" : "ch \(mine.map { String($0.channel) }.joined(separator: ", ")) (by connection)")
                        .font(.system(size: 11)).foregroundColor(mine.isEmpty ? .orange : .secondary)
                } else {
                    Picker("", selection: $scanner.manualOwnSSID) {
                        Text(scanner.ownSSID.map { "Auto (\($0))" } ?? "Auto").tag("")
                        ForEach(scanner.knownSSIDs, id: \.self) { s in Text(s).tag(s) }
                    }
                    .frame(width: 200)
                }
            }

            Divider().frame(height: 18)

            HStack(spacing: 6) {
                Text("Width I will set on the router:").font(.system(size: 11, weight: .semibold))
                if scanner.selectedTab == 1 {
                    Picker("", selection: $scanner.plannedWidth24) {
                        Text("20 MHz").tag(20); Text("40 MHz").tag(40)
                    }.pickerStyle(.segmented).frame(width: 150)
                } else {
                    Picker("", selection: $scanner.plannedWidth5) {
                        Text("20").tag(20); Text("40").tag(40); Text("80").tag(80); Text("160").tag(160)
                    }.pickerStyle(.segmented).frame(width: 200)
                }
            }

            Divider().frame(height: 18)

            Toggle(isOn: $scanner.allowDFS) {
                Text("Allow DFS channels in recommendation").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            Spacer()

            let own = scanner.ownSignal(band: scanner.selectedTab == 1 ? "2.4GHz" : "5GHz")
            Text(own.assumed ? "Own signal here: assumed \(own.rssi) dBm" : "Own signal here: \(own.rssi) dBm")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(own.assumed ? .orange : .secondary)
                .help("RSSI of your own router at the spot where this Mac is. Used to estimate SNR for every channel/width option.")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - DFS Test Sheet

    var dfsSheetView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DFS Channel Analysis")
                        .font(.system(size: 18, weight: .bold))
                    Text("Dynamic Frequency Selection — channels 52-140")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") { scanner.showDFSSheet = false }
            }
            .padding()

            Divider()

            if let result = scanner.dfsTestResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Image(systemName: result.currentlyOnDFS ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result.currentlyOnDFS ? .green : .secondary)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.currentlyOnDFS
                                     ? "Your Mac is currently on DFS channel \(result.currentChannel)"
                                     : "Your Mac is on channel \(result.currentChannel) (non-DFS)")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(result.currentlyOnDFS
                                     ? "Your router supports DFS. Radar detection is active."
                                     : "Your router is not using a DFS channel right now.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)

                        HStack(spacing: 20) {
                            dfsSummaryBox(value: "\(result.clearChannelCount)", label: "Clear channels", color: .green)
                            dfsSummaryBox(value: "\(result.activeChannelCount)", label: "Occupied channels", color: .orange)
                        }

                        VStack(spacing: 0) {
                            HStack {
                                Text("Channel").frame(width: 70, alignment: .leading)
                                Text("Status").frame(width: 80)
                                Text("Networks").frame(width: 70)
                                Text("Strongest").frame(width: 80)
                                Text("Visible networks").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Color(NSColor.controlBackgroundColor))

                            Divider()

                            ForEach(result.channels) { ch in
                                HStack {
                                    Text("\(ch.channel)")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .frame(width: 70, alignment: .leading)
                                    Text(ch.status)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(ch.statusColor)
                                        .frame(width: 80)
                                    Text("\(ch.networksFound)")
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(width: 70)
                                    if let rssi = ch.strongestRSSI {
                                        Text("\(rssi) dBm")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(rssi > -60 ? .red : rssi > -75 ? .orange : .green)
                                            .frame(width: 80)
                                    } else {
                                        Text("—").foregroundColor(.secondary).frame(width: 80)
                                    }
                                    Text(ch.networkNames.isEmpty ? "None" : ch.networkNames.prefix(3).joined(separator: ", "))
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                Divider()
                            }
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                Text("About DFS and Radar").font(.system(size: 12, weight: .semibold))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                dfsInfoRow("DFS channels (52-140) share frequencies with weather and military radar")
                                dfsInfoRow("Your Mac scans DFS channels passively (it may only listen for beacons), so neighbours there are detected less reliably — a 'clear' DFS channel can still be in use")
                                dfsInfoRow("Routers listen for 60 s before using a DFS channel and must leave it within 10 s if radar is detected; the channel is then blocked for 30 min")
                                dfsInfoRow("On DFS channels routers must use Transmit Power Control and often run at lower power; many phones and IoT devices also avoid DFS — expect a weaker signal and fewer connected devices")
                            }
                        }
                        .padding()
                        .background(Color.orange.opacity(0.05))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3)))
                    }
                    .padding()
                }
            }
        }
        .frame(width: 700, height: 600)
    }

    func dfsSummaryBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }

    func dfsInfoRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundColor(.orange).font(.system(size: 11))
            Text(text).font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Press \"Scan\" to start")
                .font(.title3)
                .foregroundColor(.secondary)
            if let err = scanner.errorMessage {
                Text(err).foregroundColor(.red).font(.caption)
            }
        }
    }

    // MARK: - 5GHz

    var band5View: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("5 GHz — Channel quality for each width (100% = best channel in that column)")
                .font(.headline)
            channel5Grid
            channelMapView
        }
    }

    var channel5Grid: some View {
        let widths = WiFiScanner.routerWidths5
        let rowChannels = WiFiScanner.routerChannels5
        let rec = scanner.recommended5

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Channel")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 80, alignment: .leading)
                ForEach(widths, id: \.self) { w in
                    Text("\(w) MHz\(w == scanner.plannedWidth5 ? "  ◀ planned" : "")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(w == scanner.plannedWidth5 ? .accentColor : .primary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ForEach(rowChannels, id: \.self) { ch in
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text("\(ch)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        if WiFiScanner.dfsSet.contains(ch) {
                            Text("DFS")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                    .frame(width: 80, alignment: .leading)

                    ForEach(widths, id: \.self) { w in
                        let opt = scanner.options5.first { $0.channel == ch && $0.width == w }
                        if let opt = opt {
                            let colMax = scanner.columnMax(scanner.options5, width: w)
                            let colBest = scanner.best(in: scanner.options5, width: w, dfs: scanner.allowDFS ? nil : false)
                            cellView(opt: opt, columnMax: colMax,
                                     isRecommended: rec?.id == opt.id,
                                     isColumnBest: colBest?.id == opt.id,
                                     dimmed: w != scanner.plannedWidth5,
                                     showGroup: w > 20)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("—")
                                .font(.caption).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity).frame(height: 84)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.2))
                        }
                    }
                }
                .padding(.horizontal, 8)
                Divider()
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
    }

    // MARK: - 2.4GHz

    var band24View: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2.4 GHz — Channel quality for each width (100% = best channel in that column)")
                .font(.headline)
            channel24Grid
        }
    }

    var channel24Grid: some View {
        let widths = [20, 40]
        let rec = scanner.recommended24

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Channel")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 80, alignment: .leading)
                ForEach(widths, id: \.self) { w in
                    Text("\(w) MHz\(w == scanner.plannedWidth24 ? "  ◀ planned" : "")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(w == scanner.plannedWidth24 ? .accentColor : .primary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ForEach(1...13, id: \.self) { ch in
                HStack(spacing: 0) {
                    Text("Ch \(ch)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 80, alignment: .leading)

                    ForEach(widths, id: \.self) { w in
                        let opt = scanner.options24.first { $0.channel == ch && $0.width == w }
                        if let opt = opt {
                            let colMax = scanner.columnMax(scanner.options24, width: w)
                            let colBest = scanner.best(in: scanner.options24, width: w, dfs: nil)
                            cellView(opt: opt, columnMax: colMax,
                                     isRecommended: rec?.id == opt.id,
                                     isColumnBest: colBest?.id == opt.id,
                                     dimmed: w != scanner.plannedWidth24,
                                     showGroup: w > 20)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("—")
                                .font(.caption).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity).frame(height: 84)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.2))
                        }
                    }
                }
                .padding(.horizontal, 8)
                Divider()
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
    }

    // MARK: - Cell View

    func cellView(opt: ChannelWidthOption, columnMax: Double, isRecommended: Bool, isColumnBest: Bool, dimmed: Bool, showGroup: Bool) -> some View {
        let pct = columnMax > 0 ? opt.capacity / columnMax : 0
        let busyPct = Int((opt.airtimeBusy * 100).rounded())
        let rise = opt.interferenceRise
        let level = opt.congestionLevel

        return VStack(spacing: 2) {
            if showGroup {
                let chs = opt.occupiedChannels.sorted()
                Text(opt.band == "5GHz" ? "channels \(chs.first ?? 0)-\(chs.last ?? 0)" : "channels \(chs.map { String($0) }.joined(separator: "+"))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(level.color.opacity(0.75))
                        .frame(width: max(4, geo.size.width * CGFloat(pct)))
                    HStack(spacing: 0) {
                        Text(String(format: " %.0f%%  %@", pct * 100, level.rawValue))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 0)
                        Spacer()
                    }
                }
            }
            .frame(height: 20)

            HStack(spacing: 3) {
                Text("busy \(busyPct)%")
                    .foregroundColor(busyPct >= 30 ? .red : busyPct >= 12 ? .orange : .secondary)
                Text("·").foregroundColor(.secondary)
                Text(String(format: "noise %.0f dBm", opt.noiseFloor))
                    .foregroundColor(rise >= 8 ? .red : rise >= 3 ? .orange : .secondary)
                if rise >= 1 {
                    Text(String(format: "(+%.0f)", rise)).foregroundColor(.secondary)
                }
            }
            .font(.system(size: 9, design: .monospaced))

            HStack(spacing: 3) {
                Text(String(format: "SNR %.0f dB", opt.snr))
                    .foregroundColor(opt.snr < 15 ? .orange : .secondary)
                Text("·").foregroundColor(.secondary)
                if opt.interferingNets.isEmpty {
                    Text("no neighbours").foregroundColor(.green)
                } else {
                    Text("\(opt.interferingNets.count) nets, max \(opt.maxInterfererRSSI) dBm")
                        .foregroundColor(opt.maxInterfererRSSI > -60 ? .red : opt.maxInterfererRSSI > -75 ? .orange : .secondary)
                }
            }
            .font(.system(size: 9, design: .monospaced))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .frame(height: 84)
        .opacity(dimmed ? 0.6 : 1.0)
        .background(isRecommended ? Color.green.opacity(0.14) : isColumnBest ? Color.accentColor.opacity(0.06) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isRecommended ? Color.green : isColumnBest ? Color.accentColor.opacity(0.5) : Color.clear,
                        lineWidth: isRecommended ? 2 : 1)
        )
        .help(cellHelp(opt))
    }

    func cellHelp(_ opt: ChannelWidthOption) -> String {
        var lines = ["Channel \(opt.channel) / \(opt.width) MHz"]
        if opt.interferingNets.isEmpty {
            lines.append("No neighbouring networks overlap this option.")
        } else {
            lines.append("Overlapping neighbours:")
            for n in opt.interferingNets.prefix(8) {
                let kind = opt.contentionNets.contains { $0.id == n.id } ? "shares airtime" : "raises noise"
                let load = n.utilization.map { ", load \($0)%" } ?? ""
                lines.append("  \(n.displayName) — ch \(n.channel)/\(n.width) MHz, \(n.rssi) dBm, seen \(n.seenCount)/\(n.passCount)\(load) → \(kind)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Channel Map

    var channelMapView: some View {
        let nets5 = scanner.networks.filter { $0.band == "5GHz" }.sorted { $0.rssi > $1.rssi }
        let allCh = WiFiScanner.routerChannels5

        return VStack(alignment: .leading, spacing: 8) {
            Text("5 GHz Channel Occupancy Map")
                .font(.subheadline).fontWeight(.semibold)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Network")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 130, alignment: .leading)
                    ForEach(allCh, id: \.self) { ch in
                        Text("\(ch)")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .frame(width: 28)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                if nets5.isEmpty {
                    Text("No 5 GHz networks found")
                        .font(.caption).foregroundColor(.secondary).padding()
                } else {
                    ForEach(nets5) { net in
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 3) {
                                    if net.isMine {
                                        Image(systemName: "house.fill").font(.system(size: 8)).foregroundColor(.blue)
                                    }
                                    Text(String(net.displayName.prefix(14)))
                                        .font(.system(size: 9)).lineLimit(1)
                                }
                                Text("\(net.rssi)dBm \(net.width)MHz · \(net.seenCount)/\(net.passCount)")
                                    .font(.system(size: 8)).foregroundColor(.secondary)
                            }
                            .frame(width: 130, alignment: .leading)

                            ForEach(allCh, id: \.self) { ch in
                                let occ = net.occupiedChannels5
                                let color = net.isMine ? Color.blue.opacity(0.5) : signalColor(net.rssi)
                                Rectangle()
                                    .fill(occ.contains(ch) ? color : Color.clear)
                                    .frame(width: 26, height: 20).cornerRadius(2)
                                    .overlay(
                                        occ.contains(ch) ?
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(color.opacity(0.8), lineWidth: 1) : nil
                                    )
                            }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
            Text("Blue rows are your own network and are not counted as interference.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    func signalColor(_ rssi: Int) -> Color {
        if rssi > -55 { return .red }
        if rssi > -65 { return .orange }
        if rssi > -75 { return .yellow }
        return Color.gray.opacity(0.5)
    }

    // MARK: - Network List

    var networkListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            let nets24 = scanner.networks.filter { $0.band == "2.4GHz" }.sorted { $0.rssi > $1.rssi }
            let nets5 = scanner.networks.filter { $0.band == "5GHz" }.sorted { $0.rssi > $1.rssi }

            Text("Tick “Mine” for every entry that belongs to your own router (both bands). Those are excluded from interference and used as your signal reference.")
                .font(.system(size: 11)).foregroundColor(.secondary)

            if !nets5.isEmpty {
                Text("5 GHz (\(nets5.count) networks)").font(.headline)
                networkTable(nets5)
            }
            if !nets24.isEmpty {
                Text("2.4 GHz (\(nets24.count) networks)").font(.headline)
                networkTable(nets24)
            }
        }
    }

    func networkTable(_ nets: [ScannedNetwork]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mine").frame(width: 40)
                Text("SSID").frame(width: 170, alignment: .leading)
                Text("Ch").frame(width: 40)
                Text("Width").frame(width: 50)
                Text("Signal").frame(width: 110)
                Text("dBm").frame(width: 45)
                Text("min…max").frame(width: 80)
                Text("Seen").frame(width: 45)
                Text("Load").frame(width: 55)
                Text("SNR").frame(width: 45)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ForEach(nets) { net in
                HStack {
                    Toggle("", isOn: Binding(get: { net.isMine }, set: { scanner.setMine(net, $0) }))
                        .toggleStyle(.checkbox).labelsHidden().frame(width: 40)
                    Text(net.displayName).lineLimit(1).frame(width: 170, alignment: .leading)
                        .foregroundColor(net.hasName ? .primary : .secondary)
                    Text("\(net.channel)").frame(width: 40)
                    Text("\(net.width)MHz").frame(width: 50)
                    signalBarView(rssi: net.rssi).frame(width: 110)
                    Text("\(net.rssi)").frame(width: 45)
                        .foregroundColor(net.rssi > -60 ? .green : net.rssi > -75 ? .primary : .orange)
                    Text(net.rssiMin == net.rssiMax ? "—" : "\(net.rssiMin)…\(net.rssiMax)").frame(width: 80)
                        .foregroundColor(.secondary)
                    Text("\(net.seenCount)/\(net.passCount)").frame(width: 45)
                        .foregroundColor(net.seenCount < net.passCount ? .orange : .secondary)
                    Text(net.utilization.map { "\($0)%" } ?? "—").frame(width: 55)
                        .foregroundColor(net.utilization.map { $0 >= 30 ? Color.red : $0 >= 12 ? .orange : .secondary } ?? .secondary)
                    Text("\(net.snr)dB").frame(width: 45)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(net.isMine ? Color.blue.opacity(0.06) : Color.clear)
                Divider()
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
    }

    func signalBarView(rssi: Int) -> some View {
        let strength = Double(max(0, min(100, rssi + 100))) / 100.0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(strength > 0.5 ? Color.green : strength > 0.3 ? Color.yellow : Color.red)
                    .frame(width: geo.size.width * CGFloat(strength))
            }
        }.frame(height: 12)
    }

    // MARK: - Legend

    var legendView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to read the table").font(.subheadline).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 6) {
                legendRow(
                    label: "% (bar)",
                    color: .green,
                    desc: "Estimated throughput of this channel relative to the best channel of the same width. Compares channels, not widths: a wider channel is faster when clean but spreads the router's power over more spectrum (−3 dB per doubling), so range drops. Pick the width above, then take the channel with the highest %."
                )
                legendRow(
                    label: "busy %",
                    color: .orange,
                    desc: "Share of airtime neighbours take from you. A neighbour whose signal reaches the Mac above the WiFi clear-channel threshold (−82 dBm co-channel, −62 dBm partially overlapping on 2.4 GHz) makes your devices wait for it. Uses the load the neighbour's router advertises (Load column) or assumes 10% if it advertises none."
                )
                legendRow(
                    label: "noise dBm (+rise)",
                    color: .red,
                    desc: "Noise floor per 20 MHz including neighbours too weak to be decoded; '+N' is how many dB above the clean floor they push it. Weaker neighbours mostly raise noise rather than steal airtime."
                )
                legendRow(
                    label: "SNR",
                    color: .blue,
                    desc: "Signal-to-noise your devices would get from your own router at this spot (own signal shown in the settings bar) after the width penalty. Below ~15 dB speeds drop sharply; 160 MHz costs 9 dB versus 20 MHz."
                )
                legendRow(
                    label: "Seen x/N",
                    color: .secondary,
                    desc: "In how many scan passes the network appeared. macOS caches results for ~10 s and misses networks on a single pass — especially on DFS channels, which are scanned passively. A network seen once still counts."
                )
                legendRow(
                    label: "DFS / green border",
                    color: .orange,
                    desc: "DFS channels (52-140) are often emptier, but routers run them with Transmit Power Control (lower power), need a 60 s radar check and many client devices refuse them — this is the usual reason a 'clear' channel gives a weaker signal. Green border = recommendation for the planned width."
                )
            }
        }
        .padding()
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
    }

    func legendRow(label: String, color: Color, desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4, height: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Recommendations

    @ViewBuilder
    var recommendationsView: some View {
        let nets24count = scanner.networks.filter { $0.band == "2.4GHz" && !$0.isMine }.count
        let nets5count = scanner.networks.filter { $0.band == "5GHz" && !$0.isMine }.count

        VStack(alignment: .leading, spacing: 12) {
            Text("Recommendations").font(.headline)

            if scanner.ownNetworks.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Your own router could not be identified, so it is being counted as a neighbour. Mark it in the Networks tab (or grant Location access) — otherwise the app will steer you away from your current channel every time.")
                        .font(.system(size: 11)).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8).background(Color.orange.opacity(0.08)).cornerRadius(6)
            }

            if let best = scanner.recommended5 {
                recommendationCard(
                    title: "5 GHz — set Channel \(best.channel), Width \(best.width) MHz\(scanner.allowDFS ? "" : " (non-DFS)")",
                    opt: best, pct: scanner.columnMax(scanner.options5, width: best.width) > 0 ? best.capacity / scanner.columnMax(scanner.options5, width: best.width) * 100 : 0,
                    color: .blue
                )
            }

            if !scanner.allowDFS, let dfs = scanner.recommendedDFS5, let best = scanner.recommended5, dfs.capacity > best.capacity * 1.15 {
                recommendationCard(
                    title: "5 GHz — DFS alternative (ch \(dfs.channel)) looks cleaner, but expect lower power and client issues",
                    opt: dfs, pct: dfs.capacity / scanner.columnMax(scanner.options5, width: dfs.width) * 100,
                    color: .orange
                )
            }

            if let best24 = scanner.recommended24 {
                recommendationCard(
                    title: "2.4 GHz — set Channel \(best24.channel), Width \(best24.width) MHz",
                    opt: best24, pct: best24.capacity / scanner.columnMax(scanner.options24, width: best24.width) * 100,
                    color: .purple
                )
            }

            widthComparison

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Why a 'clear' channel can give a weaker signal").font(.subheadline).fontWeight(.semibold)
                tipRow(icon: "antenna.radiowaves.left.and.right", color: .orange,
                       text: "DFS channels (52-140): routers must use Transmit Power Control and usually radiate less; phones/IoT often won't join them. Keep DFS off in the recommendation unless you have tested it.")
                tipRow(icon: "arrow.left.and.right", color: .orange,
                       text: "Wider channel = same power spread thinner: 80 MHz is −6 dB and 160 MHz is −9 dB per 20 MHz compared with 20 MHz. Far rooms lose speed even though the channel is 'clean'.")
                tipRow(icon: "location", color: .blue,
                       text: "This scan sees the air around the Mac, not around the router or your other devices. Scan from where WiFi is actually used, and re-scan at busy times (evenings).")
                tipRow(icon: "clock", color: .blue,
                       text: "Beacons only show that a neighbour exists, not how much it transmits. Only the Load column (when a router advertises it) is a real utilisation figure; otherwise 10% per neighbour is assumed.")
                tipRow(icon: "checkmark.circle.fill", color: .green,
                       text: nets5count < nets24count
                            ? "5 GHz has fewer neighbours here (\(nets5count) vs \(nets24count)) — keep it as the primary band."
                            : "On 2.4 GHz stay with 20 MHz and channels 1, 6 or 11 (or 1/5/9/13); 40 MHz on 2.4 GHz overlaps almost everyone.")
            }
        }
        .padding()
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
    }

    var widthComparison: some View {
        let ref = scanner.recommended5
        return VStack(alignment: .leading, spacing: 4) {
            Text("Best 5 GHz channel for each width (relative to the planned-width pick)").font(.system(size: 11, weight: .semibold))
            HStack(spacing: 12) {
                ForEach(WiFiScanner.routerWidths5, id: \.self) { w in
                    if let b = scanner.best(in: scanner.options5, width: w, dfs: scanner.allowDFS ? nil : false) {
                        let ratio = (ref?.capacity ?? 0) > 0 ? b.capacity / ref!.capacity : 1
                        VStack(spacing: 2) {
                            Text("\(w) MHz").font(.system(size: 10, weight: .semibold))
                                .foregroundColor(w == scanner.plannedWidth5 ? .accentColor : .primary)
                            Text("ch \(b.channel)").font(.system(size: 14, weight: .bold, design: .rounded))
                            Text(String(format: "×%.2f speed · SNR %.0f dB", ratio, b.snr)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                            Text(String(format: "busy %.0f%%", b.airtimeBusy * 100)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(w == scanner.plannedWidth5 ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                    }
                }
            }
            Text("Speed ratio assumes your devices are where this Mac is; at longer range the SNR drops and wider channels lose their advantage first.")
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    func recommendationCard(title: String, opt: ChannelWidthOption, pct: Double, color: Color) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline).fontWeight(.semibold).foregroundColor(color)
                HStack(spacing: 8) {
                    if opt.isDFS {
                        Text("DFS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15)).cornerRadius(3)
                    }
                    Text(opt.congestionLevel.rawValue)
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(opt.congestionLevel.color)
                    Label("\(opt.interferingNets.count) \(opt.interferingNets.count == 1 ? "neighbour" : "neighbours")", systemImage: "wifi.exclamationmark")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Text(String(format: "busy %.0f%%", opt.airtimeBusy * 100))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    Text(String(format: "noise %.0f dBm", opt.noiseFloor))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    Text(String(format: "SNR %.0f dB%@", opt.snr, opt.ownRSSIAssumed ? " (own signal assumed)" : ""))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(opt.ownRSSIAssumed ? .orange : .secondary)
                }
                if !opt.interferingNets.isEmpty {
                    Text("Overlaps: " + opt.interferingNets.prefix(4).map { "\($0.displayName) (\($0.rssi) dBm)" }.joined(separator: ", "))
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing) {
                        Text("Channel").font(.system(size: 9)).foregroundColor(.secondary)
                        Text("\(opt.channel)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    }
                    VStack(alignment: .trailing) {
                        Text("Width").font(.system(size: 9)).foregroundColor(.secondary)
                        Text("\(opt.width)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("MHz").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
                Text(String(format: "%.0f%% of best at this width", pct))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(color.opacity(0.05))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.3)))
    }

    func tipRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 12)).frame(width: 16)
            Text(text).font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - App Entry Point

@main
struct WiFiScannerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 850)
    }
}
