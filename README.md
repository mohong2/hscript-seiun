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

Also fixed while testing: `++`/`--` on local variables, default values for
optional arguments, `?.` null-safe calls, and error propagation without
`-D hscriptPos`.

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

- `Async.hx` / `Checker.hx` already had compile issues in hscript-iris 1.1.3
  (type mismatches under `hscriptPos`); the engine runtime does not reference them.
  This library only applies minor fixes (EField args).
- `using StringTools` relies on static-method reflection, which is unavailable under
  `neko --interp` (upstream behavior); it works on native cpp targets.
- Script-class constructor chains: with `class Child extends Parent`, parent fields
  are re-evaluated on the child instance and the parent constructor runs only once;
  explicit `super.new()` is not guaranteed to bind to the child instance
  (same behavior as hscript-improved upstream).

## License

MIT. This library is a merged derivative of four MIT projects:
hscript / hscript-iris / hscript-improved / hscript-plus.
Copyright and attribution are documented in [NOTICE](NOTICE) and [LICENSE](LICENSE).
