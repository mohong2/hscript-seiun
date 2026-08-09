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
  runtime under the `crowplexus.hscript` / `crowplexus.iris` packages.
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
		class CoolUtil implements crowplexus.iris.IrisUsingClass {}
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
