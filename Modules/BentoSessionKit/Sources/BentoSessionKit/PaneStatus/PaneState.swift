import Foundation

/// The three states a pane can be in
public enum PaneState: Equatable {
    case working          // The pane reports it is busy
    case idle             // Nothing to report
    case awaitingInput    // The pane reports it is waiting for the user
}
