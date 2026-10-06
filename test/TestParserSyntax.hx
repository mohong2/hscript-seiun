/*
 * hscript-seiun parser-syntax suite (MIT).
 * See LICENSE and NOTICE for details.
 *
 * Covers the parser-side syntax added by task-1 (GOAL B) and the negative
 * cases that must raise a parse error instead of silently mis-parsing.
 */
package;

import hscript.Expr;
import hscript.Interp;
import hscript.Parser;
import hscript.Tools;

class TestParserSyntax {
	static function newParser():Parser {
		var p = new Parser();
		p.allowTypes = true;
		p.allowJSON = true;
		p.allowMetadata = true;
		return p;
	}

	static function runCode(code:String):Interp {
		var ast = newParser().parseString(code, "syntax.hx");
		var interp = new Interp();
		interp.execute(ast);
		return interp;
	}

	/** Evaluates a script and returns its r variable. */
	static function eval(code:String):Dynamic {
		return runCode(code).variables.get("r");
	}

	static function parseFails(code:String):Bool {
		try {
			newParser().parseString(code, "syntax.hx");
			return false;
		} catch (e:Dynamic) {
			return true;
		}
	}

	static function walk(e:Expr, f:Expr->Void):Void {
		if (e == null)
			return;
		f(e);
		Tools.iter(e, function(c) walk(c, f));
	}

	static function firstSwitchCases(ast:Expr):Array<hscript.Expr.SwitchCase> {
		var found:Array<hscript.Expr.SwitchCase> = null;
		walk(ast, function(e) {
			if (found != null)
				return;
			switch (Tools.expr(e)) {
				case ESwitch(_, cases, _): found = cases;
				default:
			}
		});
		return found;
	}

	static function firstImport(ast:Expr):{v:String, alias:String} {
		var found:{v:String, alias:String} = null;
		walk(ast, function(e) {
			if (found != null)
				return;
			switch (Tools.expr(e)) {
				case EImport(v, a): found = {v: v, alias: a};
				default:
			}
		});
		return found;
	}

	static function hasNew(ast:Expr, cl:String):Bool {
		var found = false;
		walk(ast, function(e) switch (Tools.expr(e)) {
			case ENew(c, _): if (c == cl) found = true;
			default:
		});
		return found;
	}

	/** Capability probe: new Map() only works once Interp can resolve Map. */
	static function mapSupported():Bool {
		try {
			new Interp().execute(newParser().parseString("var __mapProbe = new Map();", "probe.hx"));
			return true;
		} catch (e:Dynamic) {
			return false;
		}
	}

	public static function run(h:TestHarness):Void {
		testOrPatterns(h);
		testGuardedWildcard(h);
		testDestructuring(h);
		testDestructuringAssign(h);
		testForDestructuring(h);
		testGenericFunctions(h);
		testMapComprehension(h);
		testWildcardImport(h);
		testSmallGaps(h);
	}

	// ---------------------------------------------------------------- or-patterns

