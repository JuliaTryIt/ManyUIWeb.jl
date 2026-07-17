# API reference

```@meta
CurrentModule = DualUIWeb
```

## Enumerations

```@docs
SessionState
ControlKind
```

## The neutral transport

The server drives anything satisfying these two interfaces; it names no UI
framework. DualUI is one frontend, Tachikoma another.

```@autodocs
Modules = [DualUIWeb]
Pages = ["transport.jl"]
```

## Frontends

```@docs
serve_tachikoma
```

## Everything else

```@autodocs
Modules = [DualUIWeb]
Pages = ["protocol.jl", "assets.jl", "wsdriver.jl", "session.jl",
         "server.jl", "backend.jl"]
```
