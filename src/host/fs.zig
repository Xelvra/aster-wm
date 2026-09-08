//! Dispatches to fs_native.zig (real OS filesystem, every non-wasm
//! backend) or fs_wasm.zig (JS/localStorage-backed) at compile time.
//! Everything else in the tree imports `fs.zig` and never needs to know
//! which one it got — Zig 0.16 dropped `usingnamespace`, so each name is
//! re-exported explicitly instead of forwarding the whole module.

const builtin = @import("builtin");
const impl = if (builtin.target.cpu.arch.isWasm()) @import("fs_wasm.zig") else @import("fs_native.zig");

pub const HostError = impl.HostError;
pub const Entry = impl.Entry;
pub const max_file_size = impl.max_file_size;

pub const errName = impl.errName;
pub const setIo = impl.setIo;
pub const read = impl.read;
pub const write = impl.write;
pub const list = impl.list;
pub const remove = impl.remove;
pub const rename = impl.rename;
pub const nowMs = impl.nowMs;
pub const realClock = impl.realClock;
pub const log = impl.log;
