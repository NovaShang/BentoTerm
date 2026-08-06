import Foundation
import Citadel
import Crypto
import NIO
import NIOSSH
import BentoFoundationKit

/// Where a failure happened, so the sentence describes the right event.
enum SSHFailureContext {
    /// TCP connect, SSH handshake, or authentication — before there is a shell.
    case connecting
    /// An established channel died under a running session.
    case session
}

/// Turn an SSH failure into a sentence a user can act on.
///
/// Not one type on this path conforms to `LocalizedError`: `SSHClientError`,
/// `AuthenticationFailed`, `CitadelError`, `NIOSSHError`, `NIOConnectionError`,
/// `SocketAddressError`, `ChannelError` and `IOError` are all plain `Error`s.
/// `localizedDescription` therefore bridges every one of them through `NSError`
/// into the same sentence with a case index glued on — "The operation couldn't
/// be completed. (Citadel.SSHClientError error 4.)" is what a wrong password
/// used to look like, and a wrong port, an unresolvable hostname and a rejected
/// key were three more of the same. This function is the only thing standing
/// between those and the user.
///
/// Everything is matched by casting to the concrete type rather than by writing
/// `case SSHClientError.allAuthenticationOptionsFailed` against the existential:
/// none of these enums are `Equatable`, so the pattern-match form would depend
/// on the stdlib's `~=` for `Error` and silently stop matching if a type ever
/// gained a payload.
///
/// The cases are ordered by what the user can do about them, not by protocol
/// layer: credentials first (retype something), then reachability (fix an
/// address or bring up a VPN), then the handshake (rare, usually a wrong port),
/// then the local key material.
func sshFailureMessage(
    for error: Error,
    host: Host,
    during context: SSHFailureContext
) -> String {
    let target = "\(host.hostname):\(host.port)"

    switch error {

    // MARK: Authentication

    case let e as SSHClientError:
        switch e {
        // Citadel hands NIOSSH one auth offer at a time and fails the promise
        // with `allAuthenticationOptionsFailed` once the list is spent — that
        // is what a wrong password or an unauthorised key arrives as, there is
        // no dedicated "rejected" case.
        case .allAuthenticationOptionsFailed:
            return rejectedCredentialsMessage(host)
        // The server advertised which methods it accepts and ours wasn't among
        // them. `PasswordAuthentication no` in sshd_config is the usual reason,
        // and it needs a different fix from a wrong password.
        case .unsupportedPasswordAuthentication:
            return "\(host.hostname) doesn't accept password logins. Switch this host to an SSH key."
        case .unsupportedPrivateKeyAuthentication:
            return "\(host.hostname) doesn't accept public-key logins for \(host.username). "
                + "Switch this host to a password."
        case .unsupportedHostBasedAuthentication:
            return "\(host.hostname) only offers host-based authentication, which Bento doesn't support."
        case .channelCreationFailed:
            return "\(host.displayName) accepted the login but wouldn't open a channel."
        }

    case is AuthenticationFailed:
        return rejectedCredentialsMessage(host)

    case let e as CitadelError:
        switch e {
        case .unauthorized:
            return rejectedCredentialsMessage(host)
        case .channelCreationFailed, .channelFailure:
            return "\(host.displayName) accepted the login but wouldn't open a shell channel. "
                + "Check the account's shell and any ForceCommand in sshd_config."
        default:
            return "SSH error talking to \(host.displayName): \(e)"
        }

    // MARK: Reachability

    // Happy Eyeballs wraps every address it tried. Unwrap it: the DNS error and
    // the per-address connect errors are the useful parts, while the wrapper's
    // own description is a nest of `Optional(...)`.
    case let connect as NIOConnectionError:
        if connect.dnsAError != nil || connect.dnsAAAAError != nil {
            return unresolvableHostMessage(host)
        }
        if let first = connect.connectionErrors.first {
            return reachabilityMessage(errno: errnoCode(of: first.error), target: target, host: host)
                ?? "Couldn't reach \(target). \(String(describing: first.error))"
        }
        return "Couldn't reach \(target)."

    case is SocketAddressError.UnknownHost:
        return unresolvableHostMessage(host)

    case let e as SocketAddressError:
        if case .failedToParseIPString(let s) = e {
            return "\"\(s)\" isn't a valid hostname or IP address."
        }
        return unresolvableHostMessage(host)

    case let e as ChannelError:
        switch e {
        // Two very different timeouts share this case. NIO raises it when the
        // TCP connect budget runs out (Citadel's default: 30s); Citadel's own
        // ClientHandshakeHandler raises it with a 10s login timeout when the
        // socket opened but the greeting/auth never completed. The duration is
        // the only thing that separates them, and they need different advice.
        case .connectTimeout(let amount):
            if amount == .seconds(10) {
                return "Connected to \(target), but the SSH login didn't finish within 10 seconds."
            }
            return "Couldn't reach \(target) within \(amount.nanoseconds / 1_000_000_000) seconds. "
                + "Check the address and port, and that you're on the right network or VPN."
        case .ioOnClosedChannel, .alreadyClosed, .eof, .outputClosed, .inputClosed:
            return context == .connecting
                ? "\(target) closed the connection before login completed."
                : "The connection to \(host.displayName) was closed."
        default:
            return "Network error talking to \(target): \(e)"
        }

    case let io as IOError:
        return reachabilityMessage(errno: io.errnoCode, target: target, host: host)
            ?? "Network error talking to \(target): \(io)"

    case let posix as POSIXError:
        return reachabilityMessage(errno: posix.code.rawValue, target: target, host: host)
            ?? "Network error talking to \(target): \(posix.localizedDescription)"

    // MARK: Handshake

    case let ssh as NIOSSHError:
        return handshakeMessage(ssh, target: target)

    // MARK: Local key material

    // Thrown when the bytes in the Keychain aren't a 32-byte Ed25519 scalar —
    // an imported key of a type we can't use, or a truncated item.
    case is CryptoKitError:
        return "The saved SSH key for this host isn't a usable Ed25519 key. "
            + "Import or generate the key again in the host's settings."

    case let e as KeychainError:
        if case .itemNotFound = e {
            switch host.authMethod {
            case .password:
                return "No saved password for \(host.displayName). Open the host and enter it again."
            case .privateKey(let label):
                return "The SSH key \"\(label)\" is no longer in the Keychain. "
                    + "Import or generate it again in the host's settings."
            }
        }
        return e.errorDescription ?? "Couldn't read this host's credentials from the Keychain."

    default:
        break
    }

    // Citadel's handshake handler fails its promise from `deinit` with a
    // private `struct Disconnected: Error {}` declared inside the function
    // body — unnameable from here, so it is matched by name.
    //
    // This is what a channel that dies without raising an error of its own
    // looks like, and pointing at the wrong port is the way to get there:
    // probed against a live HTTP server, `example.com:80` produces exactly
    // this and NOT the `NIOSSHError` you'd expect, because the far side hangs
    // up on the SSH banner before NIOSSH has anything to reject. So the wrong
    // port leads; rate-limiting is the same shape but much rarer.
    if String(describing: type(of: error)) == "Disconnected" {
        return "\(target) closed the connection before the SSH login finished. "
            + "Check that sshd is what's listening on port \(host.port)."
    }

    // Our own error types do carry written descriptions; one of those beats any
    // sentence we would invent here.
    if let localized = (error as? LocalizedError)?.errorDescription {
        return localized
    }

    // Nothing recognised it. Say what we know and append the raw form — not
    // pleasant to read, but it is the one thing that makes an unmapped failure
    // reportable, and it is strictly more than the NSError sentence carried.
    let base = context == .connecting
        ? "Couldn't connect to \(host.displayName) (\(target))."
        : "The connection to \(host.displayName) failed."
    return "\(base)\n\n\(String(reflecting: error))"
}

