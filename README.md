# ryra-registry

Default service registry for [ryra](https://github.com/ryanravn/ryra).

Each top-level directory is a service definition (`service.toml`, quadlet files,
config templates, scripts, and tests). Cross-cutting lifecycle tests live under
`tests/`.

`ryra` fetches this repo on demand the first time you run `ryra add <service>`
or `ryra search`, and pulls updates with `ryra registry update`. To use a
different registry as the default, set the `RYRA_REGISTRY_DIR` env var to a
local directory.

Add your own registry alongside this one with:

```
ryra registry add myorg https://github.com/myorg/my-ryra-registry.git
ryra add myorg/some-service
```


## Cross-service contracts

- `<services-root>/caddy-root-ca.crt`: caddy exports its internal root CA
  here (one level above every service home) after start. Recipes that need
  to trust `.internal` https endpoints (OIDC discovery from inside a
  container) read it from `$(dirname "$SERVICE_HOME")/caddy-root-ca.crt`,
  never from a hardcoded home path, so sandboxed installs stay sandboxed.
  This file is the ONLY sanctioned cross-service state at the services
  root; anything else a recipe wants to share needs a declared mechanism,
  not a sibling file.
