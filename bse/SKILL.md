---
name: bse
description: Use the Basis Set Exchange (basis_set_exchange, installed as `bse`) to find, inspect, and fetch basis sets — CLI-focused (get-basis, list-basis-sets, lookup-by-role, get-info, convert-basis), plus the Python API and PySCF integration notes (roles jfit/jkfit/rifit, the gto BSE fallback, bse_meta.json).
whenToUse: When a task involves locating a basis set or auxiliary basis, fetching one in a given format, checking whether a basis exists in BSE, looking up recommended auxiliary (jfit/jkfit/rifit) bases, converting basis files, or anything related to the locally installed basis_set_exchange package or PySCF's BSE fallback.
---

# Basis Set Exchange (BSE)

The Basis Set Exchange package (`basis_set_exchange`) is installed locally
(`bse` on PATH; Python module `basis_set_exchange`). It ships a bundled data
library of basis sets — **no network needed** — plus a CLI and a Python API.

Quick facts:
- `bse -V` — version (0.12 here).
- Data lives in the package's `data/` dir (`bse get-data-dir`).
- Basis names are case-insensitive, e.g. `def2-mTZVPP-RIJ`.
- Formats: `bse list-formats`, `bse list-writer-formats`, `bse list-reader-formats`.
  There is **no `pyscf` format** — PySCF-style `.dat` is Gaussian94-like, so use
  `gaussian94` (or `nwchem`/`turbomole` and convert).

## CLI usage

### Fetch a basis set

```bash
# full output (header + all elements)
bse get-basis def2-mTZVPP-RIJ gaussian94

# only elements H,O; no header
bse get-basis def2-mTZVPP-RIJ gaussian94 --elements H,O --noheader

# write to file
bse get-basis def2-mTZVP nwchem -o def2-mTZVP.nw

# older version of a basis
bse get-basis cc-pVDZ gaussian94 --version 1
```

Useful `get-basis` flags: `--elements` (list, e.g. `H,O,Fe`), `--version`,
`--noheader`, `--unc-gen` / `--unc-spdf` / `--unc-seg` (uncontract),
`--opt-gen` / `--make-gen` (general contraction), `--get-aux ROLE`
(also fetch an auxiliary basis by role).

### Search and metadata

```bash
bse list-basis-sets -n                 # all basis names
bse list-basis-sets -s mtzvp -n        # names containing "mtzvp"
bse list-basis-sets -r jfit -n         # only jfit-role bases
bse list-basis-sets -f ahlrichs -n     # only one family
bse list-families                      # family list
bse get-info def2-mTZVPP-RIJ           # name, role, family, description
bse get-versions cc-pVDZ -n            # version numbers only
bse get-refs def2-mTZVP                # literature references
bse get-notes def2-mTZVP               # notes
bse get-family def2-mTZVP              # family name
```

### Auxiliary basis lookup (roles)

Roles: `jfit` (Coulomb/J for pure functionals), `jkfit` (J+K for hybrids),
`rifit` (MP2/RI), `dftjfit`, `optri`, `admmfit`.

```bash
bse lookup-by-role def2-QZVP jfit      # -> def2-universal-jfit
bse lookup-by-role def2-mTZVP jfit     # -> (no match: prints nothing/fails)
```

`def2-mTZVP`/`def2-mTZVPP` have **no jfit** in BSE's role tables — the 3c RI-J
auxiliary is stored as **`def2-mTZVPP-RIJ`** (role `jfit`, "RI-J basis for
r2SCAN-3c method"), shared by B97-3c and r2SCAN-3c.

### File conversion

```bash
bse convert-basis in.tm out.g94                    # turbomole -> gaussian94
bse convert-basis in.tm out.g94 --in-fmt turbomole # force input format
bse convert-basis in.g94 out.nw --make-gen         # general contraction
```

## Python API

```python
import basis_set_exchange as bse

bse.get_basis('def2-mTZVPP-RIJ', fmt='gaussian94')       # str
bse.get_basis('def2-mTZVP', elements=['H', 'O'])          # dict (BSE format)
bse.get_all_basis_names()
bse.lookup_basis_by_role('def2-QZVP', 'jfit')
bse.get_basis_family('def2-mTZVPP-RIJ')
# readers/writers: bse.read_formatted_basis_str(s, 'turbomole'),
#                  bse.write_formatted_basis_str(d, 'gaussian94')
```

Note: the BSE-dict from `get_basis` (without `fmt`) is the raw internal format
used by PySCF's converter `pyscf/gto/basis/bse.py` (`_orbital_basis`), and by
`pyscf.df.addons.bse_predefined_auxbasis` via `gto.mole.BSE_META` (the static
`pyscf/gto/basis/bse_meta.json` table, which maps AO basis -> recommended
auxiliary roles; **hand-editing it is discouraged** — prefer
`pyscf/df/addons.DEFAULT_AUXBASIS`).

## PySCF integration (context)

- `gto.M(basis='def2-mTZVPP-RIJ')` resolves any name not in PySCF's bundled
  library through the installed `basis_set_exchange` at runtime (fallback in
  `pyscf/gto/basis/__init__.py`); missing package -> warning + error.
- `density_fit()` aux basis selection: `pyscf.df.addons.DEFAULT_AUXBASIS`
  (optional 3rd "J-fit" column, used for pure functionals) then the
  `bse_meta.json` role table; falls back to even-tempered Gaussians.
- The 3c methods (B97-3c / r2SCAN-3c) use AO bases `def2-mTZVP`/`def2-mTZVPP`
  (bundled in PySCF) and the shared RI-J aux `def2-mTZVPP-RIJ` (from BSE).
