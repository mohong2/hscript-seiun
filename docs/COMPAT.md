# Compatibility

This document records the toolchain matrix, the script-cache (`hscript.Bytes`) format
contract, and the known differences between supported Haxe versions.

## Supported toolchains

| Toolchain | Path (local dev machine) | Status |
| --- | --- | --- |
| Haxe 4.2.5 | `C:\\HaxeToolkit\\haxe\\haxe.exe` | supported |
| Haxe 4.3.7 | `C:\\HaxeToolkit\\haxe-4.3.7\\haxe.exe` (default on PATH) | supported |
| Haxe latest | resolved by CI | supported (regression guard) |

The engine ships scripts that are compiled by Haxe 4.2.5 through 4.3.7, so library code
must not use 4.3-only syntax. CI (`.github/workflows/main.yml`) runs the whole suite on
all three versions.

## Running the suites

Both suites are compiled with the engine-equivalent flags
(`-D hscriptPos -D CUSTOM_CLASSES` plus the two init macros):

```powershell
# functional suite (test/TestMain.hx)
haxe -cp . -cp test -D hscriptPos -D CUSTOM_CLASSES --macro "hscript.macros.UsingHandler.init()" --macro "hscript.macros.ClassExtendMacro.init()" -main TestMain --interp

# Bytes / Async / cross-version suite (test/TestBytesCompat.hx)
haxe -cp . -cp test -D hscriptPos -D CUSTOM_CLASSES --macro "hscript.macros.UsingHandler.init()" --macro "hscript.macros.ClassExtendMacro.init()" -main TestBytesCompat --interp
```

Swap the `haxe` executable for the 4.2.5 one to run the other half of the matrix.
Both suites exit non-zero when a check fails.

Expected: `TestBytesCompat` reports `144 passed, 0 failed` on 4.2.5 and 4.3.7.

## Script cache format (`hscript.Bytes`)

`Bytes.encode(ast)` / `Bytes.decode(bytes)` serialise a parsed script so a host can skip
parsing on later loads.

### Version byte

The first byte of every stream is `Bytes.FORMAT_VERSION` (currently **255**).
`decode()` rejects anything else with
`Unsupported hscript bytes format version N (this build writes/reads version 255)`,
and an empty stream with `Empty hscript bytes stream`. A pre-versioning cache can never
start with 255 (it started with string-table marker `0` under `hscriptPos`, or with an
`ExprDef` tag in `0...31`), so old caches fail loudly instead of decoding into a corrupt
tree. Bump `FORMAT_VERSION` whenever the layout changes.

The frozen part of the contract is `hscript.Expr.ExprDef`: **no new variants and no arity
changes**. Cache bytes are allowed to change; AST shape is not.

### What round-trips

Every construct the parser produces is encoded/decoded and executed identically, with
`encode(decode(x)) == encode(x)` (byte-stable). `TestBytesCompat` asserts this for:
constants (including non-finite floats), identifiers, parenthesised expressions, blocks,
fields (including `?.` chains), arrays, object literals (including quoted/JSON keys),
calls and spread calls, `new`, every binary and assignment operator, unary operators and
`++`/`--`, `if`/`while`/`do-while`/`for` (including `for (k => v in m)`),
`break`/`continue`/`return`, functions (named, anonymous, optional, default-valued,
rest), `try`/`catch` with typed catches, `throw`, ternaries, metadata (with arguments),
`ECheckType` (`cast(x, T)`), imports (aliased and unaliased), `using`, typedefs,
packages, enums (simple and with constructor arguments), classes (static members,
inheritance, `super`, `implements`), and the desugared newer syntax (string
interpolation, `untyped`, generics, arrow functions, destructuring, multi-value cases).

Payload limits are encoded as variable-length integers, so scripts with more than 255
distinct strings, string literals longer than 254 bytes, or more than 255 call arguments /
object fields no longer truncate.

### Format v2 changes

- leading `FORMAT_VERSION` byte (see above);
- string lengths use a 1-byte fast path plus an escape (`255` + encoded Int) for long
  literals, and collection counts are variable-length;
- `CType` is now encoded (`EVar`, `ETry`, `EFunction` return type, `ECheckType`,
  `Argument.t`). Before this, a cached `cast(x, String)` decoded as `cast(x, Void)` and a
  cached `catch (e:String)` caught everything;
- `Argument.value` (default argument values) is now encoded, so `function f(b:Int = 2)`
  behaves the same before and after a cache hit;
- `Argument.rest` is carried in the flags byte;
- the string-table reset now matches between encoder and decoder (>= 255 distinct strings).

### Known limitations

- `EDirectValue` stores its payload through `haxe.Serializer`; values that serializer
  cannot represent cannot be cached.
- Positions are only stored when the library is compiled with `-D hscriptPos`. Without it
  the cache omits `origin`/`line` (by design).
- `EIgnore` is encoded as an empty block (a runtime no-op); it is dropped by the parser
  before it can reach a cache in practice.

### Measured cost (eval target, `hscriptPos`, best-of-7, Haxe 4.3.7)

Absolute times on this host are noisy (a busy CPU moved the same corpus by up to ~50% between
runs), so read the within-run parse/decode ratio rather than the milliseconds. On the final
revision:

```
corpus       parse    encode   decode   exec     parse+exec  enc+dec+exec  delta
gameplay     9.755    2.978    7.519    2.227    11.982      12.724         +6.2%
classheavy   1.009    0.254    0.613   18.659    19.669      19.526         -0.7%
expression   0.702    0.206    0.504   34.743    35.445      35.453         +0.0%
shapes      18.504    5.510   12.665    3.329    21.833      21.504         -1.5%
TOTAL       29.970    8.949   21.300   58.958    88.928      89.208         +0.3%
```

Decoding is roughly **29% faster than parsing** the same source, but encode+decode costs about
as much as parsing does, so a cache only pays off when the same script is loaded repeatedly
(encode once, decode many times). It is not a substitute for parser or interpreter work: after
the parser optimisations the two are close enough that a cold load-and-run no longer benefits.
(The Lead's authoritative interleaved benchmark is the source of truth for parser/interpreter
speed: parse TOTAL -10.6% min / -16.1% median, exec TOTAL -37.5%.)

## Async

`hscript.Async` / `hscript.Async.AsyncInterp` (the CPS transformer) compiles and runs on
4.2.5 and 4.3.7; `TestBytesCompat` exercises it so a regression cannot go unnoticed.
Unsupported constructs still fail loudly with `Unsupported async expression`.

## Cross-version notes

No behavioural differences were observed between 4.2.5 and 4.3.7 for the test suites or
the cache round-trips. The 4.2.5 eval target is roughly 2x slower overall, which scales
both parse and execution times but not their ratio.