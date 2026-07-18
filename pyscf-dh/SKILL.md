---
name: pyscf-dh
description: Skill for developing the pyscf.dh double-hybrid DFT module. Covers class hierarchy, XC code system, MP2 backends, RespMixin patterns, pitfalls, testing, and linting.
---

# pyscf.dh Development

## Module Structure

```
pyscf/dh/
├── __init__.py          # DFDH factory + to_dh export
├── dh.py                # DHBase class, MP2 backend wrappers, to_dh()
├── resp.py              # RespMixin, RDHRespMixin, UDHRespMixin, GradientMixin + module-level helpers; prepare_pt2, make_rdm1_relaxed, dipole
├── rdfdh.py             # RDFDH (restricted), energy functions; module-level: get_eri_cpks, Ax0_*_HF/KS/resp, Ax0_cpks_HF
├── udfdh.py             # UDFDH (unrestricted), spin-specific overrides
├── dhutil.py            # Math, batching, storage (HybridDict, gen_batch, calc_batch_size, timing)
├── mp2_ajz.py           # AJZ MP2 (get_cderi_mo, _loop_t_ijab, ump2_ajz)
├── xccode/              # XC code parsing
│   ├── parse.py         # parse_xc_dh, xc_equal, _check_unsupported, _register_ext_params
│   ├── xccode.py        # XCList token parser (token, name_token), XCDH
│   ├── xcinfo.py        # XCInfo dataclass (parameters, parameters_keyword)
│   ├── xctype.py        # XCType bitfield flags
│   ├── xcjson.py        # JSON loader + normalization
│   ├── functionals/     # 3 family JSON files (bdh, xdh, post_hf)
│   └── correlations/    # definition_adv_corr.json + alias.json
├── grad/                # Nuclear gradients (RDFDH.Gradients, UDFDH.Gradients)
│   ├── dfdh.py          # Shared: GradientMixin, kernel, helpers (get_H_1_ao, etc.)
│   └── udfdh.py         # UDFDH.Gradients(UDHRespMixin, GradientMixin)
├── polar/               # Polarizabilities (RDFDH.Polar, UDFDH.Polar)
└── test/
```

## Class Hierarchy

```
DHBase(lib.StreamObject)                # dh.py — shared init, properties, energy methods (kernel, energy_nuc, etc.)
├── RDFDH(DHBase)                       # rdfdh.py — always restricted (dft.KS)
└── UDFDH(DHBase)                       # udfdh.py — always unrestricted (dft.UKS)

RespMixin(lib.StreamObject)             # resp.py — solve_cpks, prepare_D_r, make_rdm1_relaxed, dipole
├── RDHRespMixin(RespMixin)             # resp.py — restricted: prepare_pt2, prepare_integral, Ax0_*, prepare_lagrangian
│   ├── Gradients(RDHRespMixin, GradientMixin)  # grad/dfdh.py — flat wrapper, self.base = method
│   └── Polar(RDHRespMixin)                      # polar/rdfdh.py — flat wrapper, self.base = method
└── UDHRespMixin(RespMixin)             # resp.py — unrestricted: prepare_pt2, prepare_integral, Ax0_*, prepare_lagrangian
    ├── Gradients(UDHRespMixin, GradientMixin)  # grad/udfdh.py
    └── Polar(UDHRespMixin)                     # polar/udfdh.py

GradientMixin(lib.StreamObject)         # grad/dfdh.py — D3/D4 dispersion gradient
```

### Separation of concerns

