// Wrapper target for the `GhosttyKitBinary` xcframework: carries the linker
// settings the static libghostty needs. No Swift code lives here — the C API
// is imported directly via `import GhosttyKit` from the binary module.
