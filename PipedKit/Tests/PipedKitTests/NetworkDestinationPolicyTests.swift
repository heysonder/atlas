import Foundation
import Testing

@testable import PipedKit

@Test func networkPolicyEnforcesPublicAndLocalDestinationMatrix() throws {
    let policy = NetworkDestinationPolicy(
        resolver: HostAddressResolver { host in
            switch host {
            case "api.public.test", "cdn.public.test": ["93.184.216.34"]
            case "private.test": ["192.168.1.8"]
            default: []
            }
        })
    let publicContext = try InstanceNetworkContext(
        instanceURL: URL(string: "https://api.public.test")!, policy: policy)
    let localContext = try InstanceNetworkContext(
        instanceURL: URL(string: "http://piped.local:8080")!, policy: policy)

    #expect(throws: Never.self) {
        try publicContext.validate(URL(string: "https://cdn.public.test/video")!)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        try publicContext.validate(URL(string: "http://cdn.public.test/video")!)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        try publicContext.validate(URL(string: "https://private.test/video")!)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        try publicContext.validate(URL(string: "http://127.0.0.1/video")!)
    }

    #expect(throws: Never.self) {
        try localContext.validate(URL(string: "https://cdn.public.test/video")!)
    }
    #expect(throws: Never.self) {
        try localContext.validate(URL(string: "http://private.test/video")!)
    }
    #expect(throws: Never.self) {
        try localContext.validate(URL(string: "https://[fd00::1]/video")!)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        try localContext.validate(URL(string: "http://cdn.public.test/video")!)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        try localContext.validate(URL(string: "http://224.0.0.1/video")!)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        try localContext.validate(URL(string: "http://198.51.100.1/video")!)
    }
}

@Test func networkPolicyClassifiesSingleLabelHostsFromDNS() throws {
    let policy = NetworkDestinationPolicy(
        resolver: HostAddressResolver { host in
            switch host {
            case "nas": ["192.168.1.10"]
            case "misleading": ["93.184.216.34"]
            case "blocked": ["0.0.0.0"]
            default: []
            }
        })
    let context = try InstanceNetworkContext(
        instanceURL: URL(string: "http://nas:8080")!,
        policy: policy)

    #expect(throws: Never.self) {
        try context.validate(URL(string: "http://nas/media")!)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        try context.validate(URL(string: "http://misleading/media")!)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        try context.validate(URL(string: "http://blocked/media")!)
    }
}

@Test func networkPolicyRejectsCredentialsSchemesAndUnspecifiedHosts() throws {
    let policy = NetworkDestinationPolicy(resolver: HostAddressResolver { _ in ["93.184.216.34"] })
    let context = try InstanceNetworkContext(
        instanceURL: URL(string: "https://public.test")!, policy: policy)

    #expect(throws: NetworkPolicyError.credentialsNotAllowed) {
        try context.validate(URL(string: "https://user:password@public.test/video")!)
    }
    #expect(throws: NetworkPolicyError.unsupportedScheme) {
        try context.validate(URL(string: "file:///private/secret")!)
    }
    #expect(throws: NetworkPolicyError.unsupportedScheme) {
        try context.validate(URL(string: "data:text/plain,secret")!)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        _ = try InstanceNetworkContext(
            instanceURL: URL(string: "http://0.0.0.0:8080")!, policy: policy)
    }
    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        _ = try InstanceNetworkContext(
            instanceURL: URL(string: "http://[::]:8080")!, policy: policy)
    }
}

@Test func networkPolicyRejectsMixedAndSpecialUseResolution() throws {
    let mixed = NetworkDestinationPolicy(
        resolver: HostAddressResolver { _ in
            ["93.184.216.34", "127.0.0.1"]
        })
    #expect(throws: NetworkPolicyError.mixedAddressScope) {
        _ = try InstanceNetworkContext(
            instanceURL: URL(string: "https://mixed.test")!, policy: mixed)
    }

    let policy = NetworkDestinationPolicy(resolver: HostAddressResolver { _ in ["93.184.216.34"] })
    let publicContext = try InstanceNetworkContext(
        instanceURL: URL(string: "https://public.test")!, policy: policy)
    let denied = [
        "https://127.0.0.1", "https://169.254.1.1", "https://10.0.0.1",
        "https://100.64.0.1", "https://172.16.0.1", "https://192.168.0.1",
        "https://224.0.0.1", "https://[::1]", "https://[fe80::1]",
        "https://[fd00::1]", "https://[::ffff:127.0.0.1]", "https://[2001:db8::1]",
    ]
    for rawURL in denied {
        #expect(throws: NetworkPolicyError.destinationNotAllowed) {
            try publicContext.validate(URL(string: rawURL)!)
        }
    }
}

@Test func redirectPolicyRejectsPrivateDestinationAndStripsCrossOriginCredentials() throws {
    let policy = NetworkDestinationPolicy(
        resolver: HostAddressResolver { host in
            switch host {
            case "public.test", "cdn.test": ["93.184.216.34"]
            default: []
            }
        })
    let context = try InstanceNetworkContext(
        instanceURL: URL(string: "https://public.test")!,
        policy: policy)
    let redirectPolicy = NetworkRedirectPolicy(context: context)

    #expect(throws: NetworkPolicyError.destinationNotAllowed) {
        _ = try redirectPolicy.sanitizedRequest(
            responseURL: URL(string: "https://public.test/start")!,
            request: URLRequest(url: URL(string: "http://127.0.0.1/private")!))
    }

    var crossOrigin = URLRequest(url: URL(string: "https://cdn.test/media")!)
    crossOrigin.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    crossOrigin.setValue("session=secret", forHTTPHeaderField: "Cookie")
    let sanitized = try redirectPolicy.sanitizedRequest(
        responseURL: URL(string: "https://public.test/start")!,
        request: crossOrigin)
    #expect(sanitized.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(sanitized.value(forHTTPHeaderField: "Cookie") == nil)
}
