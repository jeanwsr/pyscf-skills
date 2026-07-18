---
name: pyscf-general
description: Skill for developing in the PySCF quantum chemistry codebase. Provides conventions, project structure, patterns, and pitfalls for coding, testing, and debugging in PySCF.
---

# PySCF Development

## Project Overview

PySCF is a Python-based quantum chemistry framework. The package lives under `pyscf/` with C/C++ extensions compiled via CMake. The top-level `pyscf/__init__.py` exports version and plugin discovery; computational modules are organized by method family.

## Module Hierarchy

| Submodule | Purpose |
|---|---|
| `pyscf/lib/` | Foundation: `StreamObject` base class, C-extension loader, numpy/linalg wrappers, logging, DIIS, chkfile I/O, parameters |
| `pyscf/gto/` | Molecular structure, basis set parsing, `libcint` integral interface |
| `pyscf/scf/` | Hartree-Fock (RHF, UHF, ROHF, GHF, DHF) |
| `pyscf/dft/` | Kohn-Sham DFT (inherits from SCF) |
| `pyscf/cc/` | Coupled cluster (CCSD, CCSDT, CCSDTQ, EOM) |
| `pyscf/ci/` | Configuration interaction (CISD) |
| `pyscf/mcscf/` | CASCI, CASSCF (1-step and 2-step) |
| `pyscf/mcpdft/` | MC-PDFT (on-top pair-density functionals) |
| `pyscf/df/` | Density fitting / RI |
| `pyscf/ao2mo/` | AO-to-MO integral transformation |
| `pyscf/pbc/` | Periodic boundary conditions (mirrors molecular module hierarchy) |
| `pyscf/tools/` | FCIDUMP, molden, cubegen exporters |
| `pyscf/solvent/` | Continuum solvation |
| `pyscf/fci/` | Full CI solvers |
| `pyscf/mp/` | MP2, MP3, MP4 |
| `pyscf/tdscf/` | Time-dependent HF/DFT |
| `pyscf/grad/` | Nuclear gradients |
| `pyscf/hessian/` | Hessians |
| `pyscf/geomopt/` | Geometry optimization |
| `pyscf/x2c/` | Exact two-component relativistic methods |
| `pyscf/symm/` | Point-group symmetry |
| `pyscf/agf2/` | Algebraic Green's function GW |
| `pyscf/adc/` | Algebraic diagrammatic construction |
| `pyscf/mrpt/` | Multi-reference perturbation theory |
| `pyscf/eph/` | Electron-phonon coupling |
| `pyscf/data/` | Physical constants, element data |

## Key Abstractions

### StreamObject (`pyscf/lib/misc.py`)

The base class for nearly all computational objects. Provides a fluent "pipe" API:

- **`.set(**kwargs)`** — updates attributes via `setattr`, returns `self`. `__call__` is aliased to `.set`.
- **`.run(*args, **kwargs)`** — calls `.set(**kwargs)` then `.kernel(*args)`, returns `self`.
- **`.kernel(*args, **kwargs)`** — the main computational driver; each subclass overrides this.
- **`.apply(fn, *args, **kwargs)`** — applies `fn` to `self`: `return fn(self, *args, **kwargs)`.
- **`.check_sanity()`** — validates attributes against `_keys` set, warns on misspelled/overwritten attributes.
- **`.copy()`** — shallow copy via `view(self.__class__)`.
- **`_keys`** — class attribute listing valid attribute names.

Example: `mol.apply(scf.RHF).run(conv_tol=1e-5).apply(mcscf.CASSCF, 6, 4)`

### Mole and `__getattr__` dispatch (`pyscf/gto/mole.py`)

`mol.RHF()`, `mol.CCSD()`, etc. work through `Mole.__getattr__` which:
1. Imports `pyscf.__all__` (triggers lazy loading of all modules)
2. Looks up the key in `dft`, then `scf` modules
3. Returns a `_MoleLazyCallAdapter` wrapping the factory function

