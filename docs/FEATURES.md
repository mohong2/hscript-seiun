# FEATURES

- For loop optimizations
- Generic memory optimizations

- [x] Imports (i.e: `import ClassPackageAndName;`, Added in 1.0.0)
- [x] Import Aliases (Added in 1.1.0 i.e: `import ClassPackageAndName as Class Alias;`)

- [x] Finals (Added in 1.0.1)

- [x] Improved Error Handling (Added in 1.1.0)
- [x] Using Keyword (Added in 1.1.1)

- [x] Enums (Added in 1.1.0)
- - [ ] Abstract Enums

- [x] Typedefs (Added in 1.1.0)
- - [x] Redirects (Added in 1.1.0)
- - [x] Class Redirect (automatic imports, Added in 1.1.0)

- [x] Null Coalescing Operator (Added in 1.1.0, ??, ??=)

- [x] Packages (Added in 1.1.1)

- [x] Classes (hscript-seiun: hscript-improved `_HSX` shadow classes + hscript-plus
  script-to-script inheritance via `super` chains)
- [x] Access modifiers (public/private/static/override/dynamic/inline — parsed and honored for static/public)
- [x] Key-Value for loops (`for (k => v in map)`)
- [x] scriptObject / errorHandler / importFailedCallback / importBlocklist / importRedirects
- [x] staticVariables / publicVariables (+ allow* flags)
- [x] getRedirects / setRedirects / @:bypassAccessor
- [x] Runtime preprocessor (`#if` / `#elseif` / `#else` / `#end`, `!` / `&&` / `||`,
  nested blocks and `elseif` chains — see the README for details)
- [x] String interpolation (`"$var"`, `"${expr}"`, `"$$"` escape)
- [x] `cast` (checked `cast (x, T)` + unchecked `cast x`)
- [x] Generic constructor type parameters (`new Array<Int>()`, nested generics)
- [x] Object shorthand (`{x}`), destructuring declarations (`var [a,b] = arr;`)
- [x] Spread calls (`f(...arr)`) and rest args (`function f(a, ...rest)`)
- [x] Static members via the class name (`M.f()`, `S.x = 9`)
- [x] Switch guards with variable binding (`case v if (v > 3):`)

---

## TODO:

- [ ] Regex?
- [ ] Sandboxing
- [ ] Abstract Enums

---