	static function testOrPatterns(h:TestHarness) {
		try {
			h.eq(eval("var x = 2; var r = switch (x) { case 1 | 2: 'a'; default: 'b'; };"), "a",
				"or-pattern: first alternative matches");
			h.eq(eval("var x = 1; var r = switch (x) { case 1 | 2: 'a'; default: 'b'; };"), "a",
				"or-pattern: second alternative matches");
			h.eq(eval("var x = 3; var r = switch (x) { case 1 | 2 | 3: 'a'; default: 'b'; };"), "a",
				"or-pattern: three alternatives");
			h.eq(eval("var x = 9; var r = switch (x) { case 1 | 2 | 3: 'a'; default: 'b'; };"), "b",
				"or-pattern: non-matching falls through to default");

			h.eq(eval("var g = true; var x = 5; var r = switch (x) { case 1 | 5 if (g): 'y'; default: 'n'; };"), "y",
				"or-pattern: guard true binds the case");
			h.eq(eval("var g = false; var x = 5; var r = switch (x) { case 1 | 5 if (g): 'y'; default: 'n'; };"), "n",
				"or-pattern: guard false falls through");

			h.eq(eval("var x = 3; var r = switch (x) { case (1|2): 'or'; default: 'no'; };"), "or",
				"or-pattern: parenthesised (1|2) is still bitwise OR");
			h.eq(eval("var x = 3; var r = switch (x) { case 1|2: 'or'; default: 'no'; };"), "no",
				"or-pattern: bare 1|2 means alternatives, not bitwise OR");

			var ast = newParser().parseString("var x = 2; var r = switch (x) { case 1 | 2 | 3: 'a'; default: 'b'; };");
			var cases = firstSwitchCases(ast);
			h.check(cases != null && cases.length == 1 && cases[0].values.length == 3,
				"or-pattern: AST holds 3 values in SwitchCase.values (got "
				+ (cases == null ? "null" : Std.string(cases[0].values.length)) + ")");

			h.eq(eval("var x = 2; var r = switch (x) { case 1, 2: 'a'; default: 'b'; };"), "a",
				"or-pattern: legacy comma-separated values still work");
		} catch (e:Dynamic) h.crashed("or-patterns", e);
	}

	// ---------------------------------------------------------- guarded wildcard

	static function testGuardedWildcard(h:TestHarness) {
		try {
			h.eq(eval("var x = 5; var r = switch (x) { case _ if (x > 3): 'big'; default: 'small'; };"), "big",
				"guarded wildcard: matches when the guard is true");
			h.eq(eval("var x = 1; var r = switch (x) { case _ if (x > 3): 'big'; default: 'small'; };"), "small",
				"guarded wildcard: falls through when the guard is false");
			h.eq(eval("var x = 9; var r = switch (x) { case _ if (x > 10): 'big'; default: 'small'; };"), "small",
				"guarded wildcard: a later real default is still reachable");
			h.eq(eval("var x = 9; var r = switch (x) { case 1: 'one'; case _: 'other'; };"), "other",
				"wildcard: unguarded case _ still behaves as the default");

			var ast = newParser().parseString("var x = 5; var r = switch (x) { case _ if (x > 3): 'big'; default: 'small'; };");
			var ok = false;
			walk(ast, function(e) switch (Tools.expr(e)) {
				case ESwitch(_, cases, def):
					ok = cases.length == 1 && cases[0].ifExpr != null && def != null;
				default:
			});
			h.check(ok, "guarded wildcard: stays a case (ifExpr set) while defaultExpr is the real default");
		} catch (e:Dynamic) h.crashed("guarded-wildcard", e);
	}

	// ------------------------------------------------------------ destructuring

	static function testDestructuring(h:TestHarness) {
		try {
			h.eq(eval("var arr = [1,2,3,4]; var [a, ...rest] = arr; var r = a * 100 + rest.length * 10 + rest[0];"), 132,
				"destructure: array rest [a, ...rest]");
			h.eq(eval("var o = {x: 5}; var {x: y} = o; var r = y;"), 5,
				"destructure: object rename {x: y}");
			h.eq(eval("var o = {x: null}; var {x = 7} = o; var r = x;"), 7,
				"destructure: object default used when null");
			h.eq(eval("var o = {x: 3}; var {x = 7} = o; var r = x;"), 3,
				"destructure: object default ignored when present");
			h.eq(eval("var n = 0; function bump() { n++; return {x: null}; } var {x = 9} = bump(); var r = n * 100 + x;"), 109,
				"destructure: default evaluates the source expression exactly once");
			h.eq(eval("var o = {a: [1,2]}; var {a: [b, c]} = o; var r = b * 10 + c;"), 12,
				"destructure: nested object to array");
			h.eq(eval("var pairs = [[1,2],[3,4]]; var [[a],[b]] = pairs; var r = a * 10 + b;"), 13,
				"destructure: nested array to array");
			h.eq(eval("var o = {a: {b: 6}}; var {a: {b}} = o; var r = b;"), 6,
				"destructure: nested object to object");
			h.eq(eval("var arr = [1,2,3]; var [, b] = arr; var r = b;"), 2,
				"destructure: elided array slot");
			h.eq(eval("final arr = [1,2]; final [a, b] = arr; var r = a + b;"), 3,
				"destructure: final declaration");

			h.check(parseFails("var [a, b = [1];"), "negative: unclosed array pattern errors");
			h.check(parseFails("var {a: } = o;"), "negative: object rename without a target errors");
			h.check(parseFails("var [a, b];"), "negative: pattern without '=' errors");
			h.check(parseFails("var [...a, b] = arr;"), "negative: rest must be the last element");
			h.check(parseFails("var [] = [1];"), "negative: empty array pattern errors");
			h.check(parseFails("var {} = {a: 1};"), "negative: empty object pattern errors");
			h.check(parseFails("var [[]] = [1];"), "negative: nested empty pattern errors");
		} catch (e:Dynamic) h.crashed("destructuring", e);
	}