So `mol.RHF()` → `scf.RHF(mol)`, `mol.CCSD()` → `scf.HF(mol).run().CCSD()`.

### Chkfile auto-creation (`pyscf/scf/hf.py:1772-1775`)

In `SCF.__init__`:
```python
if MUTE_CHKFILE:
    self.chkfile = None
else:
    self._chkfile = lib.NamedTemporaryFile(dir=lib.param.TMPDIR)
    self.chkfile = self._chkfile.name
```

When `MUTE_CHKFILE` is `False` (default), every SCF object auto-creates a temp chkfile. The `_chkfile` handle keeps the file alive. Downstream classes (CASSCF, CCSD, TDSCF, AGF2, MC-PDFT) inherit chkfile via `self.chkfile = self._scf.chkfile` or `self.chkfile = mf.chkfile`.

**CI sets `scf_hf_SCF_mute_chkfile = True`** in `.pyscf_conf.py`, making all auto-chkfiles `None`. Tests that read `.chkfile` MUST explicitly assign one.

### Configuration (`pyscf/__config__.py`)

Loaded from first found of: `PYSCF_CONFIG_FILE` env var, `./.pyscf_conf.py`, `~/.pyscf_conf.py`. Key variables defined in `pyscf/lib/parameters.py`:
- `TMPDIR` — scratch file location
- `MAX_MEMORY` — memory limit in MB
- `LIGHT_SPEED`, `BOHR` — physical constants

Modules read config via `getattr(__config__, 'key', default)`.

## libxc Custom Functionals (`pyscf/dft/libxc.py`)

### `register_custom_functional_` API

```python
register_custom_functional_(new_name, based_on_xc_code,
    ext_params={libxc_id: array_or_dict},
    omega=[omega_value],
    hyb=(sr_hyb, sr_hf, omega))
```

Registers a custom functional under `new_name` by cloning `based_on_xc_code` then applying customizations. Stored in module-level `_CUSTOM_FUNC_R` / `_CUSTOM_FUNC_U` dicts and accessed via `_get_xc()`.

### Named-param ext_params

`XCFunctionalCache.customize_` accepts dict-format ext_params alongside traditional positional arrays:

```python
# Positional array (traditional):
ext_params = {202: numpy.array([0.15, 0.88491, ...])}

# Named-param dict:
ext_params = {202: {'_b': 0.15, '_c': 0.88491, ...}}
```

Dict-format uses `xc_func_set_ext_params_name` to set each parameter individually by name, avoiding libxc's positional-order dependency. Validation via `LIBXC_xc_func_find_ext_params_name` — unknown names raise `ValueError`.

### C wrapper (`pyscf/lib/dft/libxc_itrf.c`)

`LIBXC_xc_func_find_ext_params_name` wraps libxc's static `xc_func_find_ext_params_name`. Returns index ≥ 0 if the param name is valid for the functional, -1 otherwise.

### ctypes bindings

```python
_itrf.xc_func_set_ext_params_name.argtypes = (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_double)
_itrf.xc_func_set_ext_params_name.restype = None
_itrf.xc_func_get_ext_params_name.argtypes = (ctypes.c_void_p, ctypes.c_char_p)
_itrf.xc_func_get_ext_params_name.restype = ctypes.c_double
_itrf.LIBXC_xc_func_find_ext_params_name.argtypes = (ctypes.c_void_p, ctypes.c_char_p)
_itrf.LIBXC_xc_func_find_ext_params_name.restype = ctypes.c_int
```

Bindings go at module level in `libxc.py`, alongside existing `_itrf.*` bindings.

### Validating param names

Use `LIBXC_xc_func_find_ext_params_name` before `xc_func_set_ext_params_name`:

```python
if _itrf.LIBXC_xc_func_find_ext_params_name(func, name.encode()) < 0:
    raise ValueError(f"Unknown ext_params name '{name}'")
```

