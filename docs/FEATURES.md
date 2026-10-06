# FEATURES

Legend: `[x]` implemented and covered by the test-suite, `[ ]` not implemented.

## Performance

- [x] Parser: string-literal fast path (no StringBuf/closure when a literal has no escape or `$`)
- [x] Parser: interned single-character ident/operator tokens; array-backed pending-token stack under `-D hscriptPos`
- [x] Parser: keyword pre-filter before the 29-case statement switch; operator/identifier slicing instead of per-char `String.fromCharCode`
- [x] Interp: shared operator table (no ~40 closures allocated per `Interp`), zero-arg call allocation avoided, single-lookup `resolve`
- [x] Interp: script-class instantiation no longer builds a second instance + interpreter per inheritance level
- [x] `-D PERFCOUNT` counters in `Parser` for allocation-level profiling
- [x] `bench/` harness with a representative corpus, best-of-rounds timing and A/B comparison (see `bench/README.md`)
- [ ] Bytecode cache: `hscript.Bytes` round-trips all supported syntax, but is not wired into any loader path

## Language / Haxe syntax

- [x] Imports, import aliases (`import Foo as Bar`), packages, wildcard imports (`import haxe.ds.*;`)
- [x] `using` keyword (registered using-entries and macro-level `IrisUsingClass`)
- [x] `final` constants
- [x] Enums (including constructors with arguments) and typedefs (incl. redirects)
- [x] Null coalescing `??` / `??=` and null-safe access `?.` / `?.()`
- [x] String interpolation `"$var"`, `"${expr}"`, `"$$"` escape
- [x] `cast` (checked `cast (x, T)` and unchecked `cast x`) and `untyped`
- [x] Generic constructor type parameters (`new Array<Int>()`) and generic function type parameters (`function f<T>(x:T)`)
- [x] Object shorthand (`{x}`)
- [ ] Object spread (`{...a, b: 1}`)
- [x] Destructuring declarations: `var [a, b] = arr;`, `var {x, y} = obj;`
- [x] Destructuring extensions: rest (`[a, ...rest]`), rename (`{x: y}`), defaults (`{x = 1}`), nesting, in `for (... in ...)`,
      and the assignment form (`[a, b] = f();`, `{x} = obj;`)
- [x] Spread calls (`f(...arr)`) and rest arguments (`function f(a, ...rest)`)
- [x] Array comprehensions and key-value map comprehensions (`[for (k => v in m) k => v]`)
- [x] Switch: comma-separated values, `|` or-patterns, variable binding (`case v:`), guards (`case v if (v > 3):`),
      guarded wildcard (`case _ if (cond):`)
- [x] Key-value for loops (`for (k => v in map)`)
- [x] Static members via the class name (`M.f()`, `S.x = 9`)
- [x] Access modifiers (public/private/static/override/dynamic/inline — parsed and honoured for static/public)
- [x] Untyped `catch (e)`
- [x] Empty statement (`;`)

## Script classes

- [x] Script classes (`class Foo { ... }`) and `new` with constructor arguments
- [x] Script-to-script inheritance with `super.method()` and `super.new()` binding to the child instance
- [x] `class Foo extends EngineClass` via the CUSTOM_CLASSES `_HSX` shadow classes
- [x] Shared `static` variables, `publicVariables`, `scriptObject`

## Runtime / host integration

- [x] `errorHandler`, `importFailedCallback`, `importBlocklist` (global + per-`IrisConfig`), `importRedirects`
- [x] `getRedirects` / `setRedirects`, `@:bypassAccessor`
- [x] Runtime preprocessor (`#if` / `#elseif` / `#else` / `#end`, `!` / `&&` / `||`, nesting)
- [x] `Math`, `Std` and `Map` resolve from scripts
- [x] `hscript.Bytes` compiled-script cache (versioned format; round-trips the supported syntax)
- [x] `hscript.Async` type-checks and transforms (was dead code before 1.3.0)
- [x] Haxe 4.2.5 through 4.3.7, verified in CI

## Macro hygiene

- [x] `ClassExtendMacro` skips `@:deprecated` members, so shadow classes no longer emit `WDeprecated` warnings
      that point into the macro file itself

---

## TODO

- [ ] Object spread `{...a, b: 1}` (not Haxe syntax - a deliberate superset extension)
- [ ] Array literal spread `[...a, 2]` (not Haxe syntax)
- [ ] Multiple typed `catch` clauses (Haxe parity gap; a single typed or untyped catch works)
- [ ] Class type parameters `class Box<T>` (Haxe parity gap; generic *functions* and `new X<T>()` work)
- [ ] `interface` declarations and `implements` clauses (Haxe parity gap)
- [ ] `abstract` declarations and `enum abstract` (Haxe parity gap)
- [ ] Switch array/object patterns `case [a, b]:` / `case {x: v}:` (Haxe parity gap)
- [ ] Sandboxing
- [ ] Wire `hscript.Bytes` into a loader path so the cache actually saves parse time at runtime
- [ ] `hscript.Checker` static analysis
