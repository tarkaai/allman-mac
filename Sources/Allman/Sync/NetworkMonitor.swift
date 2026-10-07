import Foundation
import Network

/// Thin NWPathMonitor wrapper that reports on the main queue.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "sh.allman.mac.network")
    private(set) var isOnline = true
    private(set) var interface: String = ""
    var onChange: ((Bool, String) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let iface: String
            if path.usesInterfaceType(.wifi) { iface = "Wi-Fi" }
            else if path.usesInterfaceType(.wiredEthernet) { iface = "Ethernet" }
            else if path.usesInterfaceType(.cellular) { iface = "Cellular" }
            else if path.usesInterfaceType(.other) { iface = "VPN / other" }
            else { iface = "" }
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = online != self.isOnline || iface != self.interface
                self.isOnline = online
                self.interface = iface
                if changed { self.onChange?(online, iface) }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
