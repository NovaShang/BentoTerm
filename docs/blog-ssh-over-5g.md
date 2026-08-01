# The SSH connection that only failed on 5G

*How a thirty-second timeout with no packets on the wire turned out to be the
operating system helpfully rewriting our address.*

Bento Term connects an iPhone to a Mac over plain SSH. The Mac sits behind a home
router; the phone reaches it over Tailscale. On Wi-Fi it connects instantly. On 5G it
would sit there spinning and then fail — not always, but often enough to be useless.

The bug turned out to have nothing to do with SSH, tmux, timeouts, or any of the four
things I was sure it was. This is the write-up, including the wrong turns, because the
wrong turns are the interesting part.

## The symptom

The app reported `Connect timeout (30 s)`. Nothing else. Every failure looked identical.

The first thing worth knowing about a connect timeout is *where* the packets stopped. On
the Mac, `last` and the `sshd` unified log showed successful logins from the phone's
tailnet address earlier in the day — but during a failing attempt, nothing at all. No
`sshd` process spawned, no half-open connection, no trace. The SYN was not arriving.

Meanwhile the tunnel itself was healthy. From the Mac:

```
$ tailscale ping iphone-14-pro
pong from iphone-14-pro (100.78.227.117) via DERP(lax) in 160ms
...
direct connection not established
```

Relayed through DERP — the Mac is behind a symmetric NAT and the phone behind carrier
CGNAT, so no direct path is possible — but working, in both directions, at 60–900 ms.

## Four wrong turns

Before I had any device logs I built a theory out of what the Mac could see. Every step
of it was defensible and every step of it was wrong. In order:

**"It's the handshake timeout."** Citadel (the Swift SSH client we use) hardcodes a 10 s
login timeout that isn't exposed through its public API. An SSH handshake is six to eight
round trips; at 900 ms RTT that is 5–7 seconds, and a spike would blow through it. Neat
theory. The log said `Connect timeout (30 s)`, and 30 s is the *TCP* bootstrap timeout,
not the 10 s login one. The handshake never started.

**"It's the session-discovery timeout."** The iOS session picker opens a whole separate
SSH connection just to run `tmux ls`, waits a fixed 500 ms for the shell to settle, then
gives the command 5 seconds. On a relayed link that budget is marginal, and on timeout it
silently returns an empty list. Real problem — I found and verified it — but it happens
*after* a connection exists, and we never got one.

**"It's the three redundant SSH connections."** Every attach opened three: the picker's
discovery connection, the real one, and the picker again afterwards. Three cold
handshakes triples your exposure to any per-connection failure. Also real, also not this.

**"BSD sockets don't work through a VPN on cellular."** Safari, Termius and Tailscale's
own app all reached the Mac from the phone at moments when Bento could not. Those use
Network.framework; SwiftNIO uses a plain BSD socket. The story wrote itself.

That last one was close enough to be dangerous, so I stopped theorising and put probes in
the app.

## The probes

Four questions, answered inside the app, at the moment of a real failing connect:

1. What does the OS think the network path is?
2. Can Network.framework reach the peer?
3. Can a bare BSD socket — ours, not NIO's — reach it?
4. Can a BSD socket reach it if we bind the source to the tunnel's address?

The answers, from one run on 5G:

```
path: status=satisfied v4=false v6=true expensive=true ifaces=[pdp_ip0:cellular,utun8:other]
ifaces: ... pdp_ip0/v4=192.0.0.2 ... utun8/v4=100.78.227.117 utun8/v6=fd7a:115c:a1e0::3601:e395

Network.framework      -> 100.116.71.126:22: ok in 180ms
BSD socket             -> 100.116.71.126:22: ok in 70ms
BSD socket bound to utun8 -> 100.116.71.126:22: ok in 61ms
SSH connection error after 30031ms: Connect timeout (30 s)
```

A plain BSD socket, in the same app, in the same second, connected in **70 milliseconds**
— while NIO timed out after thirty seconds. So much for the socket API theory. Whatever
was wrong lived above the socket.

Two things in that dump matter later. `path: v4=false` — the carrier is IPv6-only; the
`192.0.0.2` on `pdp_ip0` is the 464XLAT translation address, not a real IPv4 address. And
my probe reached the peer using `inet_pton` on the literal, with **no DNS involved at
all**. NIO takes a `String`.

