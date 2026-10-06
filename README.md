# hscript-seiun

[![CI](https://github.com/mohong2/hscript-seiun/actions/workflows/main.yml/badge.svg)](https://github.com/mohong2/hscript-seiun/actions/workflows/main.yml)

[English](README.md) | [中文](README_zh-CN.md)

A **super-combined HaxeScript runtime** for SeiunEngine — built on
[hscript-iris](https://github.com/crowplexus/hscript-iris) 1.1.3 as the base, fused
with [hscript-improved](https://github.com/FNF-CNE-Devs/hscript-improved) and
[hscript-plus](https://github.com/DleanJeans/hscript-plus).
All three are MIT-licensed; attribution is kept in [NOTICE](NOTICE).

Packages start at `hscript`: the merged runtime lives in `hscript.*`
(`hscript.Parser`, `hscript.Interp`, ...), with the iris utilities under
`hscript.iris.*`. The upstream `crowplexus` prefix is gone.

## Features

### From hscript-iris

- `import` + aliases (`import Foo as Bar`), `package`, `using`
- `final` constants, `enum`, `typedef` redirects
- null coalescing `??` / `??=`
- improved error handling and `showPosOnLog`
- for-loop iterator caching and other performance/memory optimizations

### From hscript-improved (FNF-CNE-Devs)

- **Script classes**: `class Foo { ... }`, `new Foo()`, fields/methods/`this`
- **CUSTOM_CLASSES macro**: script classes can `extends` engine classes
  (e.g. `class MySprite extends FlxSprite`); `_HSX` shadow classes are generated at
  compile time and engine methods can be overridden at runtime
- `scriptObject` (parent binding, `this` resolution)
- `static` / `public` variables and functions (`staticVariables` / `publicVariables`,
  `allowStaticVariables` / `allowPublicVariables`)
- `errorHandler`, `importFailedCallback`, `importBlocklist`, `importRedirects`
- `getRedirects` / `setRedirects`, `@:bypassAccessor`
- `_HSC` shadow classes for `Abstract` / `Enum` (UsingHandler macro)

### From hscript-plus

- **Script-to-script inheritance**: `class Dog extends Animal {}` (both script
  classes), instances are Dynamic objects with a `__sname__` + `super` chain;
  method overrides, inherited fields and `super.method()` all work
- access modifiers: `public` / `private` / `static` / `override` / `dynamic` / `inline`

### Merge extras

- Key-value for loops: `for (k => v in map)`
- Script-class static variables are truly shared across instances
- Class-field assignment syncs locals and the variable table, so `obj.field`
  always reads the freshest value

### Haxe syntax additions

- **String interpolation**: `"v=$x"`, `"v=${x + 2}"`, `"${obj.field}"`;
  `$$` is the escaped dollar, just like Haxe
- **`cast`**: both `cast (x, T)` (checked against resolvable classes, raises
  "Cast error" on mismatch) and `cast x` (unchecked)
- **`untyped`**: parsed and evaluated as the wrapped expression
- **Generic constructor type parameters**: `new Array<Int>()`,
  `new Array<Array<Int>>()` (types are discarded, like a compile-time concept)
- **Object shorthand** (Haxe 4): `{x}` means `{x: x}`
- **Destructuring declarations** (Haxe 4):
  `var [a, b] = arr;` and `var {x, y} = obj;`
- **Spread calls** and **rest args**: `f(...arr)` and `function f(a, ...rest)`
- **Static members via the class name**: `M.staticMethod()`, `S.staticVar`,
  `S.staticVar = 9` — static fields are evaluated once at class declaration
- **Switch guards**: `case v if (v > 3):` binds `v` to the switched value
- **Or-patterns** (Haxe 4.2+ style): `case 1 | 2:`, `case "a" | "b" if (cond):`.
  A parenthesised bitwise OR still works: `case (1 | 2):`
- **Guarded wildcard cases**: `case _ if (cond):`
- **Destructuring extensions**: rest (`var [a, ...rest] = arr;`), rename
  (`var {x: y} = obj;`), defaults (`var {x = 1} = obj;`), nesting
  (`var {a: [b, c]} = obj;`), destructuring in `for ([a, b] in pairs)`, and the
  assignment form (`[a, b] = f();`, `{x} = obj;`)
- **Generic functions**: `function f<T>(x:T):T` (type parameters are erased)
- **Map comprehensions**: `[for (k => v in map) k => v]`
- **Wildcard imports**: `import haxe.ds.*;`
- Untyped `catch (e)` and the bare empty statement `;`

Also fixed while testing: `++`/`--` on local variables, default values for
optional arguments, `?.` null-safe calls, and error propagation without
`-D hscriptPos`.

**Behaviour change in 1.3.0:** `case 1 | 2:` used to be parsed as the bitwise OR
expression `(1 | 2)` and therefore never matched anything. It is now an
or-pattern, matching Haxe. Write `case (1 | 2):` if you really mean the bitwise
OR.

## Performance

1.3.0 is a profiled rewrite of the parser and interpreter. Measured with the
bundled `bench/` harness on the eval target with `-D hscriptPos` (the engine's
configuration); see [bench/README.md](bench/README.md) for the methodology,
corpus and acceptance thresholds.

| | before | after | change |
| --- | --- | --- | --- |
| parse (TOTAL) | 26.38 ms | 22.12 ms | **-16%** |
| execute (TOTAL) | 63.00 ms | 39.36 ms | **-38%** |

Both columns are medians of seven interleaved runs that alternate between a pristine
`git archive HEAD` checkout and the 1.3.0 tree on the same machine, so the comparison is
like-for-like. Using the single best run of each instead gives -11% parse and -38% execute.

Highlights: a substring fast path for string literals, no closure allocation in
the tokenizer, an array-backed pending-token stack instead of per-token
`TokenPos` objects, interned single-character tokens, a shared operator table
instead of ~40 closures per `Interp`, and a single-instance script-class
instantiation path instead of building a shadow parent instance and a second
interpreter per inheritance level.

Run it yourself:

```powershell
$env:BENCH_LABEL='mine'
haxe -cp . -cp bench -D hscriptPos -D CUSTOM_CLASSES `
  --macro "hscript.macros.UsingHandler.init()" `
  --macro "hscript.macros.ClassExtendMacro.init()" -main Bench --interp
$env:BENCH_COMPARE='baseline,mine'
haxe -cp . -cp bench -D hscriptPos -D CUSTOM_CLASSES `
  --macro "hscript.macros.UsingHandler.init()" `
  --macro "hscript.macros.ClassExtendMacro.init()" -main Bench --interp
```

## Runtime preprocessor (`#if`)

Scripts get Haxe-style **conditional execution** (parsed at runtime — this is not
compile-time conditional compilation):

```haxe
#if android
var plat = "android";
#elseif ios
var plat = "ios";
#else
var plat = "other";
#end
```

Supports `#if` / `#elseif` / `#else` / `#end`, `!`, `&&`, `||` and parentheses.
A key counts as "defined" when it is **present** in `Parser.preprocessorValues`
(the value is irrelevant — same semantics as Haxe `#if`); nested `#if` blocks and
multi-branch `#elseif` chains pair correctly.

Engine hosts (e.g. SeiunEngine's `HScript`) inject platform keys by default:
`android` / `ios` / `windows` / `linux` / `mac` / `web` / `html5` /
`desktop` / `mobile` / `sys`, plus `engine` / `engineName` / `hscript`.
Custom keys are easy to add:

```haxe
parser.preprocessorValues.set("myFeature", true);
```

The historical misspelled alias `preprocesorValues` (missing an "s") still works,
and writes to it are synced into `preprocessorValues`.

## Installation

```bat
haxelib git hscript-seiun https://github.com/mohong2/hscript-seiun.git
```

or, for local development:

```bat
haxelib dev hscript-seiun <path-to-repo>
```

Then, in `project.xml`:

```xml
<haxelib name="hscript-seiun"/>
<!-- optional: enable script classes extending engine classes -->
<define name="CUSTOM_CLASSES"/>
```

The `extraParams.hxml` at the repo root automatically injects the two compile-time
macros (`UsingHandler.init()` / `ClassExtendMacro.init()`), so no manual setup is
needed. See [docs/SETUP.md](docs/SETUP.md) for Haxe / OpenFL / Flixel examples.

## Testing

```bat
haxe -cp . -cp test -D hscriptPos -D CUSTOM_CLASSES ^
  --macro hscript.macros.UsingHandler.init() ^
  --macro hscript.macros.ClassExtendMacro.init() ^
  -main TestMain --interp
```

Covers: iris syntax, script classes, script-to-script inheritance, shared statics,
error handlers, import callbacks, blocklist, scriptObject, redirects, `using`,
macro-extended classes (extends engine classes), Bytes roundtrip, Printer,
key-value for loops and the runtime `#if` preprocessor.
Test indices are also runnable standalone, e.g.
`-main TestConformance`, `-main TestParserSyntax`, `-main TestRuntimeExt`,
`-main TestMacrosLegacy`, `-main TestBytesCompat`.
Run the whole thing on Haxe 4.2.5 as well as 4.3.7 — both are supported and CI
covers both.

Benchmarks and the engine-level verification procedure are documented in
[bench/README.md](bench/README.md); the toolchain/cache matrix is in
[docs/COMPAT.md](docs/COMPAT.md).

## Configuration (macro scope)

`hscript.Config` controls the package prefixes scanned by the two macros
(defaults aligned with SeiunEngine's own package layout):

- `ALLOWED_CUSTOM_CLASSES`: packages whose classes get `_HSX` shadows
  (default `flixel/openfl/script/states/substates/backend/options/editors/mohong`)
- `ALLOWED_ABSTRACT_AND_ENUM`: packages whose abstracts/enums get `_HSC` shadows
- `DISALLOW_CUSTOM_CLASSES` / `DISALLOW_ABSTRACT_AND_ENUM`: module-level blocklist

**Warning:** do **not** add whole packages like `haxe` or `lime` — the macros would
process std classes and can break abstracts such as `haxe.Int64`; add specific
classes instead.

## Known limitations (inherited from upstream)

- `using StringTools;` (and `using` of a script class) works on the eval target as of
  1.3.0 - verified by probe. The upstream note about static-method reflection only
  applies to the neko target.
- Not implemented (tracked in [docs/FEATURES.md](docs/FEATURES.md)): object spread
  (`{...a, b: 1}`), switch array/object patterns (`case [a, b]:`, `case {x: v}:`),
  `enum abstract`, and comma-separated `implements I, J`.
- `hscript.Checker` static analysis is not wired into the runtime and has no test
  coverage.
- `hscript.Bytes` round-trips every supported construct and its format is now
  versioned, but nothing in the engine loads a cached script yet, so the cache does
  not currently save parse time at runtime. Decoding costs roughly a third of the
  parse phase; see [docs/COMPAT.md](docs/COMPAT.md).
- `import some.pkg.*;` resolves lazily: a Haxe runtime cannot enumerate a package, so a
  mistyped package prefix is accepted by `import` and fails on first use of one of its
  identifiers (`Unknown variable`) rather than at the `import` itself.
- In an or-pattern, an identifier alternative is a catch-all that matches any value and is
  tried left to right, so `case v | 5:` always matches through `v`. The guard only sees
  bindings made by the alternative that matched, which is why
  `case 5 | x if (x == 5):` raises `Unknown variable: x`.
- Script classes that override a `@:deprecated` base-class member fall back to the
  Haxe implementation; the shadow-class macro no longer generates a forwarding
  override for deprecated members (this is what removed the engine's `WDeprecated`
  warnings).

## License

MIT. This library is a merged derivative of four MIT projects:
hscript / hscript-iris / hscript-improved / hscript-plus.
Copyright and attribution are documented in [NOTICE](NOTICE) and [LICENSE](LICENSE).
