# API reference

```@meta
CurrentModule = ManyUIWeb
```

## Enumerations

```@docs
SessionState
ControlKind
```

## The neutral transport

The server drives anything satisfying these two interfaces; it names no UI
framework. ManyUI is one frontend, Tachikoma another.

```@autodocs
Modules = [ManyUIWeb]
Pages = ["transport.jl"]
```

## Frontends

```@docs
serve_tachikoma
```

## Everything else

```@autodocs
Modules = [ManyUIWeb]
Pages = ["protocol.jl", "assets.jl", "wsdriver.jl", "session.jl",
         "server.jl", "backend.jl"]
```