- **`RDFDH` / `UDFDH`** — pure energy classes. Zero response methods (no `solve_cpks`, `prepare_D_r`, `dipole`, `prepare_lagrangian`, `prepare_integral`, `Ax0_*`). ``prepare_pt2`` lives on ``RDHRespMixin``/``UDHRespMixin``, not here.
- **`RespMixin`** — unified R/U response infrastructure: ``solve_cpks``, ``prepare_D_r``, ``make_rdm1_relaxed``, ``dipole``. Branching via ``self.D.ndim == 2`` (restricted) vs ``3`` (unrestricted).
- **`RDHRespMixin` / `UDHRespMixin`** — spin-specific: ``prepare_pt2``, ``prepare_integral``, ``Ax0_Core_HF/KS/Core/Core_resp``, ``Ax0_cpks``, ``prepare_lagrangian``.
- **`Gradients` / `Polar`** — flat wrapper classes. Do NOT inherit ``RDFDH``/``UDFDH``. Store original method as ``self.base``. Response methods via ``RespMixin`` MRO, energy methods via ``self.base.*``.

### `mf_or_mol` pattern

```python
class DHBase:
    def __init__(self, mf_or_mol, xc=..., *args, **kwargs):
        if isinstance(mf_or_mol, gto.Mole):
            mol = mf_or_mol; self._scf = None
        else:
            mol = mf_or_mol.mol; self._scf = mf_or_mol
        # tunable flags, XC parsing via parse_xc_dh, auxbasis, etc.

class RDFDH(DHBase):
    def __init__(self, mf_or_mol, xc=..., *args, **kwargs):
        super().__init__(mf_or_mol, xc, *args, **kwargs)
        if self._scf is not None:
            mf_s = self._scf               # validated: must match functional
        else:
            mf_s = dft.KS(mol, xc=self.xc).density_fit(...)
```

SCF object must be `dft.KS`/`dft.UKS` with matching functional (validated by `DHBase.__init__` via `xc_equal`). `scf.HF` raises `TypeError`.

### `to_dh(mf, xc, **kwargs)` (in `dh.py`)

Converts any converged KS/UKS to DH. Auto-converts non-KS objects:

```python
# Reuse: B3LYPg matches XYG3's SCF functional
dh = to_dh(dft.KS(mol, xc="B3LYPg").density_fit().run(), xc="XYG3").run()

# Auto-convert: PBE0 doesn't match B2PLYP → runs new B2PLYP SCF internally
dh = to_dh(dft.KS(mol, xc="PBE0").density_fit().run(), xc="B2PLYP").run()
```

## XC Code System (`xccode/`)

### `parse_xc_dh(xc_dh)` (in `xccode/parse.py`)

Returns `((xc, xc_n, c_os, c_ss), xc_add)` — **4-tuple, no `cc`** (always 1, removed).

Accepted formats:

| Format | Type | Example |
|---|---|---|
| Name string | `str` | `"B2PLYP"` |
| Code string | `str` | `"0.53*HF+0.47*B88,0.73*LYP+0.27*MP2"` |
| 2-tuple (scf, eng) | `tuple` | `("B3LYPg", "0.8033*HF+...+0.3211*MP2")` |
| 4-tuple (xc, xc_n, c_os, c_ss) | `tuple` | Legacy direct format |
| 5-tuple (xc, xc_n, cc, c_os, c_ss) | `tuple` | **DEPRECATED** — emits `FutureWarning` |

### `_register_ext_params` (in `xccode/parse.py`)

Registers custom libxc functionals for XC components with external parameters.
Handles two formats from `XCInfo`:

| Source | Format | Example |
|---|---|---|
| `parameters_keyword` (dict) | Named-param dict | `{'_alpha': 1.0, '_beta': -0.321208, ...}` |
| `parameters` (list) | Positional array | `[0.15, 0.88491, 0.047, ...]` |

**Positional array** (PTPSS, PWPB95): JSON uses `MGGA_X_TPSS(0.15, 0.88491, ...)` without `=` signs. `parameters` holds values in libxc order. Converted directly to numpy array.

**Named-param dict** (wB97X-2): JSON uses `HYB_GGA_XC_WB97X(_alpha=1, _beta=-0.321208, ...)`. `parameters_keyword` holds key-value pairs. **Must lowercase keys** before passing to `register_custom_functional_` — `xc_func_set_ext_params_name` expects lowercase (`_alpha`) but DH parses uppercase (`_ALPHA`).

