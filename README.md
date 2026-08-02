# ManyUIWeb.jl

**ManyUIWeb** is the web backend for [`ManyUI`](https://github.com/s-celles/ManyUI.jl): run the exact same application in a browser instead of a terminal, with no change to the widget tree or the application logic.

## 📖 Documentation

For the complete API reference, features overview, quickstart guides, and advanced examples, please see the central documentation repository:

👉 **[Read the Documentation (ManyUIDoc)](https://s-celles.github.io/ManyUIDoc.jl/)**

## Installation

```julia
import Pkg; Pkg.add("ManyUIWeb")
```

Non-blocking launches return the same lifecycle contract as other ManyUI
backends:

```julia
server = launch(ui, WebNative(); wait=false)
isopen(server)
close(server)
wait(server)
```
