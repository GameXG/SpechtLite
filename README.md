# SpechtLite

SpechtLite manages a TcpRoute runtime and its TOML profiles.

## TcpRoute Runtime

- Put the executable `TcpRoute` in `~/.SpechtLite`.
- Put one or more TcpRoute TOML profiles in the same directory, including `config.toml`.
- The app checks both the executable and at least one `.toml` profile at startup.
- TcpRoute owns routing and protocol support, including its integrated xray capability.

TcpRoute is started with the selected profile:

```text
TcpRoute -config ~/.SpechtLite/config.toml
```