Note: `xc_func_get_ext_params_name` returns 0.0 for nonexistent names (not NaN), so it cannot be used for validation.

### Registered functional lifetime

Custom functionals persist in `_CUSTOM_FUNC_R` / `_CUSTOM_FUNC_U` until explicitly removed via `unregister_custom_functional_()`. The `XCFunctionalCache` objects hold references to C-level functional pointers managed by libxc. Registration and unregistration perform C-level init/end respectively.

## Test Conventions

### File structure
- Tests in `test/` subdirectory of each module: `pyscf/scf/test/test_rhf.py`
- Single `KnownValues(unittest.TestCase)` class per test file
- Module-level `setUpModule()` / `tearDownModule()` for shared expensive objects

### Patterns
```python
def setUpModule():
    global mol, mf
    mol = gto.M(verbose=7, output='/dev/null', atom='...', basis='cc-pvdz')
    mf = scf.RHF(mol)
    mf.conv_tol = 1e-10
    mf.chkfile = lib.NamedTemporaryFile().name
    mf.kernel()

def tearDownModule():
    global mol, mf
    mol.stdout.close()
    del mol, mf
```

### Assertions
- `self.assertAlmostEqual(value, expected, ndigits)` — primary assertion
- `lib.fp(array)` — deterministic array fingerprint: `dot(cos(arange(n)), a.ravel())`
- `_high_cost` and `_skip` suffixes exclude tests from default runs (configured in `pytest.ini`)
- `@unittest.skipIf(condition, reason)` for optional dependencies

### Chkfile in tests
- CI sets `MUTE_CHKFILE = True` → auto-chkfiles are `None`. Tests MUST explicitly set `mf.chkfile = lib.NamedTemporaryFile().name` if `.chkfile` is read later.
- Tests that don't read `.chkfile` don't need explicit assignment.
- `test_ghf.py` has `scf.hf.MUTE_CHKFILE = True` at module top — the only test file that globally disables auto-chkfile.
- Use `os.path.join` to construct expected paths in assertions, never hardcode `/` or `\`.

### Running tests
```bash
pytest pyscf/scf/test/                      # default (skips _high_cost, _skip)
pytest pyscf/scf/test/ -k "_high_cost"      # include expensive
pytest pyscf/scf/test/test_rhf.py::KnownValues::test_init_guess_chk
```

### `@test` subagent

Use the `@test` subagent to run tests with automatic ruff linting:

- `@test auto` — auto-discovers which tests to run based on `git diff`
- `@test pyscf/scf/test/test_rhf.py -v` — specific test file
- `@test pyscf/scf/test/ -v` — whole test directory

### Linting
```bash
ruff check --config .ruff.toml pyscf
flake8 pyscf   # test directories excluded
```

## Import Conventions

- `from pyscf import lib` (not `import pyscf.lib`)
- `from pyscf import gto, scf, dft, cc, mcscf`
- Submodules: `from pyscf.scf import hf` for direct class access
- `pyscf/__all__.py` provides lazy imports for post-HF modules — not loaded at `import pyscf` time

## Build System

C extensions compiled via CMake (`pyscf/lib/CMakeLists.txt`), invoked by custom `CMakeBuildPy` in `setup.py`. Key extensions:
- `libnp_helper` — OMP threads, BLAS-wrapped array ops
- `libcvhf` — J/K matrix construction
- `libcgto` / `libcint` — Gaussian integrals (wraps qcint/libcint v6.1.3)
- `libdft` — XC functional grids
- `libao2mo` — integral transformation
- `libpbc` — periodic integrals
- `libxc_itrf` — libxc C interface wrapper (functional init/end, eval_xc, param setters/getters)

Build deps: CMake 3.22+, BLAS, numpy, scipy, h5py.

### Rebuilding after C changes

```bash
cd /path/to/pyscf/pyscf/lib/build/dft && cmake --build .
```

### CI environment
- `OMP_NUM_THREADS=4`
- `.pyscf_conf.py` sets `scf_hf_SCF_mute_chkfile = True`, `TMPDIR = "./pyscftmpdir"`
- Tests fail if temp files remain in `pyscftmpdir` after run

## GitHub CLI (`gh`)

The GitHub CLI is available for PR review, branch management, and CI inspection. The repo is `pyscf/pyscf`.

### Pull request review
```bash
# View PR summary and metadata
gh pr view 3255 --repo pyscf/pyscf