### `name_token` (on `XCList`)

Use `xc_list.name_token` for `register_custom_functional_`, not `token`. `name_token` builds from `info.name` (without parenthesized params), while `token` includes `info.token` (with parens). Parenthesized params crash PySCF's `parse_xc()` which splits on commas.

### RSH functional support (wB97X-2)

RSH functionals like `HYB_GGA_XC_WB97X` are registered via `register_custom_functional_` with:
- `omega=[0.3]` — sets range-separation parameter via `customize_` → `_set_omega_density_threshold_`
- `rsh_coeff` returns correct `(omega, alpha, beta)` from C-level functional info
- Omega propagation through `numint` is automatic (no manual `mf_s.omega` needed)

**PySCF dependency**: Named-param ext_params require `LIBXC_xc_func_find_ext_params_name` in the shared library. Tests for wB97X-2 are conditionally skipped on PySCF < 2.14 via `@unittest.skipUnless(_HAS_NAMED_PARAMS)`.

### Marking unsupported functionals

Add `"supported": false` to filter out functionals using unimplemented features (RS_MP2, SIEPA, MP2cr). `_check_unsupported` in `parse.py` raises `NotImplementedError`.

Unsupported correlations in `correlations/definition_adv_corr.json` also marked `"supported": false` (IEPA, RS_MP2, MP2CR, SIEPA, RS_RING_CCD). DFTD4 and VV10 are supported (definitions exist, implementation pending).

### `xc_equal(a, b)` (in `xccode/parse.py`)

Compares XC tokens using `XCList.__eq__`. Handles `"HF"` vs `"HF,"` equivalence. Used for functional match validation in `DHBase.__init__` and HF detection in `RespMixin.prepare_D_r`.

## MP2 Backends

Three backends, dispatched in `RDFDH.__init__` via `partial(func, self)`:

| Backend | `mp2_backend=` | Wrapper | Returns `(val0, val1, val2)` |
|---|---|---|---|
| AJZ (default) | `"ajz"` | `mp2_ajz.energy_elec_mp2_ajz` | `(None, eng_bi1, eng_bi2)` |
| dfmp2_native | `"dfmp2_native"` | `dh.energy_elec_mp2_dfmp2_native` | `(emp2, None, None)` |
| dfmp2 (core) | `"dfmp2"` | `dh.energy_elec_mp2_dfmp2` | `(None, e_corr_os, e_corr_ss)` |

- `val0` = pre-scaled total (or `None`)
- `val1` = OS component (or `None`)
- `val2` = SS component (or `None`)

### `dfmp2_native` ps/pt mapping

```python
mp2.ps = mf.c_os   # opposite-spin (NOT mf.c_ss)
mp2.pt = mf.c_ss   # same-spin (NOT mf.c_os)
```

### `dfmp2` frozen support

```python
mp2 = DFRMP2(mf.mf_s, frozen=mf.frozen)
```

## Key Patterns

### Flat wrapper pattern (Gradients / Polar)

`nuc_grad_method()` / `polar_method()` return a NEW wrapper object, not mutating
the original:

```python
# rdfdh.py:
def nuc_grad_method(self):
    from pyscf.dh.grad.dfdh import Gradients
    return Gradients(self)   # returns new object; self remains RDFDH
```

The wrapper ``__init__`` copies state via ``__dict__.update`` and stores the
original as ``self.base``:

```python
class Gradients(RDHRespMixin, GradientMixin):
    def __init__(self, method):
        self.__dict__.update(method.__dict__)  # copy all data
        self.base = method                     # original energy object
        self.grad_jk = NotImplemented
        ...
```

**Mutable state**: Attributes that change after init (from ``run_scf``,
``prepare_pt2``, etc.) are stale in ``self.__dict__``.  Read them via
``self.base.*``:

