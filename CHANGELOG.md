# 1.3.0 — performance, syntax and legacy repairs

This release is a rewrite pass over the whole runtime: the parser and interpreter were profiled and
optimised, the script language was brought closer to Haxe, and a long list of latent bugs that the
Haxe 4.3.7 / OpenFL 9.5.2 / Lime 8 upgrade exposed were fixed.

## Performance

Measured with the new `bench/` harness (`bench/README.md`) on the eval target with `-D hscriptPos`,
which is the configuration the engine always uses. `TOTAL` is the aggregate over the four corpus
scripts; best-of-9 rounds, so the figure is stable to about +/-6%.

| | before | after | change |
| --- | --- | --- | --- |
| parse (TOTAL) | 26.38 ms | 22.12 ms | **-16%** |
| execute (TOTAL) | 63.00 ms | 39.36 ms | **-38%** |

Both columns are medians of the same seven interleaved runs, alternating between a pristine
`git archive HEAD` checkout and the 1.3.0 tree on the same machine, so they are a like-for-like
comparison rather than two measurements taken under different load. Taking the single best run of
each instead of the median gives -11% parse and -38% execute; the machine was a busy desktop, so
treat the parse figure as -11% to -16% and the execute figure as about -38% either way.
The internal goal was -25% parse; it was not reached. The remaining parse cost is structural
(per-token dispatch and one `Expr` allocation per node under `-D hscriptPos`), not micro-fixable.

Parser work:

- String literals without an escape or `$` take a substring fast path instead of allocating a
  `StringBuf` and a closure; the slow path only runs for escapes/interpolation.
  `readString` never builds a closure any more.
- `_token` was a local function inside `token()`, which allocated a closure on every single token;
  it is an ordinary method now.
- The pending-token stack under `-D hscriptPos` is three parallel arrays indexed by depth instead of
  a list of freshly allocated `TokenPos` objects — one allocation removed per pushed token.
- Single-character identifiers and operators are interned and shared instead of being re-sliced.
  Multi-character operators and identifiers are sliced straight out of the source instead of being
  built one `String.fromCharCode` at a time.
- `parseStructure` consults a keyword `Map` before running its 29-case statement switch, and operator
  precedence lookups are hoisted out of the hot paths.
- `-D PERFCOUNT` enables allocation/visit counters for further profiling.

Interpreter work:

- The operator table is built once and shared instead of allocating ~40 closures on every
  `new Interp()`; the entries receive the executing interpreter as an argument.
- Script-class instantiation no longer builds a throw-away shadow parent instance and a second
  `Interp` per inheritance level. One instance is created, ancestor fields are evaluated on it in
  order, and `super` becomes a scope over per-level function snapshots. This is also what makes
  `super.new(...)` initialise the child instance (see the bug list below).
- `resolve()` uses a single `locals.get()` instead of `exists()` + `get()`.

## New syntax

- **Or-patterns** in `switch`: `case 1 | 2:`, `case "a" | "b" if (cond):`. This matches Haxe 4.2+
  switch-pattern syntax. A bitwise OR still works when parenthesised: `case (1 | 2):`.
  **Behaviour change:** `case 1 | 2:` used to be silently parsed as the bitwise OR expression
  `(1 | 2)` and therefore never matched; it is now an or-pattern.
- **Guarded wildcard cases**: `case _ if (cond):` (previously any `_` case was hoisted into the
  switch default, which broke the guard and made a later `default:` a parse error).
- **Destructuring extensions**: rest (`var [a, ...rest] = arr;`), rename (`var {x: y} = obj;`),
  defaults (`var {x = 1} = obj;`), nesting (`var {a: [b, c]} = obj;`), destructuring inside `for`
  (`for ([a, b] in pairs)`), and the assignment form (`[a, b] = f();`, `{x} = obj;`).
- **Generic functions**: `function f<T>(x:T):T`, including class methods. Type parameters are erased
  at parse time, like generic constructor type parameters already were.
- **Map comprehensions**: `[for (k => v in map) k => v]`.
- **Wildcard imports**: `import haxe.ds.*;`.
- **Object spread**: `{...a, b: 1}`.
- Untyped `catch (e)` and the bare empty statement `;`.

## Legacy bug fixes

- **`new ScriptClass(arg)` was completely broken** for script classes without a Haxe base class:
  `Type.createInstance(TemplateClass, args)` threw "Something went wrong" before the script's own
  constructor ran. Script-class constructors with arguments now work, including inherited ones.
- **`super.new(...)`** in a script subclass did not initialise the child instance.
- **`ClassExtendMacro` emitted deprecation warnings that pointed into the macro file itself.**
  Shadow classes generate an `override` + `_HX_SUPER__` forwarder per member, and the generated
  `super.<name>(...)` call carried the macro's own position, so a whole engine build printed five
  `WDeprecated` warnings (`stateSwitched`, `gameStarted`, `sound.group`) attributed to
  `hscript/macros/ClassExtendMacro.hx:239/257`. Deprecated members are now skipped when generating
  the override/forwarder pair; a full engine build reports zero warnings from this file.
  **Behaviour consequence:** a script that overrides a `@:deprecated` member is no longer routed
  through the interpreter and falls back to the Haxe base implementation.
- **`Math`, `Std` and `Map` did not resolve** from scripts (`Unknown variable: Math`,
  `Class not found: Map`). `new Map()` now produces a working map.
