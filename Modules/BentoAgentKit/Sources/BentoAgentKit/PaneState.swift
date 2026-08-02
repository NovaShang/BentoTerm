import Foundation

/// The three states a pane can be in
public enum PaneState: Equatable {
    case working                          // Command is running, producing output
    case idle                             // No recent output, shell prompt visible
    case awaitingInput(profile: String)   // Waiting for user input (y/N prompt, etc.)
}
