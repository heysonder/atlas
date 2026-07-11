enum PlayerInfoPersistence {
    static func retainedValue<Value>(
        current: Value,
        requested: Value,
        persist: (Value) -> Bool
    ) -> Value {
        persist(requested) ? requested : current
    }
}