- Properties: ``self.base.eval_pt2``, ``self.base.eval_ss``, ``self.base.eng_tot``
- Methods: ``self.base.get_memory()``, ``self.base.calc_batch_size()``, ``self.base.run_scf()``
- Kernel entry: ``self.base.build()``

**Kernel sync**: After ``run_scf()``, sync mutable data back:

```python
mf.base.run_scf()
mf.__dict__.update(mf.base.__dict__)
```

**``prepare_pt2`` on RespMixin**: ``prepare_pt2`` is defined on
``RDHRespMixin`` / ``UDHRespMixin`` (not on ``RDFDH``/``UDFDH``), so it
resolves via MRO on the wrapper and returns ``self`` (the wrapper).
This preserves method chaining (``self.prepare_pt2().prepare_lagrangian()``).

### MRO ordering for unrestricted RespMixin

The unrestricted Gradients/Polar must list `UDHRespMixin` **before** any restricted mixin so that unrestricted methods shadow restricted ones:

```python
# CORRECT — unrestricted methods take precedence:
class Gradients(UDHRespMixin, GradientMixin):
# UDHRespMixin.prepare_pt2(U) takes priority over any R version
```

### `prepare_D_r` calls `solve_cpks`

Both restricted and unrestricted branches in `RespMixin.prepare_D_r` use `self.solve_cpks(L)` consistently. No inlined `cphf.solve(...)` — the `solve_cpks` method handles R/U dispatch and zero RHS shortcuts.

### `eng_bi` tuple format (3 values)

```python
DHBase.kernel(self.base, eng_bi=(None, 0, 0))                         # non-PT2
DHBase.kernel(self.base, eng_bi=(None, eng_bi1[0], eng_bi2[0]))       # PT2
```

On wrappers, ``DHBase.kernel`` is called with ``self.base`` so energy
attributes (``e_tot``, ``eng_tot``, etc.) are set on the energy object,
then synced back via ``__dict__.update``.

### `_loop_t_ijab` shared batch loop (in `mp2_ajz.py`)

```python
def _loop_t_ijab(mf, Y_ia_ri, mo_energy, nocc, nvir, callback):
    # Shared by energy_elec_mp2_ajz and prepare_pt2
    for sI in gen_batch(0, nocc, nbatch):
        t_ijab, g_ijab = ...
        callback(sI, t_ijab, g_ijab)
```

### Module-level helpers (`resp.py`)

All response helpers live in `resp.py` with `_r_` (restricted) or `_u_` (unrestricted) prefixes:

```
_r_get_eri_cpks, _r_Ax0_Core_HF, _r_Ax0_Core_KS, _r_Ax0_Core_resp, _r_Ax0_cpks_HF
_u_get_eri_cpks, _u_Ax0_Core_HF, _u_Ax0_Core_KS, _u_Ax0_cpks_HF
```

The `_u_Ax0_Core_KS` uses `transform_vxc(rho, ..., spin=1)` and `nr_uks_fxc`; `_r_Ax0_Core_KS` uses `spin=0` and `nr_rks_fxc`.

### `hermi_sum_last2dim` gotcha

`reshape(-1, ...)` on non-C-contiguous arrays silently copies. `inplace=True` then modifies the copy, not the original. For polar code, use `arr += arr.swapaxes(-1, -2)` instead.

## Test Conventions

### File naming

```
test_xccode.py         # XC parsing unit tests
test_rdfdh.py          # Restricted energy + backend tests + frozen core
test_udfdh.py          # Unrestricted energy + backend tests + frozen core
test_dfdh_dipole.py    # Analytical vs num-diff dipole
test_dfdh_grad.py      # Analytical vs num-diff gradient
test_dfdh_polar.py     # Analytical vs num-diff polarizability
test_udfdh_grad.py     # Unrestricted gradient
test_udfdh_polar.py    # Unrestricted polarizability
test_low_mem.py        # Low-memory batching correctness
```

