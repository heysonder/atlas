import Foundation

/// Generic async loading state for a screen.
enum LoadPhase<T> {
    case idle
    case loading
    case loaded(T)
    case failed(String)
}