- **`hscript.Bytes` (the compiled-script cache) was almost entirely broken.** Fixed: operator
  encode/decode (every operator except `+` either threw or silently decoded as a different one, and
  compound assignment lost its `=`), missing `=>` / `++` / `--` op codes, unguarded switch cases
  (`ifExpr == null` threw), unaliased imports, the 255-string table desync, non-finite floats,
  dropped rest arguments, `EIgnore` stream desync, and the stream/count limits that silently
  truncated long strings. The format is now versioned (leading version byte, loud rejection of
  unknown versions) and additionally carries default argument values and full `CType` data, so a
  cached script behaves identically to a freshly parsed one.
- **`hscript.Async` had never type-checked** (it was dead code that CI never compiled). It now
  compiles and its transforms run.
- **`IrisConfig.localBlocklist` was stored but never enforced** — only the global
  `Iris.blocklistImports` reached the interpreter.
- **`hscript.Printer` dropped or corrupted several node kinds**, found by round-trip tests: switch
  guards (`SwitchCase.ifExpr`) were lost entirely, `switch` was printed without a space before the
  subject, rest arguments were dropped, spread arguments were printed with the wrong fixity,
  `EMeta` varargs printed the wrong expression, `ECheckType` printed `(e :  : T)`, string escaping
  ignored backslash and `$`, `1.0` printed as `1` and re-parsed as an integer, and array-comprehension
  targets were not parenthesised.
- `Tools.mk` / `Tools.map` had no return type annotation, so they produced plain anonymous objects
  rather than `hscript.Expr` instances at runtime.

## Compatibility, testing and tooling

- CI now runs Haxe **4.2.5**, **4.3.7** and `latest`, and runs both `TestMain` and `TestBytesCompat`.
- New test suites: `TestConformance` (broad language regression table), `TestParserSyntax`,
  `TestRuntimeExt`, `TestMacrosLegacy`, `TestBytesCompat`, `TestHarness`.
- New `bench/` harness plus `bench/README.md` (methodology, corpus, acceptance thresholds) and
  `docs/COMPAT.md` (toolchain matrix and cache format contract).
- `docs/FEATURES.md` rewritten as a checkable feature list.

---
# 1.2.0 - package rename

- Renamed the `crowplexus.hscript.*` packages to `hscript.*` and
  `crowplexus.iris.*` to `hscript.iris.*` - packages now start at `hscript`.
- Updated the `CUSTOM_CLASSES` macros, engine integration, tests, docs and CI
  accordingly. Upstream authorship (`crowplexus`) is preserved in NOTICE.

---

# 1.1.0 — Haxe syntax additions

- String interpolation: `"$var"`, `"${expr}"`, `"${obj.field}"`, `$$` escape.
- `cast` in both forms: checked `cast (x, T)` and unchecked `cast x`.
- `untyped` pass-through, generic constructor type parameters
  (`new Array<Int>()`), object shorthand (`{x}`).
- Destructuring declarations: `var [a, b] = arr;`, `var {x, y} = obj;`
  (including inside functions).
- Spread calls (`f(...arr)`) and rest arguments (`function f(a, ...rest)`).
- Static members accessible through the class name (`M.f()`, `S.x = 9`);
  static fields are evaluated once at class declaration.
- Switch guards bind the case variable (`case v if (v > 3):`).
- Fixed: `++`/`--` not writing back to local variables (upstream iris bug),
  optional-argument default values, `?.` null-safe calls, and errors being
  swallowed as "Cannot call null" without `-D hscriptPos`.
- Test suite grew from 48 to 70 assertions.

---

# 1.0.0 — hscript-seiun

- Merged hscript-iris 1.1.3, hscript-improved and hscript-plus into one drop-in
  runtime under the `hscript` / `hscript.iris` packages.
- Script classes (`_HSX` shadow classes), script-to-script inheritance, static/public
  variables, import callbacks/redirects, `scriptObject`, key-value for loops.
- Fixed the runtime preprocessor: `#if` / `#elseif` / `#else` / `#end` now handle
  nested blocks, `elseif` chains and sibling `#if` blocks with Haxe-like semantics.
- Added `Parser.preprocessorValues` (plus the legacy `preprocesorValues` alias) so
  hosts can feed platform/engine defines into scripts.
- Replaced the upstream CI with a test-suite workflow (Haxe latest + 4.3.7, `--interp`).

---

# 1.1.3

- Better `using`s
	- You can now call the `using` statement with most classes
	- You can make your project's classes usable by implementing an interface
		```haxe
		class CoolUtil implements hscript.iris.IrisUsingClass {}
		```
	- Customizable using parsing by using @:irisUsableEntry(forceAny, onlyBasic), arguments are optional
	- You can also prevent a function from being used by adding `@:irisNoUse` over the function.
	- `@:noUsing` will also work for that same purpose, but careful, this also prevents you from using it in source.
	
- Classes imported like `flixel.text.FlxText.FlxTextBorderStyle` are now supported.

# 1.1.2

- Fixed `package;` (unnamed) crashing the script.
- Script Package now gets saved in the parser.

# 1.1.1

- Added `package path;` syntax
	- This gets ignored by the interpreter, its simply there to prevent any issues
- Added `using` keyword
	- Right now, this is sort of limited, as you can only use it with `StringTools` and `Lambda`
- Fixed `#end` preprocessor value
	- Your script will no longer crash if you make a code like
		```haxe
		#if openfl
		trace("project is using the OpenFL library.");
		#end
		```
# 1.1.0

Collaborators in this update:
[Ne_Eo](https://github.com/NeeEoo)

- Added Enumerator support, along with constructors.
	- As of now, some functions in the Standard Library `Type` might not be available for scripted enums.
- Added Typedef support.
- Improved importing.
- Improved error handling.
- ANSI Colour support for the console when printing errors.

# 1.0.2

- Haxe 4.2.5 support

# 1.0.1

- Fix packaging, add changelog to the files, Fix some errors.

# 1.0.0

- Initial Haxelib Release
