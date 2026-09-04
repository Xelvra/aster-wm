# ADR-001 — Host contract, not a kernel

**Status:** accepted

## Context

aster grew out of `aster-os`, an experimental kernel. The desktop it produced turned out to
be the interesting part; the kernel turned out to be scaffolding. The obvious next move —
"port it to a better kernel", with seL4 the usual suggestion — is the move that would kill
the project.

seL4's one real value is formal verification, and verification is orthogonal to a hackable
Lua desktop: you would pay the whole price and receive none of the benefit, since the
verification does not extend to your drivers. Getting a framebuffer, a keyboard and a Lua
interpreter onto seL4 is months of work with Microkit, a capability model and almost no
driver ecosystem. It would lock the interesting thing behind unbounded platform work again
— exactly the problem we are leaving behind.

## Decision

There is no kernel in this project. There is a **host contract**: twelve functions that
supply pixels, events, time and files. Anything that can implement those twelve functions
can run aster.

The kernel from `aster-os` is not the foundation. It is backend #4.

## Consequences

- Every platform decision becomes a directory in `src/backends/`, not an architecture change.
- The contract is the thing we protect. Adding a function is work for every present and
  future backend, so it requires an ADR.
- If seL4 is ever wanted, the right order is the reverse of the obvious one: keep the
  contract small enough that an seL4 backend is a weekend, then do it as backend #5, for
  the effect.
- We give up any claim to isolation or verification. `wm.lua` runs with full host
  permissions and always will. This is stated plainly in the README rather than hedged.
