import Foundation

/// Shared state machine for all ViewModels.
/// Represents the lifecycle of an async data-loading operation.
enum ViewState<T> {
    case idle
    case loading
    case loaded(T)
    case error(String)
    case empty(String)
}