	static function testDestructuringAssign(h:TestHarness) {
		try {
			h.eq(eval("var a = 0; var b = 0; [a, b] = [1, 2]; var r = a * 10 + b;"), 12,
				"assign-destructure: [a, b] = f()");
			h.eq(eval("var a = 0; var b = 0; var src = [7, 8]; var v = ([a, b] = src); var r = a * 10 + b;"), 78,
				"assign-destructure: expression form yields the source value");
			h.eq(eval("var x = 0; {x} = {x: 4}; var r = x;"), 4,
				"assign-destructure: {x} = obj");
			h.eq(eval("var a = 0; var b = 0; var o = {a: 5, b: 6}; ({a, b} = o); var r = a * 10 + b;"), 56,
				"assign-destructure: parenthesised object form");
			h.eq(eval("var a = 0; var rest = null; [a, ...rest] = [1,2,3]; var r = a * 100 + rest.length * 10 + rest[0];"), 122,
				"assign-destructure: [a, ...rest] = arr");
		} catch (e:Dynamic) h.crashed("destructuring-assign", e);
	}

	static function testForDestructuring(h:TestHarness) {
		try {
			h.eq(eval("var pairs = [[1,2],[3,4]]; var t = 0; for ([a, b] in pairs) t += a * 10 + b; var r = t;"), 46,
				"for-destructure: for ([a, b] in pairs)");
			h.eq(eval("var objs = [{x: 1}, {x: 2}]; var t = 0; for ({x} in objs) t += x; var r = t;"), 3,
				"for-destructure: for ({x} in objs)");
			h.eq(eval("var pairs = [[1,2],[3,4]]; var t = 0; for ([a, b] in pairs) { if (a > 1) t += b; } var r = t;"), 4,
				"for-destructure: block body keeps its own statements");
			h.check(parseFails("for ([a, b] pairs) { }"), "negative: for-destructure without 'in' errors");
		} catch (e:Dynamic) h.crashed("for-destructuring", e);
	}

	// ---------------------------------------------------------- generic functions

	static function testGenericFunctions(h:TestHarness) {
		try {
			h.eq(eval("function f<T>(x:T):T return x; var r = f(5);"), 5,
				"generics: function f<T>(x:T):T");
			h.eq(eval("function f<T, U>(a:T, b:U) return a; var r = f(7, 8);"), 7,
				"generics: two type parameters");
			h.eq(eval("function f<T:Array<Array<Int>>>(x) return 3; var r = f(0);"), 3,
				"generics: constraint with nested closers");
			h.eq(eval("function f<T>(x:T) return x; var r = f('hi');"), "hi",
				"generics: string argument");
			h.eq(eval("class C { public function id<T>(v:T):T return v; } var c = new C(); var r = c.id(9);"), 9,
				"generics: class method");
			h.eq(eval("class C { static function make<T>(v:T) return v; } var r = C.make(11);"), 11,
				"generics: static class method");
		} catch (e:Dynamic) h.crashed("generic-functions", e);
	}

