/*
 * hscript-seiun functional test-suite (MIT).
 * See LICENSE and NOTICE for details.
 *
 * T3 (macros/legacy) suite:
 *   GOAL A - ClassExtendMacro @:deprecated handling (runtime side; the
 *            compile-time side is the test/DeprecationProbe.hx build check).
 *   GOAL B - Printer round-trip: parse -> exprToString -> re-parse -> same result.
 *   GOAL C - iris hygiene (config, blocklist, error/log routing).
 *
 * Standalone:
 *   haxe -cp . -cp test -D hscriptPos -D CUSTOM_CLASSES --macro "hscript.macros.UsingHandler.init()" --macro "hscript.macros.ClassExtendMacro.init()" -main TestMacrosLegacy --interp
 */
package;

import hscript.Expr;
import hscript.Interp;
import hscript.Parser;
import hscript.Printer;
import hscript.Tools;
import hscript.iris.Iris;
import hscript.iris.IrisConfig;

class TestMacrosLegacy {
	static var DOLLAR = String.fromCharCode(36);

	public static function run(h:TestHarness):Void {
		testDeprecatedShadowClass(h);
		testPrinterRoundTrip(h);
		testPrinterSwitchShapes(h);
		testPrinterStringEscapes(h);
		testWildcardImportPrinter(h);
		testPrinterNewSyntax(h);
		testIrisHygiene(h);
	}

	static function main() {
		var h = new TestHarness();
		run(h);
		trace('TestMacrosLegacy: ' + h.summary() + (h.failed > 0 ? ' -> ' + h.failures.join(' | ') : ''));
		if (h.failed > 0)
			Sys.exit(1);
	}

	// ───────────────────────── helpers ─────────────────────────

	static function mkParser():Parser {
		var p = new Parser();
		p.allowTypes = true;
		p.allowJSON = true;
		p.allowMetadata = true;
		return p;
	}

	static function oneLine(s:String):String {
		return StringTools.replace(StringTools.replace(s, "\r", " "), "\n", " ");
	}

	/** parse -> print -> parse -> execute both; compare the listed variables. */
	static function rtExec(h:TestHarness, name:String, code:String, vars:Array<String>):Void {
		var printed = "";
		try {
			var ast1 = mkParser().parseString(code, "rt1.hx");
			printed = Printer.toString(ast1);
			var ast2 = mkParser().parseString(printed, "rt2.hx");
			var i1 = new Interp();
			i1.execute(ast1);
			var i2 = new Interp();
			i2.execute(ast2);
			var same = true;
			var before:Array<String> = [];
			var after:Array<String> = [];
			for (v in vars) {
				var a = Std.string(i1.variables.get(v));
				var b = Std.string(i2.variables.get(v));
				before.push(a);
				after.push(b);
				if (a != b)
					same = false;
			}
			h.check(same, 'printer roundtrip: $name | ' + oneLine(printed) + ' | before=' + before.join(",") + ' after=' + after.join(","));
		} catch (e:Dynamic) {
			h.crashed('printer roundtrip: $name | printed=' + oneLine(printed), e);
		}
	}

	/** print -> parse -> print must be idempotent (catches paren growth / dropped nodes). */
	static function rtText(h:TestHarness, name:String, code:String):String {
		try {
			var p1 = Printer.toString(mkParser().parseString(code, "rt1.hx"));
			var p2 = Printer.toString(mkParser().parseString(p1, "rt2.hx"));
			h.check(p1 == p2, 'printer stable: $name | 1=' + oneLine(p1) + ' | 2=' + oneLine(p2));
			return p1;
		} catch (e:Dynamic) {
			h.crashed('printer stable: $name', e);
			return "";
		}
	}

	static function runSnippet(h:TestHarness, name:String, code:String, varName:String, want:Dynamic):Void {
		try {
			var i = new Interp();
			i.execute(mkParser().parseString(code, "probe.hx"));
			h.eq(i.variables.get(varName), want, name);
		} catch (e:Dynamic) {
			h.crashed(name, e);
		}
	}

	static function parsesOk(code:String):Bool {
		try {
			mkParser().parseString(code, "probe.hx");
			return true;
		} catch (e:Dynamic)
			return false;
	}

