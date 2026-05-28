# ryra-registry

Default service registry for [ryra](https://github.com/ryanravn/ryra).

Each top-level directory is a service definition (`service.toml`, quadlet files,
config templates, scripts, and tests). Cross-cutting lifecycle tests live under
`tests/`.

`ryra` fetches this repo on demand the first time you run `ryra add <service>`
or `ryra search`, and pulls updates with `ryra registry update`. To use a
different registry as the default, set the `RYRA_DEFAULT_REGISTRY` env var to a
local directory.

Add your own registry alongside this one with:

```
ryra registry add myorg https://github.com/myorg/my-ryra-registry.git
ryra add myorg/some-service
```
