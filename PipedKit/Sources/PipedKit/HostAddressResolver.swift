import Darwin
import Foundation

public struct HostAddressResolver: @unchecked Sendable {
    private let resolveBody: @Sendable (String) throws -> [String]

    public init(_ resolve: @escaping @Sendable (String) throws -> [String]) {
        resolveBody = resolve
    }

    public func resolve(_ host: String) throws -> [String] {
        try resolveBody(host)
    }

    public static let system = HostAddressResolver { host in
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { if let result { freeaddrinfo(result) } }

        var addresses: [String] = []
        var cursor = result
        while let info = cursor?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.ai_addr,
                info.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST) == 0
            {
                let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
                addresses.append(
                    String(
                        decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
                        as: UTF8.self))
            }
            cursor = info.ai_next
        }
        return Array(Set(addresses)).sorted()
    }
}