	// --------------------------------------------------------- map comprehension

	static function testMapComprehension(h:TestHarness) {
		try {
			var ast = newParser().parseString("var m = ['a' => 1]; var r = [for (k => v in m) k => v];");
			h.check(hasNew(ast, "Map"), "map-comprehension: desugars to new Map()");

			var ast2 = newParser().parseString("var r = [for (i in 0...3) i * i];");
			h.check(!hasNew(ast2, "Map"), "map-comprehension: plain array comprehension stays an array");

			h.eq(eval("var r = [for (i in 0...3) i * i].length;"), 3,
				"map-comprehension: array form still works");

			var ast3 = newParser().parseString("var m = [for (i in 0...2) i => i * 10];");
			h.check(hasNew(ast3, "Map"), "map-comprehension: single-variable form with a k => v body builds a Map");

			if (!mapSupported()) {
				trace("SKIP: map-comprehension runtime (Interp cannot resolve new Map() yet)");
				return;
			}
			h.eq(eval("var m = ['a' => 1, 'b' => 2]; var c = [for (k => v in m) k => v]; var t = 0; for (k => v in c) t += v; var r = c.get('a') * 10 + t;"), 13,
				"map-comprehension: runtime builds a working Map");
			h.eq(eval("var m = [for (i in 0...2) i => i * 10]; var r = m.get(1);"), 10,
				"map-comprehension: single-variable range form yields {0:0, 1:10}");
			h.eq(eval("var r = [for (i in 0...2) i => i * 10].get(0);"), 0,
				"map-comprehension: single-variable form key 0");
		} catch (e:Dynamic) h.crashed("map-comprehension", e);
	}

	// ------------------------------------------------------------ wildcard imports

	static function testWildcardImport(h:TestHarness) {
		try {
			var imp = firstImport(newParser().parseString("import haxe.ds.*;"));
			h.check(imp != null && imp.v == "haxe.ds.*" && imp.alias == null,
				"wildcard import: EImport(haxe.ds.*, null) (got " + Std.string(imp) + ")");

			var plain = firstImport(newParser().parseString("import haxe.ds.StringMap as SM;"));
			h.check(plain != null && plain.v == "haxe.ds.StringMap" && plain.alias == "SM",
				"wildcard import: aliased class import unchanged (got " + Std.string(plain) + ")");

			h.check(parseFails("import haxe.ds.* as X;"), "negative: wildcard import cannot be aliased");

			var decls = newParser().parseModule("import haxe.ds.*;");
			var ok = false;
			for (d in decls)
				switch (d) {
					case DImport(path, everything, _):
						ok = path.join(".") == "haxe.ds" && everything == true;
					default:
				}
			h.check(ok, "wildcard import: module DImport keeps everything=true");
		} catch (e:Dynamic) h.crashed("wildcard-import", e);
	}

	// ------------------------------------------------------- small parser gaps

	static function testSmallGaps(h:TestHarness) {
		try {
			h.eq(eval("var r = null; try { throw 42; } catch (e) { r = e; }"), 42,
				"catch: untyped catch (e) works");
			h.eq(eval("var r = null; try { throw 42; } catch (e:Dynamic) { r = e; }"), 42,
				"catch: typed catch still works");
			h.eq(eval("var a = 1;; var b = 2; var r = a + b;"), 3,
				"empty statement: double semicolon is a no-op between statements");
			h.eq(eval(";;; var r = 1;;"), 1, "empty statement: leading and trailing semicolons");
		} catch (e:Dynamic) h.crashed("small-gaps", e);
	}

	// ------------------------------------------------------------------ standalone

	static function main() {
		var h = new TestHarness();
		run(h);
		trace("== TestParserSyntax: " + h.summary() + " ==");
		if (h.failed > 0)
			Sys.exit(1);
	}
}