	static function snippetError(code:String):String {
		try {
			var i = new Interp();
			i.execute(mkParser().parseString(code, "probe.hx"));
			return "executed, r=" + Std.string(i.variables.get("r"));
		} catch (e:Dynamic)
			return Std.string(e);
	}

	static function trySnippet(code:String, varName:String, want:Dynamic):Bool {
		try {
			var i = new Interp();
			i.execute(mkParser().parseString(code, "probe.hx"));
			return i.variables.get(varName) == want;
		} catch (e:Dynamic) {
			return false;
		}
	}

	// ───────────────────── GOAL A: deprecated members ─────────────────────

	static function testDeprecatedShadowClass(h:TestHarness):Void {
		#if CUSTOM_CLASSES
		// Typing the plain classes also types their macro-generated _HSX shadows.
		var base:Class<script.TestDeprecatedBase> = script.TestDeprecatedBase;
		var sub:Class<script.TestDeprecatedSub> = script.TestDeprecatedSub;
		var leaf:Class<script.TestDeprecatedLeaf> = script.TestDeprecatedLeaf;
		h.check(base != null && sub != null && leaf != null, "macro-class: deprecated probe classes are compiled");

		// Non-deprecated members must still be routed through the interpreter.
		var i = new Interp();
		i.execute(mkParser().parseString('
			class DepThing extends script.TestDeprecatedBase {
				public function new() {}
				public function freshMethod():Int return 99;
			}
			var t = new DepThing();
			var fresh = t.freshMethod();
			var old = t.oldMethod();
			var bare = t.bareOld();
			class DepLeafThing extends script.TestDeprecatedLeaf {
				public function new() {}
				public function freshMethod():Int return 77;
			}
			var l = new DepLeafThing();
			var lold = l.oldMethod();
			var lfresh = l.freshMethod();
		', "dep.hx"));
		h.eq(i.variables.get("fresh"), 99, "macro-class: non-deprecated member still routed to script override");
		// Documented consequence of the WDeprecated fix: a @:deprecated member is
		// no longer overridden by the shadow class, so the script override is not
		// routed and the base implementation runs.
		h.eq(i.variables.get("old"), 1, "macro-class: deprecated member falls back to the base implementation");
		h.eq(i.variables.get("bare"), 9, "macro-class: bare @:deprecated member falls back to base");
		h.eq(i.variables.get("lold"), 420, "macro-class: inherited deprecated member (2 levels) falls back to base");
		h.eq(i.variables.get("lfresh"), 77, "macro-class: leaf non-deprecated member still routed");
		#else
		trace('SKIP: testDeprecatedShadowClass (need -D CUSTOM_CLASSES)');
		#end
	}

	// ───────────────────── GOAL B: Printer round-trip ─────────────────────

	static function testPrinterRoundTrip(h:TestHarness):Void {
		rtExec(h, "arith/binops", 'var a = 1 + 2 * 3; var b = (1 + 2) * 3; var c = 17 % 5; var d = 2 << 3; var e = 5 & 3;', ["a", "b", "c", "d", "e"]);
		rtExec(h, "unops", 'var a = -5; var b = !false; var c = ~1;', ["a", "b", "c"]);
		rtExec(h, "if/else", 'var x = 3; var r = ""; if (x > 2) r = "big" else r = "small";', ["r"]);
		rtExec(h, "while", 'var i = 0; var s = 0; while (i < 4) { s += i; i++; }', ["i", "s"]);
		rtExec(h, "do-while", 'var i = 0; do { i++; } while (i < 3);', ["i"]);
		rtExec(h, "for-range", 'var s = 0; for (i in 0...5) s += i;', ["s"]);
		rtExec(h, "for-keyvalue", 'var m = ["a" => 1, "b" => 2]; var s = 0; for (k => v in m) s += v;', ["s"]);
		rtExec(h, "break/continue", 'var s = 0; for (i in 0...10) { if (i == 3) continue; if (i == 6) break; s += i; }', ["s"]);
		rtExec(h, "objects/arrays", 'var o = {a: 1, b: "x"}; var arr = [1, 2, 3]; var r = o.a; var q = arr[1];', ["r", "q"]);
		rtExec(h, "functions", 'function add(a, b) return a + b; var r = add(2, 3); var f = function(x) return x * 2; var y = f(4);', ["r", "y"]);
		rtExec(h, "closures", 'var n = 0; var inc = function() { n += 1; return n; }; var a = inc(); var b = inc();', ["a", "b"]);
		rtExec(h, "ternary", 'var t = 1 > 0 ? "yes" : "no";', ["t"]);
		rtExec(h, "try/catch", 'var r = ""; try { throw "boom"; } catch (e:Dynamic) r = "caught:" + e;', ["r"]);
		rtExec(h, "class/new/method", 'class Foo { public var x:Int = 3; public function new() {} public function get():Int return x; } var f = new Foo(); var r = f.get(); var v = f.x;', ["r", "v"]);
		rtExec(h, "enum/switch", 'enum Color { Red; Green; Blue; } var c = Color.Green; var r = switch(c) { case Color.Red: 1; case Color.Green: 2; case Color.Blue: 3; };', ["r"]);
		rtExec(h, "var modifiers", 'public var a = 1; static var b = 2; final c = 3; var r = a + b + c;', ["r"]);
		rtExec(h, "null-safe access", 'var o = null; var r = o?.f();', ["r"]);
		rtExec(h, "cast", 'var x = "42"; var y = cast(x, String); var z = cast x;', ["y", "z"]);
		rtExec(h, "checkType", 'var x = (1 : Int); var r = x + 1;', ["r"]);
		rtExec(h, "untyped", 'var r = untyped (1 + 2);', ["r"]);
		rtExec(h, "spread call", 'function f(a, b) return a + b; var arr = [1, 2]; var r = f(...arr);', ["r"]);
		rtExec(h, "rest args", 'function f(a, ...rest) return a + rest.length; var r = f(1, 2, 3);', ["r"]);
		rtExec(h, "array comprehension", 'var r = [for (i in 0...4) i * 2].length;', ["r"]);
		rtExec(h, "metadata", '@foo(1, 2) var x = 3; var r = x;', ["r"]);
		rtExec(h, "destructure array", 'var arr = [1, 2]; var [a, b] = arr; var c = a + b;', ["c"]);
		rtExec(h, "destructure object", 'var obj = {x: 1, y: 2}; var {x, y} = obj; var c = x + y;', ["c"]);
		rtExec(h, "nested block", 'var r = 0; { var a = 1; { var b = 2; r = a + b; } }', ["r"]);
		rtExec(h, "string concat", 'var x = 42; var s = "v=" + x;', ["s"]);
		rtExec(h, "new generic", 'var a = new Array<Int>(); a.push(1); var r = a.length;', ["r"]);

		// import / using are declarations: check printed text is stable and re-parses.
		rtExec(h, "typedef class redirect", 'typedef MyMath = Math; var v = MyMath;', ["v"]);
		rtExec(h, "enum with args", 'enum E { A; B(v:Int); } var x = E.A; var y = E.B(3);', ["x", "y"]);
		rtExec(h, "class extends", 'class A { public function f() return 1; } class B extends A { public function g() return 2; } var b = new B(); var r = b.f() + b.g();', ["r"]);
		rtExec(h, "named function expression", 'var f = function foo(x) return x; var r = f(1);', ["r"]);
		rtExec(h, "empty object", 'var o = {}; var r = o == null;', ["r"]);
		// more shapes that exercise Printer reconstruction rules
		rtExec(h, "float literal", 'var a = 3.0; var b = a / 2; var c = 1.5;', ["a", "b", "c"]);
		rtExec(h, "postfix/prefix inc", 'var i = 1; var a = i++; var b = i; var c = ++i; var d = i--;', ["a", "b", "c", "d"]);
		rtExec(h, "logical/compare ops", 'var a = 1 < 2 && 3 >= 3; var b = false || true; var c = 1 != 2; var d = null ?? 7;', ["a", "b", "c", "d"]);
		rtExec(h, "nested field/array", 'var o = {a: {b: [10, 20]}}; var r = o.a.b[1];', ["r"]);
		rtExec(h, "call chain", 'function f(x) return function(y) return x + y; var r = f(1)(2);', ["r"]);
		rtExec(h, "if expression", 'var x = if (true) 1 else 2; var y = if (false) 3 else 4;', ["x", "y"]);
		rtExec(h, "switch no default", 'var x = 2; var r = 0; switch(x) { case 1: r = 10; case 2: r = 20; }', ["r"]);
		rtExec(h, "switch multi statement", 'var x = 1; var r = ""; switch(x) { case 1: r += "a"; r += "b"; default: r = "z"; }', ["r"]);
		rtExec(h, "typed function args", 'function f(a:Int, b:Float):Float return a + b; var r = f(1, 2.5);', ["r"]);
		rtExec(h, "typed var", 'var x:Int = 41; var r = x + 1;', ["r"]);
		rtExec(h, "nested ternary", 'var x = 1; var r = x == 1 ? "one" : x == 2 ? "two" : "many";', ["r"]);
		rtExec(h, "throw/catch typed", 'var r = ""; try { throw 42; } catch (e:Int) r = "int:" + e;', ["r"]);
		rtExec(h, "for over map keys", 'var m = ["a" => 1, "b" => 2]; var n = 0; for (k in m.keys()) n++;', ["n"]);
		rtExec(h, "array of objects", 'var a = [{x: 1}, {x: 2}]; var r = a[0].x + a[1].x;', ["r"]);
		rtExec(h, "string interpolation", 'var x = 5; var s = "v=' + DOLLAR + 'x";', ["s"]);
		rtExec(h, "spread middle arg", 'function f(a, b, c) return a + b + c; var arr = [2, 3]; var r = f(1, ...arr);', ["r"]);
		rtText(h, "import", 'import haxe.ds.StringMap; var x = 1;');
		rtText(h, "import alias", 'import haxe.ds.StringMap as SM; var x = 1;');
		rtText(h, "using", 'using StringTools; var x = 1;');
	}

	static function testPrinterSwitchShapes(h:TestHarness):Void {
		// guard must not be dropped
		var ast = mkParser().parseString('var x = 5; var r = switch(x) { case v if (v > 3): "big"; default: "small"; };', "guard.hx");
		var printed = Printer.toString(ast);
		h.check(printed.indexOf("if (v > 3)") >= 0, "printer: switch guard is printed (got " + oneLine(printed) + ")");
		rtExec(h, "switch guard", 'var x = 5; var r = switch(x) { case v if (v > 3): "big"; default: "small"; };', ["r"]);
		rtExec(h, "switch guard false", 'var x = 1; var r = switch(x) { case v if (v > 3): "big"; default: "small"; };', ["r"]);

		// several case values must print as an or-pattern
		var ast2 = mkParser().parseString('var r = switch(4) { case 1, 4: "or"; default: "no"; };', "orpat.hx");
		var printed2 = Printer.toString(ast2);
		h.check(printed2.indexOf("case 1 | 4") >= 0, "printer: multi-value case prints as or-pattern (got " + oneLine(printed2) + ")");

		// parenthesised bitwise OR stays a single case value
		rtExec(h, "case (1|3) bitwise", 'var x = 3; var r = switch(x) { case (1 | 3): "or3"; default: "none"; };', ["r"]);
		// The Lead's or-pattern ambiguity probe: 1|2 == 3, so with parentheses the case
		// matches; without them a post-T1 parser would see two alternatives and miss.
		rtExec(h, "case (1|2) matches 3", 'var r = switch (3) { case (1 | 2): "a"; default: "b"; };', ["r"]);
		// parser-dev trap: `case (1|2):` is ONE value whose top node is EParent(EBinop);
		// the Printer must keep it parenthesised and must not split it into alternatives.
		var astBit = mkParser().parseString('var r = switch (3) { case (1 | 2): "a"; default: "b"; };', "bitwise.hx");
		var printedBit = Printer.toString(astBit);
		h.check(printedBit.indexOf("case (1 | 2)") >= 0, "printer: parenthesised bitwise OR case stays one value (got " + oneLine(printedBit) + ")");
		// bare OR in the AST (what the pre-T1 parser produced): the printer must add
		// parentheses so the printed form means the same thing on either parser.
		rtExec(h, "case bare 1|2 roundtrip", 'var r = switch (3) { case 1 | 2: "a"; default: "b"; };', ["r"]);
	}

	static function testPrinterStringEscapes(h:TestHarness):Void {
		// quote / tab / newline
		rtExec(h, "string quote/tab/nl", 'var s = "a\\"b\tc\nd";', ["s"]);
		// literal backslash: hscript source needs a doubled backslash
		rtExec(h, "string backslash", 'var s = "back\\\\slash";', ["s"]);
		// literal dollar: hscript source needs a doubled dollar
		rtExec(h, "string dollar", 'var s = "cost: ' + DOLLAR + DOLLAR + DOLLAR + DOLLAR + '5";', ["s"]);
		// print must escape backslash and dollar so the value survives twice
		rtText(h, "string escapes stable", 'var s = "a\\"b\\\\c";');
	}

	// ───────────── Lead-fixed wildcard-import interface (EImport("pkg.*", null)) ─────────────

	/**
	 * Printer contract for `import haxe.ds.*;`: the parser encodes the wildcard
	 * as a trailing ".*" in EImport's `v` and the Printer must print it verbatim.
	 * Checked directly on a hand-built node so it does not depend on parser-dev.
	 */
	static function testWildcardImportPrinter(h:TestHarness):Void {
		#if hscriptPos
		try {
			var node:hscript.Expr = {e: EImport("haxe.ds.*", null), pmin: 0, pmax: 0, origin: "w.hx", line: 1};
			var printed = Printer.toString(node);
			h.check(printed == "import haxe.ds.*", "printer: EImport wildcard prints verbatim (got " + printed + ")");
		} catch (e:Dynamic)
			h.crashed("printer: EImport wildcard", e);
		#end
		// statement-level stability; becomes a real star-preservation check once the
		// parser emits the trailing ".*" (asserted in testPrinterNewSyntax below)
		rtText(h, "wildcard import statement", 'import haxe.ds.*; var r = 1;');
	}

	// ───────────── GOAL B/GOAL B-contract: parser-dev T1/T2 syntax ─────────────

	static function testPrinterNewSyntax(h:TestHarness):Void {
		// or-patterns (parser-dev T1)
		if (trySnippet('var r = switch(4) { case 1 | 4: "or"; default: "no"; };', "r", "or")) {
			rtExec(h, "or-pattern", 'var r = switch(4) { case 1 | 4: "or"; default: "no"; };', ["r"]);
			rtExec(h, "or-pattern three", 'var r = switch(7) { case 1 | 4 | 7: "hit"; default: "no"; };', ["r"]);
			rtExec(h, "or-pattern with guard", 'var x = 4; var r = switch(x) { case 1 | 4 if (x > 2): "guarded"; default: "no"; };', ["r"]);
		} else {
			trace('SKIP: or-pattern round-trip (parser-dev T1 not landed yet)');
		}

		// guarded wildcard (parser-dev T1 + interp-dev T2)
		if (trySnippet('var x = 5; var r = switch(x) { case _ if (x > 3): "guarded"; default: "none"; };', "r", "guarded")) {
			rtExec(h, "guarded wildcard", 'var x = 5; var r = switch(x) { case _ if (x > 3): "guarded"; default: "none"; };', ["r"]);
			// unguarded wildcard stays the default
			rtExec(h, "unguarded wildcard", 'var x = 5; var r = switch(x) { case _: "default"; };', ["r"]);
		} else {
			trace('SKIP: guarded wildcard round-trip (T1/T2 not landed yet)');
		}

		// generic functions
		if (trySnippet('function id<T>(x:T):T return x; var r = id(3);', "r", 3)) {
			rtExec(h, "generic function", 'function id<T>(x:T):T return x; var r = id(3);', ["r"]);
			rtExec(h, "generic function two params", 'function pair<T, U>(a:T, b:U) return a; var r = pair(1, "x");', ["r"]);
		} else {
			trace('SKIP: generic function round-trip (parser-dev T1 not landed yet)');
		}

		// destructuring extensions
		if (trySnippet('var arr = [1, 2, 3]; var [a, ...rest] = arr; var n = rest.length;', "n", 2))
			rtExec(h, "destructure rest", 'var arr = [1, 2, 3]; var [a, ...rest] = arr; var n = rest.length; var f = a + rest[0];', ["n", "f"]);
		else
			trace('SKIP: destructure rest (parser-dev T1 not landed yet)');

		if (trySnippet('var o = {x: 5}; var {x: y} = o; var r = y;', "r", 5))
			rtExec(h, "destructure rename", 'var o = {x: 5}; var {x: y} = o; var r = y;', ["r"]);
		else
			trace('SKIP: destructure rename (parser-dev T1 not landed yet)');

		if (trySnippet('var o = {}; var {x = 7} = o; var r = x;', "r", 7))
			rtExec(h, "destructure default", 'var o = {}; var {x = 7} = o; var r = x;', ["r"]);
		else
			trace('SKIP: destructure default (parser-dev T1 not landed yet)');

		if (trySnippet('var o = {a: [1, 2]}; var {a: [b, c]} = o; var r = b + c;', "r", 3))
			rtExec(h, "destructure nested", 'var o = {a: [1, 2]}; var {a: [b, c]} = o; var r = b + c;', ["r"]);
		else
			trace('SKIP: destructure nested (parser-dev T1 not landed yet)');

		if (trySnippet('var s = 0; for ([a, b] in [[1, 2], [3, 4]]) s += a + b;', "s", 10))
			rtExec(h, "for destructure", 'var s = 0; for ([a, b] in [[1, 2], [3, 4]]) s += a + b;', ["s"]);
		else
			trace('SKIP: for destructure (parser-dev T1 not landed yet)');

		if (trySnippet('var a = 0; var b = 0; [a, b] = [4, 5]; var r = a + b;', "r", 9))
			rtExec(h, "assign destructure", 'var a = 0; var b = 0; [a, b] = [4, 5]; var r = a + b;', ["r"]);
		else
			trace('SKIP: assign destructure (parser-dev T1 not landed yet)');

		// [for (k => v in m) k => v] desugars to a Map; there is no .length on a Map.
		var mapCode = 'var m = ["a" => 1]; var a = [for (k => v in m) k => v]; var r = a.get("a");';
		if (parsesOk(mapCode)) {
			// Printer coverage does not need runtime Map support
			rtText(h, "map comprehension", mapCode);
			if (trySnippet(mapCode, "r", 1))
				rtExec(h, "map comprehension exec", mapCode, ["r"]);
			else
				trace('SKIP: map comprehension execution -> ' + snippetError(mapCode));
		} else
			trace('SKIP: map comprehension parse (parser-dev T1 not landed yet)');

		// single-variable map comprehension form: [for (i in 0...2) i => i * 10] -> {0=>0, 1=>10}
		var map1 = 'var a = [for (i in 0...2) i => i * 10]; var r = a.get(1);';
		rtText(h, "map comprehension single var", map1);
		if (trySnippet(map1, "r", 10))
			rtExec(h, "map comprehension single var exec", map1, ["r"]);
		else
			trace('SKIP: single-var map comprehension -> ' + snippetError(map1));

		// wildcard import
		var wild = wildcardImportSupported();
		if (wild) {
			var printed = rtText(h, "wildcard import", 'import haxe.ds.*; var r = 1;');
			h.check(printed.indexOf("*") >= 0, "printer: wildcard import keeps the star (got " + oneLine(printed) + ")");
		} else {
			trace('SKIP: wildcard import round-trip (parser-dev T1 not landed yet)');
		}
	}

	static function wildcardImportSupported():Bool {
		try {
			var ast = mkParser().parseString('import haxe.ds.*; var r = 1;', "wild.hx");
			var v:String = null;
			var as:String = null;
			switch (Tools.expr(ast)) {
				case EBlock(el):
					for (e in el)
						switch (Tools.expr(e)) {
							case EImport(p, a):
								v = p;
								as = a;
							default:
						}
				default:
			}
			if (v != null && v.indexOf("*") >= 0) return true;
			if (as != null && as.indexOf("*") >= 0) return true;
			return Printer.toString(ast).indexOf("*") >= 0;
		} catch (e:Dynamic)
			return false;
	}

	// ───────────────────── GOAL C: iris hygiene ─────────────────────

	static function testIrisHygiene(h:TestHarness):Void {
		// basic lifecycle
		var iris = new Iris('var x = 1; function twice(a) return a * 2;', new IrisConfig("T3Iris", true, true));
		h.eq(iris.get("x"), 1, "iris: get after autoRun");
		h.check(iris.exists("x"), "iris: exists");
		var call = iris.call("twice", [3]);
		h.check(call != null && call.returnValue == 6, "iris: call returns value");
		iris.set("y", 5, false);
		h.eq(iris.get("y"), 5, "iris: set new value");
		iris.set("y", 9, false);
		h.eq(iris.get("y"), 5, "iris: set allowOverride=false keeps old value");
		iris.set("y", 9, true);
		h.eq(iris.get("y"), 9, "iris: set allowOverride=true overrides");
		iris.destroy();
		h.eq(iris.get("x"), false, "iris: get after destroy returns false");

		// config coercion (raw anon + IrisConfig)
		var raw:hscript.iris.IrisConfig.RawIrisConfig = {name: "Raw", autoRun: false, autoPreset: false, localBlocklist: ["haxe.ds.IntMap"]};
		var cfg = IrisConfig.from(raw);
		h.check(cfg != null && cfg.name == "Raw" && cfg.autoRun == false && cfg.localBlocklist.length == 1,
			"iris: IrisConfig.from(raw anon)");
		var cfg2 = IrisConfig.from(new IrisConfig("Cls", false, false));
		h.check(cfg2.name == "Cls" && cfg2.autoRun == false, "iris: IrisConfig.from(IrisConfig)");

		// global blocklist is enforced (control)
		Iris.blocklistImports.push("haxe.ds.IntMap");
		var globalBlocked = false;
		try {
			new Iris('import haxe.ds.IntMap;', new IrisConfig("T3BlockGlobal", true, false));
		} catch (e:Dynamic)
			globalBlocked = true;
		Iris.blocklistImports.remove("haxe.ds.IntMap");
		h.check(globalBlocked, "iris: global blocklist rejects a blocked import");

		// per-script localBlocklist must be enforced too
		var localBlocked = false;
		try {
			new Iris('import haxe.ds.IntMap;', new IrisConfig("T3BlockLocal", true, false, ["haxe.ds.IntMap"]));
		} catch (e:Dynamic)
			localBlocked = true;
		h.check(localBlocked, "iris: localBlocklist rejects a blocked import");

		// warning/error routing goes through Iris.logLevel
		var levels:Array<String> = [];
		var oldLogLevel = Iris.logLevel;
		Iris.logLevel = function(level, v, ?pos) levels.push(Std.string(level));
		new Iris('final x = 1; x = 2;', new IrisConfig("T3LogRoute", true, false));
		Iris.logLevel = oldLogLevel;
		h.check(levels.length > 0, "iris: warnings are routed through Iris.logLevel");

		// calling a missing function is reported through logLevel and returns null
		var callErrors:Array<String> = [];
		Iris.logLevel = function(level, v, ?pos) callErrors.push(Std.string(v));
		var irisErr = new Iris('var x = 1;', new IrisConfig("T3CallErr", true, false));
		var missing = irisErr.call("nope");
		Iris.logLevel = oldLogLevel;
		h.check(missing == null && callErrors.length > 0, "iris: call on a missing function reports through logLevel");

		// enum + typedef resolution through Iris
		var irisEnum = new Iris('enum Color { Red; Green; } var c = Color.Green;', new IrisConfig("T3Enum"));
		h.check(irisEnum.get("c") != null, "iris: enum constructor resolves");
		var irisTd = new Iris('typedef MyMath = Math; var v = MyMath;', new IrisConfig("T3Typedef"));
		h.eq(irisTd.get("v"), Math, "iris: typedef redirect resolves");

		// using registration + resolution
		var entry = Iris.registerUsingGlobal("T3Using", function(o:Dynamic, f:String, args:Array<Dynamic>):Dynamic {
			return f == "doubleIt" ? Std.string(o) + Std.string(o) : null;
		});
		var usingIris = new Iris('using T3Using; var doubled = "ab".doubleIt();', new IrisConfig("T3UsingScript"));
		h.eq(usingIris.get("doubled"), "abab", "iris: registered using entry resolves");

		Iris.destroyAll();
	}
}
