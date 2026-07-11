import Foundation

public struct InstanceNetworkContext: Sendable {
    public let baseURL: URL
    public let scope: NetworkTrustScope
    public let generation: UInt64
    public let policy: NetworkDestinationPolicy

    public init(
        instanceURL: URL,
        generation: UInt64 = 0,
        policy: NetworkDestinationPolicy = NetworkDestinationPolicy()
    ) throws {
        baseURL = instanceURL
        scope = try policy.scopeForConfiguredInstance(instanceURL)
        self.generation = generation
        self.policy = policy
    }

    public static func publicInternet(
        generation: UInt64 = 0,
        policy: NetworkDestinationPolicy = NetworkDestinationPolicy()
    ) -> InstanceNetworkContext {
        // This fixed origin is only identity/provenance. Every request URL still
        // passes policy validation before the transport starts.
        try! InstanceNetworkContext(
            instanceURL: URL(string: "https://atlas.invalid")!,
            generation: generation,
            policy: policy)
    }

    public func validate(_ url: URL) throws {
        try policy.validate(url, scope: scope)
    }
}
