import Testing

@testable import Atlas

@MainActor
@Test func instanceStoreKeepsAndMirrorsValidDefaultsValue() throws {
    let defaults = makeTestDefaults()
    let secureStore = MemoryInstanceSecureStore()
    defaults.set("pipedapi.cmf.sh/", forKey: InstanceStore.defaultsKey)

    let store = InstanceStore(defaults: defaults, secureStore: secureStore)

    #expect(store.load() == "https://pipedapi.cmf.sh")
    #expect(defaults.string(forKey: InstanceStore.defaultsKey) == "https://pipedapi.cmf.sh")
    #expect(secureStore.value == "https://pipedapi.cmf.sh")
}

@MainActor
@Test func instanceStoreRestoresDefaultsFromSecureStore() throws {
    let defaults = makeTestDefaults()
    let secureStore = MemoryInstanceSecureStore(value: "https://piped.example")
    let store = InstanceStore(defaults: defaults, secureStore: secureStore)

    #expect(store.load() == "https://piped.example")
    #expect(defaults.string(forKey: InstanceStore.defaultsKey) == "https://piped.example")
    #expect(secureStore.value == "https://piped.example")
}

@MainActor
@Test func instanceStoreAllowsHTTPForLocalAndPrivateHosts() throws {
    let allowed = [
        "http://localhost:8080",
        "http://127.0.0.1:8080",
        "http://192.168.1.24:8080",
        "http://10.0.0.5",
        "http://172.20.10.2",
        "http://atlas-lan:8080",
        "http://[::1]:8080",
        "http://[fd00::1]:8080",
    ]

    for rawURL in allowed {
        #expect(InstanceStore.isValidInstanceURL(rawURL))
    }
}

@MainActor
@Test func instanceStoreRejectsHTTPForPublicDomains() throws {
    #expect(!InstanceStore.isValidInstanceURL("http://piped.example"))
    #expect(!InstanceStore.isValidInstanceURL("http://example.com"))
    #expect(!InstanceStore.isValidInstanceURL("http://0.0.0.0:8080"))
    #expect(!InstanceStore.isValidInstanceURL("https://user:password@example.com"))
}

@MainActor
@Test func instanceStoreClearsInvalidSavedValues() throws {
    let defaults = makeTestDefaults()
    let secureStore = MemoryInstanceSecureStore(value: "not a url")
    defaults.set("ftp://piped.example", forKey: InstanceStore.defaultsKey)
    let store = InstanceStore(defaults: defaults, secureStore: secureStore)

    #expect(store.load().isEmpty)
    #expect(defaults.string(forKey: InstanceStore.defaultsKey) == nil)
    #expect(secureStore.value == nil)
}