// MARK: - Helpers

/// The server said no to what we offered.
///
/// A wrong username and a wrong password are the *same* error here — verified
/// against a live sshd, both arrive as `allAuthenticationOptionsFailed` and
/// carry nothing else. That isn't a gap in Citadel: SSH deliberately refuses to
/// say which half was wrong, so a stranger can't enumerate accounts. Hence a
/// message that names both halves — but it names them and stops. Explaining the
/// protocol's reticence is this comment's job, not the alert's.
private func rejectedCredentialsMessage(_ host: Host) -> String {
    switch host.authMethod {
    case .password:
        return "\(host.hostname) rejected the login for \(host.username). "
            + "Check the username and password."
    case .privateKey:
        return "\(host.hostname) rejected the login for \(host.username). "
            + "Check the username, and that the key is in ~/.ssh/authorized_keys on the server."
    }
}

private func unresolvableHostMessage(_ host: Host) -> String {
    "Can't resolve the hostname \"\(host.hostname)\". "
        + "Check the spelling, and that you're on the right network or VPN."
}

/// Advice for a connect that reached the network stack and came back with an
/// errno. These are the ones a phone actually hits; anything else falls through
/// so the caller can use its own wording.
private func reachabilityMessage(errno code: Int32?, target: String, host: Host) -> String? {
    guard let code else { return nil }
    switch code {
    case ECONNREFUSED:
        return "\(target) refused the connection. Check that sshd is listening on port \(host.port)."
    case ETIMEDOUT:
        return "\(target) didn't answer. Check the address, and that you're on the right network or VPN."
    case EHOSTUNREACH, EHOSTDOWN:
        return "No route to \(host.hostname). Check that it's up, and that you're on the right network or VPN."
    case ENETUNREACH, ENETDOWN:
        return "No network route to \(host.hostname). Check the phone's connection and any VPN."
    case ECONNRESET:
        return "\(target) reset the connection."
    default:
        return nil
    }
}

