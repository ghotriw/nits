#if os(iOS)
    import Network
    import Observation

    /// What the device is connected through, for the status row's icon.
    @MainActor @Observable
    final class NetworkKindMonitor {
        enum Kind: Equatable {
            case wifi, cellular, other, offline
        }

        private(set) var kind: Kind = .other
        @ObservationIgnored private let monitor = NWPathMonitor()

        init() {
            monitor.pathUpdateHandler = { [weak self] path in
                let kind: Kind =
                    path.status != .satisfied
                    ? .offline
                    : path.usesInterfaceType(.wifi) ? .wifi : path.usesInterfaceType(.cellular) ? .cellular : .other
                Task { @MainActor in self?.kind = kind }
            }
            monitor.start(queue: DispatchQueue(label: "nits.network-kind"))
        }

        deinit {
            monitor.cancel()
        }
    }
#endif