# View PR as JSON (title, author, files, state, etc.)
gh pr view 3255 --repo pyscf/pyscf --json title,body,author,files,additions,deletions,state,headRefName

# Full unified diff
gh pr diff 3255 --repo pyscf/pyscf

# Check out a PR branch locally
gh pr checkout 3255 --repo pyscf/pyscf

# List review comments on a PR
gh api repos/pyscf/pyscf/pulls/3255/comments
```

### Viewing CI checks
```bash
# List CI runs for a branch
gh run list --repo pyscf/pyscf --branch high_order_cc_improvements --limit 5

# Watch a specific CI run as it progresses
gh run watch <run-id> --repo pyscf/pyscf
```

### Issue workflows
```bash
# List / filter open issues
gh issue list --repo pyscf/pyscf --limit 20
gh issue list --repo pyscf/pyscf --label bug
gh issue list --repo pyscf/pyscf --search "libxc"

# View an issue (with discussion thread)
gh issue view 2864 --repo pyscf/pyscf --comments

# JSON output for scripting
gh issue view 2864 --repo pyscf/pyscf --json title,body,labels,state,comments

# Cross-referenced PRs/commits for an issue
gh api repos/pyscf/pyscf/issues/2864/timeline
```

### Common patterns
- When reviewing a PR, start with `gh pr view` for metadata, then `gh pr diff` for the code changes.
- After reviewing the diff, `gh pr checkout` to test locally.
- `gh run list` + `gh run watch` to track CI status for a PR branch.
- When investigating a bug report: `gh issue view --comments` first, then search for duplicates/related issues, then check the timeline for linked PRs.

## Common Pitfalls

1. **MUTE_CHKFILE**: CI disables auto-chkfiles. Tests reading `.chkfile` must assign explicitly: `mf.chkfile = lib.NamedTemporaryFile().name`.

2. **Path separators**: use `os.path.join` in both production and test code. Never hardcode `/` or `\`.

3. **`__setstate__` sets chkfile to None**: `generate_pickle_methods(excludes=('chkfile', ...))` in SCF and derived classes sets `chkfile = None` on unpickle. Deserialized objects need explicit chkfile reassignment.

4. **`NamedTemporaryFile().name` without storing handle**: the file handle must be kept alive until all I/O is complete. Inline `.name` is fine for read-once patterns but the file object must persist through writes.

5. **`mol.HF()` always calls `SCF.__init__`**: via `__getattr__` dispatch. Auto-chkfile is created unless `MUTE_CHKFILE` is set.

6. **`H5TmpFile` with explicit filename**: when `filename=None` (default), `delete_on_close=True` and the file is auto-cleaned. When an explicit filename is passed, `delete_on_close=False`.

7. **Basis parser paths**: basis set paths are resource paths within the package, constructed with `os.path.join`. Tests must use `os.path.join` for expected paths, not hardcoded separators.

8. **`xc_func_set_ext_params_name` expects lowercase**: libxc parameter names are lowercase by convention (``_alpha``, ``_beta``). Passing uppercase names silently fails — the C function is case-sensitive.

9. **`xc_func_get_ext_params_name` returns 0.0 for unknowns**: invalid param names return 0.0 (not NaN). Use ``LIBXC_xc_func_find_ext_params_name`` (returns -1) to validate before setting.