/// The errno buried in whatever Happy Eyeballs collected for one address.
private func errnoCode(of error: Error) -> Int32? {
    switch error {
    case let io as IOError: return io.errnoCode
    case let posix as POSIXError: return posix.code.rawValue
    default: return nil
    }
}

/// NIOSSH failures, keyed on the error type rather than its text. Most of these
/// are unreachable in practice; the ones that aren't nearly always mean the
/// port doesn't have an sshd behind it.
private func handshakeMessage(_ error: NIOSSHError, target: String) -> String {
    switch error.type {
    // What pointing at an HTTP server, a database, or a TLS port looks like:
    // bytes arrive, none of them are SSH.
    case .invalidSSHMessage, .invalidPacketFormat, .protocolViolation, .unsupportedVersion,
         .excessiveVersionLength, .unknownPacketType:
        return "\(target) answered, but it isn't speaking SSH. Check the port."
    case .keyExchangeNegotiationFailure, .invalidMacSelected, .unknownPublicKey, .unknownSignature,
         .weakSharedSecret:
        return "Bento and \(target) share no SSH algorithm they both accept."
    case .invalidExchangeHashSignature, .invalidHostKeyForKeyExchange, .invalidCertificate,
         .invalidOpenSSHPublicKey:
        return "The host key \(target) presented didn't verify."
    case .tcpShutdown:
        return "\(target) closed the connection during the SSH handshake."
    case .channelSetupRejected:
        return "\(target) accepted the login but refused to open a shell channel. "
            + "Check the account's shell and any ForceCommand in sshd_config."
    default:
        // NIOSSHError is CustomStringConvertible and its description carries
        // both the type and the diagnostic string — genuinely readable, unlike
        // its localizedDescription.
        return "SSH handshake with \(target) failed: \(error)"
    }
}