## The answer

Two more probes. First, resolve the address exactly the way NIO's resolver does — same
hints, no `AI_NUMERICHOST`. Second, run two NIO connects side by side: one by hostname
string, one with a pre-parsed `SocketAddress`.

```
getaddrinfo("100.116.71.126")  -> v6:2607:7700:0:a:0:2:6474:477e
NIO connect(host:)             -> failed after 10022ms: Connect timeout
NIO connect(to: SocketAddress) -> ok in 76ms
```

We asked for an IPv4 address. The system gave us an IPv6 one.

Look at the last 32 bits: `6474:477e`. That is `0x64 0x74 0x47 0x7e` = **100.116.71.126**
— our address, embedded verbatim under the carrier's NAT64 prefix
`2607:7700:0:a:0:2::/96`. `getaddrinfo` returned *only* that, no IPv4 at all, so Happy
Eyeballs had exactly one candidate and it was the wrong one.

This is documented, deliberate Apple behaviour. On an IPv6-only network with NAT64/DNS64,
`getaddrinfo` synthesises an IPv6 address from an IPv4 *literal*, so that apps which
hardcode IPv4 addresses keep working: the packets go out to the carrier's NAT64 gateway,
which translates them back to IPv4 on the far side. For a public address it is exactly
right.

For an address that only exists inside a VPN it is fatal. `100.64.0.0/10` is the CGNAT
range Tailscale hands out; it is routable inside the tunnel and nowhere else. The
synthesised address sent our connection out through the carrier's gateway toward a
destination the public internet cannot reach. The packets went nowhere. The tunnel — up,
healthy, 60 ms away — was never used.

Wi-Fi is dual-stack with no DNS64, so nothing is synthesised, so it always worked. Safari
and Termius never fed an IP literal to the resolver. Every observation lines up.

And NIO never short-circuits literals: `ClientBootstrap.connect(host:port:)` builds a
`GetaddrinfoResolver` and hands it the string, whatever the string is.

## The fix, and the fix that didn't work

The honest fix is to skip resolution entirely — parse the literal into a `SocketAddress`
and connect to that. Citadel even has an entry point for it: `SSHClient.connect(on:)`
takes a channel you built yourself.

It crashes:

```
NIOCore/ChannelPipeline.swift:1208: Precondition failed
```

`connect(on:)` installs its handlers with `pipeline.syncOperations`, which requires the
caller to be on the channel's event loop. On Citadel's normal path that code runs inside
the bootstrap's `channelInitializer`, where it is. `connect(on:)` calls it directly from
the caller's `async` context, where it is not. The documented escape hatch is unusable
from Swift concurrency — which is presumably why no test covers it.

So we go around instead. `::ffff:100.116.71.126` is the IPv4-mapped form of the same
address. It is *already* an IPv6 literal, so `getaddrinfo` has nothing to synthesise and
returns it verbatim, and the kernel routes it as IPv4 straight into the tunnel. The whole
fix is four lines:

```swift
private static func connectAddress(for hostname: String) -> String {
    guard let parsed = try? SocketAddress(ipAddress: hostname, port: 0),
          case .v4 = parsed else { return hostname }
    return "::ffff:" + hostname
}
```

Hostnames pass through untouched — there the resolver is doing its job, and synthesis for
a real name is correct.

Four Citadel bugs came out of this and are written up with patches to send upstream: the
literal going through the resolver, a convenience overload that silently discards three of
its parameters, `connect(on:)` returning before authentication completes, and the event
loop trap above.

## What I'd do differently

**A timeout is not a diagnosis.** "Connect timeout (30 s)" and "Connect timeout (10 s)"
came from two different subsystems and meant completely different things, and I spent an
hour on a theory that the digits had already ruled out.

**Localised error strings destroy evidence.** The original code logged
`error.localizedDescription`, which for NIO and Citadel errors is the same uninformative
sentence for every possible cause. Switching to `String(reflecting:)` is what made the
first log readable.

**Differential probes beat theories.** Every theory I formed from the server side was
wrong. The bug was found by running four connects to the same address from the same
process in the same second and changing exactly one variable at a time. The decisive
evidence was two lines: one API timing out and another succeeding in 76 ms.

**The layer you suspect is rarely the layer that's lying.** I suspected SSH, then tmux,
then the socket API. It was the name resolver — for an address that was never a name.
