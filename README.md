# swift-windows-dll-bundler

Reusable composite GitHub Action that copies all DLLs required to run a given
Windows executable into the same directory as the executable, so the result is
portable to a fresh Windows machine that has neither the Swift toolchain nor
the Visual C++ runtime installed.

The action:

1. Runs `dumpbin /DEPENDENTS` on the executable.
2. For every dependency:
   - If a DLL of the same name is sitting next to the executable, it is treated
     as a build product and kept.
   - Otherwise the dependency is only copied when it appears on a built-in
     allow-list of Swift, Foundation, libdispatch and MSVC runtime DLLs.
     DLLs that are not on the allow-list are assumed to be Windows system
     DLLs and are skipped.
3. Recurses into every copied DLL so transitive dependencies are bundled too.
4. Copies any matching `.pdb` files alongside their DLLs when present.

An allow-listed DLL that cannot be located on `PATH` is reported as an error.

The resolution and allow-list logic is a direct port of
[`GenericWindowsBundler.swift`](https://github.com/moreSwift/swift-bundler/blob/main/Sources/SwiftBundler/Bundler/GenericWindowsBundler.swift)
from `moreSwift/swift-bundler`.

## Requirements

- Windows runner.
- `dumpbin` (from MSVC) must be on `PATH`. Use
  [`compnerd/gha-setup-vsdevenv`](https://github.com/compnerd/gha-setup-vsdevenv)
  earlier in the job to enter a Visual Studio Developer environment.

## Inputs

| Input | Required | Description |
|---|---|---|
| `executable` | yes | Absolute path to the `.exe` whose dependencies should be bundled. DLLs are copied into the same directory. |

## Usage

```yaml
- uses: compnerd/gha-setup-vsdevenv@main

- uses: SwiftyLab/setup-swift@latest
  with:
    swift-version: "6.3.1"

- name: Build
  run: swift build -c release --product hello
  shell: pwsh

- name: Bundle DLLs next to hello.exe
  uses: hylo-lang/swift-windows-dll-bundler@v1
  with:
    executable: ${{ github.workspace }}\.build\release\hello.exe
```

## License

Apache-2.0. See [LICENSE](./LICENSE).
