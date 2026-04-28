import Foundation
import Network

struct SNTPClient {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let timeout: TimeInterval

    init(host: String = "time.apple.com", port: UInt16 = 123, timeout: TimeInterval = 5) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 123
        self.timeout = timeout
    }

    func fetchCurrentDate() async throws -> Date {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(host: host, port: port, using: .udp)
            let queue = DispatchQueue(label: "SNTPClient")
            let state = ManagedState()

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    sendRequest(on: connection, state: state, continuation: continuation)
                case .failed(let error):
                    state.finish(with: .failure(error), continuation: continuation)
                    connection.cancel()
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                let error = NSError(domain: "SNTPClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "NTP request timed out"])
                state.finish(with: .failure(error), continuation: continuation)
                connection.cancel()
            }
        }
    }

    private func sendRequest(
        on connection: NWConnection,
        state: ManagedState,
        continuation: CheckedContinuation<Date, Error>
    ) {
        let packet = requestPacket()

        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                state.finish(with: .failure(error), continuation: continuation)
                connection.cancel()
                return
            }

            connection.receiveMessage { data, _, _, error in
                if let error {
                    state.finish(with: .failure(error), continuation: continuation)
                    connection.cancel()
                    return
                }

                guard let data, data.count >= 48 else {
                    let error = NSError(domain: "SNTPClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid NTP response"])
                    state.finish(with: .failure(error), continuation: continuation)
                    connection.cancel()
                    return
                }

                do {
                    let date = try parse(dateFrom: data)
                    state.finish(with: .success(date), continuation: continuation)
                } catch {
                    state.finish(with: .failure(error), continuation: continuation)
                }

                connection.cancel()
            }
        })
    }

    private func requestPacket() -> Data {
        var bytes = Array(repeating: UInt8(0), count: 48)
        bytes[0] = 0x23
        return Data(bytes)
    }

    private func parse(dateFrom data: Data) throws -> Date {
        let seconds = data[40...43].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let fraction = data[44...47].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }

        let ntpEpochOffset: TimeInterval = 2_208_988_800
        let unixSeconds = TimeInterval(seconds) - ntpEpochOffset
        let fractionalSeconds = TimeInterval(fraction) / TimeInterval(UInt64(1) << 32)
        return Date(timeIntervalSince1970: unixSeconds + fractionalSeconds)
    }
}

private final class ManagedState: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false

    func finish(
        with result: Result<Date, Error>,
        continuation: CheckedContinuation<Date, Error>
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else {
            return
        }

        isFinished = true

        switch result {
        case .success(let date):
            continuation.resume(returning: date)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}