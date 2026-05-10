# Contributing to meowctl-registry

This registry is a static index of meowctl modules. It maps module names to
tarball URLs and version lists. It does **not** host tarballs — each module
maintains its own repository and GitHub Releases.

## How the registry works

`index.toml` is served directly from `main` via `raw.githubusercontent.com`.
The meowctl loader fetches it, resolves a version with MVS, downloads the
tarball from the `source` URL, verifies the SRI hash, and extracts to the
local cache.

## Entry format

Each module entry in `index.toml` looks like this:

```toml
[modules.my-module]
versions   = ["0.1.0", "0.2.0"]
source     = "https://github.com/author/my-module/releases/download/v{version}/my-module-{version}.tar.gz"
integrity  = "sha384-<base64-of-latest-version-tarball>"
```

**Fields:**

| Field       | Required | Description |
|-------------|----------|-------------|
| `versions`  | yes      | Ascending semver list. Most-recent version last. |
| `source`    | yes      | URL template. `{name}` and `{version}` are substituted at resolution time. |
| `integrity` | yes      | W3C SRI hash (`sha384-<base64>`) of the **latest** version tarball. Per-version hashes are recorded in the consumer's lock file by the loader. |

## Tarball structure

Tarballs must be `.tar.gz` archives. The following files are required at the
archive root (not nested under a directory):

```
MODULE.meow      # Required. Lists dependencies via dep() calls. May be empty.
<files>.star     # One or more Starlark files the module exports.
```

`MODULE.meow` is a Starlark file evaluated with a single builtin `dep(name, version)`.
A module with no dependencies may have an empty `MODULE.meow`.

Example `MODULE.meow`:

```python
dep("hello", "0.1.0")
```

## Computing the SRI hash

Given a tarball `my-module-0.2.0.tar.gz`, compute the sha384 SRI string with:

```sh
openssl dgst -sha384 -binary my-module-0.2.0.tar.gz | base64
```

Prefix the output with `sha384-` to get the full SRI string:

```
sha384-<base64 output>
```

Include this value as the `integrity` field for the new version.

## Publishing a new module

1. Create a public GitHub repository for your module (e.g. `author/my-module`).
2. Add `MODULE.meow` at the repo root (empty if no deps; add `dep()` calls for each dependency).
3. Add your `.star` files at the repo root.
4. Pack the tarball (files at root, no wrapping directory):
   ```sh
   tar -czf my-module-0.1.0.tar.gz MODULE.meow *.star
   ```
5. Create a GitHub Release tagged `v0.1.0` and upload the tarball as a release asset.
6. Compute the SRI hash (see above).
7. Open a PR against this repository adding your entry to `index.toml`:
   - Append your version to the `versions` array (ascending semver order).
   - Set `source` to the GitHub Release download URL template.
   - Set `integrity` to the sha384 SRI of the new tarball.
8. CI will validate your PR automatically (see below).

## Publishing a new version of an existing module

Follow the same steps as above. In `index.toml`:

- **Append** the new version to `versions` — do not remove old versions.
- **Update** `integrity` to the SRI hash of the new tarball.
- The `source` template typically stays the same if your release URL pattern
  is consistent.

## No-overwrite policy

**Published versions are immutable.** Once a version appears in `index.toml`
and is merged to `main`, it must never be removed or modified. The meowctl
lock file relies on version stability for reproducible installs.

If a published tarball must be replaced (e.g. security fix), publish a new
version (patch bump). Do not delete or re-upload the existing release asset.

## CI validation

Every PR is validated automatically by `.github/workflows/validate.yml`.
The check:

- Parses `index.toml` and reports TOML syntax errors.
- Verifies no existing `(module, version)` pair has been modified or removed.
- Sends a HEAD request to each tarball URL to confirm it is reachable (HTTP 200).

PRs that fail validation will not be merged.