### Numdiff pattern

Most tests use hardcoded reference values. A few keep live numdiff for sanity:

```python
# Live numdiff
nde = NumericDiff(NucCoordDerivGenerator(mol, ...)).derivative.reshape(-1, 3)
de = DFDH(mol, xc).nuc_grad_method().run().grad_tot
assert np.allclose(nde, de, atol=1e-5, rtol=1e-4)
```

### Dipole path

```python
d = DFDH(mol, xc).run().nuc_grad_method().dipole()
```

## Test After Edit

Run the minimal test subset matching the scope of changes. Avoid numdiff tests for quick iteration — use hardcoded reference tests instead.

**Use the `@test` subagent**: Invoke `@test auto` to auto-discover which tests to run based on `git diff`. The subagent maps changed files to the test table below and runs the minimal subset automatically. You can also pass specific test paths: `@test pyscf/dh/test/test_xccode.py -v`.

### By file changed

| Changed file | Run these tests | ~Time |
|---|---|---|
| `xccode/parse.py`, `xccode/xcinfo.py`, `xcjson.py`, `*.json` | `test_xccode.py` | 2s |
| `xccode/xccode.py` | `test_xccode.py test_dfdh_extra.py::test_PTPSS` | 5s |
| `dhutil.py` | `test_xccode.py test_low_mem.py` | 5s |
| `dh.py` (DHBase, MP2 wrappers) | `test_xccode.py test_rdfdh.py::TestRDFDH::test_mp2_backend` | 15s |
| `mp2_ajz.py` | `test_rdfdh.py::TestRDFDH::test_mp2_backend test_dfdh_grad.py::TestDFGrad::test_b2plyp` | 30s |
| `rdfdh.py` (energy, kernel) | `test_rdfdh.py` | 30s |
| `udfdh.py` | `test_udfdh.py` | 30s |
| `resp.py` (RespMixin, helpers) | `test_dfdh_grad.py::TestDFGrad::test_b2plyp test_udfdh_grad.py::TestUDFGrad::test_b2plyp test_dfdh_polar.py::TestDFPolar::test_mp2` | 0.5s |
| `grad/dfdh.py` | `test_dfdh_grad.py::TestDFGrad::test_b2plyp` | 0.5s |
| `grad/udfdh.py` | `test_udfdh_grad.py::TestUDFGrad::test_b2plyp` | 0.5s |
| `polar/rdfdh.py` | `test_dfdh_polar.py::TestDFPolar::test_mp2` | 0.5s |
| `polar/udfdh.py` | `test_udfdh_polar.py::TestUDFPolar::test_mp2` | 0.5s |
| Moving R/U helpers between files | One grad + one polar test in each spin (4 tests) | 2s |

All tests in this table use hardcoded reference values. Numdiff tests (`test_mp2` in grad, `test_b2plyp` in polar) are excluded — they validate correctness against finite differences but are too slow for quick iteration (~2 min each).

**No extra pipeline verification**: Do not run manual ``python -c "from pyscf.dh import DFDH; ..."`` checks after each change. The existing test suite covers all computation paths. Only add extra manual verification when the changed code path is **not** exercised by any existing test. Trust the test results otherwise.

### Commands

```bash
# Fast sanity check (always run before commit):
pytest pyscf/dh/test/test_xccode.py pyscf/dh/test/test_rdfdh.py -v

# After RespMixin/response changes:
pytest pyscf/dh/test/test_dfdh_grad.py::TestDFGrad::test_b2plyp \
       pyscf/dh/test/test_udfdh_grad.py::TestUDFGrad::test_b2plyp \
       pyscf/dh/test/test_dfdh_polar.py::TestDFPolar::test_mp2 -v

# Pre-push full suite (includes numdiff sanity tests):
pytest pyscf/dh/test/ -v
```

## Common Pitfalls

