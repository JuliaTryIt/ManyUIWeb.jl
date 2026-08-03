# Upstream bugs

## HTTP.jl 2.6.1 does not translate an asynchronous bind failure

- **Upstream:** HTTP.jl 2.6.1 / Reseau.jl 1.3.4
- **Platform observed:** macOS ARM64, Julia 1.12.6
- **Status:** Workaround in `src/server.jl`

Starting a second `HTTP.listen!` server on an occupied port raises a
`TaskFailedException` containing
`Reseau.HostResolvers.OpError(SystemError(..., EADDRINUSE))`. HTTP.jl's server
documentation and source comments indicate that host/port bind failures should
instead be translated synchronously to `HTTP.AddressInUseError`.

ManyUIWeb recursively inspects the task and operation-error causes and matches
the platform `EADDRINUSE` errno. This preserves its public `PortInUseError`
without adding a direct dependency on the lower-level Reseau transport.