1. **`@timing` decorator on class definitions**: `@timing` turns callables into functions. If placed before `class RDFDH(...):`, the class becomes a function — metaclass conflicts and attribute errors follow. Always remove `@timing` decorators that precede class definitions.

2. **MRO shadowing**: `UDFDH.kernel` (energy) shadows `Gradients.kernel`. Always set `kernel = kernel` on the Gradients class itself. For unrestricted, list `UDHRespMixin` before `GradientMixin` so unrestricted response methods aren't shadowed by restricted ones.

3. **Transcription errors in copied module-level functions**: When copying R/U variants of `get_eri_cpks`, `Ax0_Core_HF`, etc., verify: coefficients differ (restricted uses 4×, unrestricted uses 2× in `get_eri_cpks` same-spin term), `tot_size` preflop must be included in batch size calculation, `spin=0` vs `spin=1` in `transform_vxc`, `nr_rks_fxc` vs `nr_uks_fxc`.

4. **`cc` removed**: No `self.cc` anywhere. `parse_xc_dh` returns 4-tuple `(xc, xc_n, c_os, c_ss)`. 5-tuple legacy format emits `FutureWarning`.

5. **`self.C` / `self.e` aliases removed**: Use `self.mo_coeff` and `self.mo_energy`. `self.Co`/`self.Cv`/`self.eo`/`self.ev` remain.

6. **XC_DH_MAP / XC_DH_ADD_MAP removed**: All functionals routed through JSON + `xccode/parse.py`.

7. **`pyscf.dftd3` replaced with `pyscf.dispersion`**: D3/D4 via `DFTD3Dispersion`/`DFTD4Dispersion`.

8. **`unrestricted` flag removed**: No `self.unrestricted` anywhere. Use `self.D.ndim == 2` (restricted) vs `3` (unrestricted) for runtime branching.

9. **`TYPE_CHECKING` removed**: `from __future__ import annotations` blocks gone. Functions are not type-checked.

10. **No in-function imports**: All imports go at module level.

11. **Stale state on flat wrappers**: ``Gradients``/``Polar`` copy data from
    the energy object via ``__dict__.update(method.__dict__)`` at init time.
    Attributes that change after init (e.g. ``mo_coeff`` after ``run_scf``,
    ``eng_tot`` after ``DHBase.kernel``) are stale on the wrapper. Access
    mutable data through ``self.base.*`` and sync back with
    ``self.__dict__.update(self.base.__dict__)`` after ``run_scf``.

12. **``prepare_pt2`` on RespMixin**: ``prepare_pt2`` lives on
    ``RDHRespMixin``/``UDHRespMixin``, not on ``RDFDH``/``UDFDH``.
    This is required for MRO resolution on flat wrappers (Gradients/Polar
    don't inherit energy classes) and for correct method chaining.

13. **``tempfile.NamedTemporaryFile`` for temp files**: ``HybridDict`` uses
    ``tempfile.NamedTemporaryFile``.  ``HybridDict.close()`` closes the h5py
    handle before the temp file handle; ``__del__`` calls ``close()``.
    (``lib.NamedTemporaryFile`` is unavailable in older PySCF.)

14. **Ext-param key case**: ``xc_func_set_ext_params_name`` expects lowercase
    param names (``_alpha``). DH parses JSON into uppercase
    (``_ALPHA``). Always apply ``k.lower()`` when building named ext-param
    dicts in ``_register_ext_params``. Uppercase keys are silently ignored by
    libxc.

15. **``name_token`` for registration**: When calling
    ``register_custom_functional_``, use ``xc_list.name_token`` (built from
    ``info.name``, no parenthesized params) as the ``based_on_xc_code``. The
    full ``token`` includes parenthesized ext-param values which crash
    PySCF's ``parse_xc()`` (splits on commas). ``name_token`` returns e.g.
    ``HYB_GGA_XC_WB97X`` instead of
    ``HYB_GGA_XC_WB97X(_ALPHA=1, _BETA=-0.321208, ...)``.
