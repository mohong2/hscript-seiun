/*
 * hscript-seiun Bytes round-trip / cross-version compatibility suite (MIT).
 *
 * Standalone:
 *   haxe -cp . -cp test -D hscriptPos -D CUSTOM_CLASSES \
 *        --macro "hscript.macros.UsingHandler.init()" \
 *        --macro "hscript.macros.ClassExtendMacro.init()" \
 *        -main TestBytesCompat --interp
 */
package;

import hscript.Async.AsyncInterp;
import hscript.Bytes;
import hscript.Expr;
import hscript.Interp;
import hscript.Parser;

class TestBytesCompat {
	// ────────────────────────────────────────────────────────────────────
	// helpers
	// ────────────────────────────────────────────────────────────────────

	static function newParser():Parser {
		var p = new Parser();
		p.allowTypes = true;
		p.allowJSON = true;
		p.allowMetadata = true;
		return p;
	}

	/** Sorted "name=value" digest of an interp's variables; class/function
	    values are reduced to a marker so two fresh Interps compare equal. */
	static function fingerprint(i:Interp):String {
		var keys = [for (k in i.variables.keys()) k];
		keys.sort(Reflect.compare);
		var b = new StringBuf();
		for (k in keys) {
			if (k == "this") continue;
			var v = i.variables.get(k);
			b.add(k);
			b.add("=");
			if (v == null) b.add("null");
			else if (Std.isOfType(v, Int) || Std.isOfType(v, Float) || Std.isOfType(v, Bool) || Std.isOfType(v, String)) b.add(Std.string(v));
			else if (Type.typeof(v) == TFunction) b.add("<fun>");
			else b.add("<obj>");
			b.add(";");
		}
		return b.toString();
	}

	static function execAst(ast:Expr, ?setup:Interp->Void):{fp:String, err:String} {
		try {
			var i = new Interp();
			if (setup != null) setup(i);
			i.execute(ast);
			return {fp: fingerprint(i), err: null};
		} catch (e:Dynamic) {
			return {fp: null, err: Std.string(e)};
		}
	}

	/**
		Encode -> decode -> re-encode -> execute both trees.
		Asserts byte stability, identical error behaviour and identical results.
	**/
	static function rt(h:TestHarness, name:String, src:String, ?setup:Interp->Void) {
		var ast:Expr = null;
		try ast = newParser().parseString(src, name + ".hx") catch (e:Dynamic) {
			h.check(false, name + ": parse threw " + Std.string(e));
			return;
		}
		var bytes:haxe.io.Bytes = null;
		try bytes = Bytes.encode(ast) catch (e:Dynamic) {
			h.check(false, name + ": encode threw " + Std.string(e));
			return;
		}
		var ast2:Expr = null;
		try ast2 = Bytes.decode(bytes) catch (e:Dynamic) {
			h.check(false, name + ": decode threw " + Std.string(e));
			return;
		}
		var bytes2:haxe.io.Bytes = null;
		try bytes2 = Bytes.encode(ast2) catch (e:Dynamic) {
			h.check(false, name + ": re-encode threw " + Std.string(e));
			return;
		}
		if (bytes.toHex() != bytes2.toHex()) {
			h.check(false, name + ": encode(decode(x)) is not byte-stable");
			return;
		}
		var r1 = execAst(ast, setup);
		var r2 = execAst(ast2, setup);
		if (r1.err != r2.err) {
			h.check(false, name + ": error differs (orig=" + r1.err + " decoded=" + r2.err + ")");
			return;
		}
		if (r1.fp != r2.fp) {
			h.check(false, name + ": execution differs (orig=" + r1.fp + " decoded=" + r2.fp + ")");
			return;
		}
		h.check(true, name);
	}

	/** Documents a round-trip loss without failing the suite. */
	static function limitation(name:String, src:String) {
		var ast:Expr = null;
		try ast = newParser().parseString(src, name + ".hx") catch (e:Dynamic) {
			trace("LIMITATION " + name + ": parse threw " + Std.string(e));
			return;
		}
		var bytes:haxe.io.Bytes = null;
		try bytes = Bytes.encode(ast) catch (e:Dynamic) {
			trace("LIMITATION " + name + ": encode threw " + Std.string(e));
			return;
		}
		var ast2:Expr = null;
		try ast2 = Bytes.decode(bytes) catch (e:Dynamic) {
			trace("LIMITATION " + name + ": decode threw " + Std.string(e));
			return;
		}
		var r1 = execAst(ast);
		var r2 = execAst(ast2);
		if (r1.err == r2.err && r1.fp == r2.fp) {
			trace("LIMITATION RESOLVED " + name + " (format now round-trips this)");
		} else {
			trace("LIMITATION " + name + ": orig=" + r1.fp + "/" + r1.err + " decoded=" + r2.fp + "/" + r2.err);
		}
	}

	// ────────────────────────────────────────────────────────────────────
	// suite
	// ────────────────────────────────────────────────────────────────────

	public static function run(h:TestHarness):Void {
		testConstructs(h);
		testOperators(h);
		testSwitchAndImports(h);
		testStringTable(h);
		testFloats(h);
		testArguments(h);
		testFormatAndPayloads(h);
		testNewSyntax(h);
		testAsync(h);
	}

	/** Every construct the interpreter supports must survive a cache round-trip. */
	static function testConstructs(h:TestHarness):Void {
		rt(h, "const-int", "var r = 42;");
		rt(h, "const-int-neg", "var r = -300;");
		rt(h, "const-int-big", "var r = 70000;");
		rt(h, "const-float", "var r = 1.5;");
		rt(h, "const-string", "var r = \"hello\";");
		rt(h, "const-string-esc", "var r = \"a\\tb\\n\\\"q\\\"\";");
		rt(h, "const-unicode", "var r = \"\\u00e9\\u4e2d\";");
		rt(h, "const-true", "var r = true;");
		rt(h, "const-null", "var r = null;");
		rt(h, "ident", "var abc = 1; var r = abc;");
		rt(h, "parent", "var r = (1 + 2) * 3;");
		rt(h, "block", "var r = 0; { var a = 1; r = a; }");
		rt(h, "multi-var-decl", "var a = 1, b = 2; var r = a + b;");
		rt(h, "field", "var o = {x: 3}; var r = o.x;");
		rt(h, "field-safe", "var o = null; var r = o?.x;");
		rt(h, "field-safe-chain", "var o = null; var r = o?.a?.b;");
		rt(h, "array", "var a = [1,2,3]; var r = a[1];");
		rt(h, "arraydecl", "var r = [1,2,3];");
		rt(h, "object", "var r = {a: 1, b: \"x\"};");
		rt(h, "object-shorthand", "var x = 5; var r = {x};");
		rt(h, "json-object-keys", "var r = {\"a-b\": 1, \"c d\": 2};");
		rt(h, "object-in-array", "var r = [{a:1},{b:2}];");
		rt(h, "call", "function f(a,b) return a+b; var r = f(1,2);");
		rt(h, "call-spread", "function f(a,b) return a+b; var arr=[1,2]; var r = f(...arr);");
		rt(h, "new", "class C { public var v = 7; public function new() {} } var c = new C(); var r = c.v;");
		rt(h, "new-args", "class C { public var v; public function new(x) { v = x; } } var c = new C(9); var r = c.v;");
		rt(h, "new-nested", "class C { public var v; public function new(x) { v = x; } } var c = new C(new C(2).v); var r = c.v;");
		rt(h, "if", "var r = 0; if (true) r = 1; else r = 2;");
		rt(h, "while", "var i = 0; while (i < 3) i++; var r = i;");
		rt(h, "dowhile", "var i = 0; do { i++; } while (i < 3); var r = i;");
		rt(h, "for", "var s = 0; for (i in 0...4) s += i; var r = s;");
		rt(h, "for-keyvalue", "var m = [\"a\" => 1, \"b\" => 2]; var s = 0; for (k => v in m) s += v; var r = s;");
		rt(h, "break-continue", "var s = 0; for (i in 0...10) { if (i == 2) continue; if (i == 5) break; s += i; } var r = s;");
		rt(h, "return", "function f() { return 3; } var r = f();");
		rt(h, "return-void", "function f() { return; } f(); var r = 1;");
		rt(h, "nested-functions", "function a() { function b() return 2; return b(); } var r = a();");
		rt(h, "deep-nesting", "var r = ((((((((((1+2))))))))));");
		rt(h, "throw-try", "var r = 0; try { throw \"x\"; } catch (e:Dynamic) { r = 1; }");
		rt(h, "catch-typed", "var r = 0; try { throw \"x\"; } catch (e:String) { r = 1; }");
		rt(h, "ternary", "var r = true ? 1 : 2;");
		rt(h, "unop-prefix", "var r = !false;");
		rt(h, "unop-not-chain", "var r = !!true;");
		rt(h, "unop-neg", "var r = -5;");
		rt(h, "unop-bitnot", "var r = ~1;");
		rt(h, "unop-postfix", "var i = 0; i++; var r = i;");
		rt(h, "unop-postfix-dec", "var i = 5; i--; var r = i;");
		rt(h, "binop-null-coalesce", "var a = null; var r = a ?? 5;");
		rt(h, "meta", "@:keep var r = 1;");
		rt(h, "meta-args", "@:keep(1, \"x\") var r = 1;");
		rt(h, "meta-class-field", "@:build class C { @:keep public var x = 1; } var r = 1;");
		rt(h, "checked-type-unchecked", "var x = \"42\"; var r = cast x;");
		rt(h, "import-as", "import haxe.ds.StringMap as SM; var r = 1;");
		rt(h, "using", "using StringTools; var r = \"x\";");
		rt(h, "typedef-anon", "typedef T = {x:Int}; var r = 1;");
		rt(h, "typedef-extend", "typedef T = {> Base, x:Int}; var r = 1;");
		rt(h, "typedef-anon-then-use", "typedef T = {x:Int}; var a:T; var r = 7;");
		rt(h, "package-decl", "package foo.bar; var r = 3;");
		rt(h, "typedef-redirect", "typedef MyMath = Math; var r = MyMath;");
		rt(h, "var-const", "final x = 1; var r = x;");
		rt(h, "enum-simple", "enum Color { Red; Green; } var r = Color.Red;");
		rt(h, "enum-ctor", "enum E { A; B(v:Int); } var r = E.B(3);");
		rt(h, "enum-switch-args", "enum E { A; B(v:Int); } var e = E.B(3); var r = switch (e) { case E.B(v): v; default: 0; };");
		rt(h, "class-basic", "class Foo { var x = 1; public function get() return x; } var f = new Foo(); var r = f.get();");
		rt(h, "class-static", "class S { public static var n:Int = 7; public static function add(a,b) return a+b; } S.n = 9; var r = S.n + S.add(1,2);");
		rt(h, "class-extend", "class A { public var v = 1; public function f() return v; } class B extends A { public function g() return f() + 1; } var b = new B(); var r = b.g();");
		rt(h, "class-super", "class A { public function f() return 1; } class B extends A { public function f() return super.f() + 1; } var b = new B(); var r = b.f();");
		rt(h, "class-implements", "class C implements I { } var r = 1;");
		rt(h, "string-format", "var x = 42; var r = \"v=$" + "x\";");
		rt(h, "string-interp-expr", "var x = 40; var r = \"v=$" + "{x + 2}\";");
		rt(h, "untyped", "untyped (1 + 2); var r = 3;");
		rt(h, "generic-new", "var a = new Array<Array<Int>>(); a.push([1]); var r = a.length;");
		rt(h, "arrow-fn", "var f = (a) -> a * 2; var r = f(3);");
		rt(h, "destructure-array", "var arr = [1,2]; var [a,b] = arr; var r = a + b;");
		rt(h, "destructure-object", "var o = {x: 1, y: 2}; var {x, y} = o; var r = x + y;");
		rt(h, "switch-multi-values", "var v = 2; var r = switch (v) { case 1, 2: \"a\"; default: \"b\"; };");
	}

	/** Regression: the operator table was encoded/decoded with an off-by-one shift,
	    so every operator except "+" failed to decode or decoded to the wrong op. */
	static function testOperators(h:TestHarness):Void {
		var binops = ["+","-","*","/","%","&","|","^","<<",">>",">>>","==","!=",">=","<=",">","<","||","&&","??"];
		for (op in binops)
			rt(h, "binop[" + op + "]", "var a = 6; var b = 3; var r = a " + op + " b;");
		var assignops = ["=","+=","-=","*=","/=","%=","&=","|=","^=","<<=",">>=",">>>=","??="];
		for (op in assignops)
			rt(h, "assignop[" + op + "]", "var a = 6; a " + op + " 3; var r = a;");
		rt(h, "op-map-literal", "var r = [\"a\" => 1, \"b\" => 2];");
		rt(h, "op-keyvalue-for", "var m = [1 => 2]; var r = 0; for (k => v in m) r = k + v;");
		rt(h, "op-postfix-plusplus", "var i = 0; i++; var r = i;");
		rt(h, "op-prefix-minusminus", "var i = 4; --i; var r = i;");
	}

	/** Regression: ESwitch.ifExpr == null threw at encode; unaliased imports threw
	    "Null Access" because the string table has no null entry. */
	static function testSwitchAndImports(h:TestHarness):Void {
		rt(h, "switch-unguarded-cases", "var v = 2; var r = switch (v) { case 1: \"a\"; case 2: \"b\"; default: \"c\"; };");
		rt(h, "switch-no-default", "var v = 9; var r = switch (v) { case 1: \"a\"; };");
		rt(h, "switch-guard", "var v = 5; var r = switch (v) { case x if (x > 3): \"big\"; default: \"small\"; };");
		rt(h, "switch-empty-block-body", "var v = 1; var r = switch (v) { case 1: {} default: 2; };");
		rt(h, "import-unaliased", "import haxe.ds.StringMap; var r = 1;");
		rt(h, "import-inside-fn", "function f() { import haxe.ds.StringMap; return 1; } var r = f();");
	}

	/** Regression: the decoder reset the string table one entry early, corrupting
	    any cache with 255 or more distinct strings. */
	static function testStringTable(h:TestHarness):Void {
		var sb = new StringBuf();
		for (i in 0...301) sb.add("var s" + i + " = \"uniq-" + i + "\";\n");
		sb.add("var r = s299 + \"|\" + s0;");
		rt(h, "strings-301-distinct", sb.toString());

		var sb2 = new StringBuf();
		for (i in 0...300) sb2.add("var u" + i + " = \"v" + i + "\";\n");
		sb2.add("var r = u0 + u255 + u299;");
		rt(h, "strings-300-distinct-boundary", sb2.toString());
	}

	/** Regression: Std.string(Infinity) == "infinity", which Std.parseFloat cannot
	    read back; the decoder now maps the non-finite spellings explicitly. */
	static function testFloats(h:TestHarness):Void {
		rt(h, "float-plain", "var r = 0.5;");
		rt(h, "float-negative", "var r = -1234.5;");
		rt(h, "float-exp", "var r = 1e10;");
		rt(h, "float-arithmetic", "var r = 1.0 / 0.0 + 0.0 * 1.0;");
		#if hscriptPos
		// Non-finite floats have no script spelling, so build the node directly:
		// Std.string(Infinity) is "infinity" and Std.parseFloat cannot read it.
		var pinf:Expr = {e: EConst(CFloat(Math.POSITIVE_INFINITY)), pmin: 0, pmax: 0, origin: "inf.hx", line: 1};
		var back = Bytes.decode(Bytes.encode(pinf));
		var got:Float = switch (back.e) {
			case EConst(CFloat(f)): f;
			default: -1.0;
		}
		h.check(got == Math.POSITIVE_INFINITY, "float: +Infinity survives the codec (got " + got + ")");
		var pnan:Expr = {e: EConst(CFloat(Math.NaN)), pmin: 0, pmax: 0, origin: "nan.hx", line: 1};
		var backN = Bytes.decode(Bytes.encode(pnan));
		var gotN:Float = switch (backN.e) {
			case EConst(CFloat(f)): f;
			default: -1.0;
		}
		h.check(Math.isNaN(gotN), "float: NaN survives the codec (got " + gotN + ")");
		#end
	}

	/** Regression: Argument.rest was not encoded, so "...rest" became null after a
	    round-trip. Default argument values are still not encoded (see limitations). */
	static function testArguments(h:TestHarness):Void {
		rt(h, "rest-args", "function f(a, ...rest) return a + rest.length; var r = f(1,2,3);");
		rt(h, "rest-args-empty", "function f(a, ...rest) return rest.length; var r = f(1);");
		rt(h, "optional-arg", "function f(?a:Int) return a == null ? 7 : a; var r = f();");
	}

	/** Async.hx is not referenced by the rest of the test-suite; this keeps it
	    compiled and exercised on every CI run. */
	static function testAsync(h:TestHarness):Void {
		var ok = true;
		var detail = "";
		try {
			var ast = newParser().parseString("var n = 0; for (i in 0...3) n += 1;", "asyncfor.hx");
			var a = hscript.Async.toAsync(ast);
			var i = new AsyncInterp();
			i.execute(a);
			if (i.variables.get("n") != 3) {
				ok = false;
				detail = " for-loop n=" + i.variables.get("n");
			}
			var ast2 = newParser().parseString("var x = 1 + 2;", "sync.hx");
			var i2 = new AsyncInterp();
			i2.execute(hscript.Async.toAsync(ast2, true));
			if (i2.variables.get("x") != 3) {
				ok = false;
				detail += " topLevelSync x=" + i2.variables.get("x");
			}
		} catch (e:Dynamic) {
			ok = false;
			detail = " threw " + Std.string(e);
		}
		h.check(ok, "async: toAsync transforms execute on AsyncInterp" + detail);
	}

	/** Constructs added by the parser/interp workstreams must survive the cache
	    too, including the wildcard-import encoding agreed for EImport. */
	static function testNewSyntax(h:TestHarness):Void {
		rt(h, "new-or-pattern", "var v = 2; var r = switch (v) { case 1 | 2: \"a\"; default: \"b\"; };");
		rt(h, "new-or-pattern-bitwise-or", "var v = 3; var r = switch (v) { case (1 | 2): \"or\"; default: \"no\"; };");
		rt(h, "new-guarded-wildcard", "var v = 5; var r = switch (v) { case _ if (v > 3): \"big\"; default: \"small\"; };");
		rt(h, "new-destructure-rest", "var [a, ...rest] = [1,2,3]; var r = a + rest.length;");
		rt(h, "new-destructure-rename", "var {x: y} = {x: 5}; var r = y;");
		rt(h, "new-destructure-default", "var {x = 7} = {}; var r = x;");
		rt(h, "new-destructure-nested", "var {a: [b, c]} = {a: [1, 2]}; var r = b + c;");
		rt(h, "new-destructure-for", "var s = 0; for ([a, b] in [[1,2],[3,4]]) s += a + b; var r = s;");
		rt(h, "new-destructure-assign", "var a = 0; var b = 0; [a, b] = [1, 2]; var r = a + b;");
		rt(h, "new-generic-fn", "function f<T>(x:T):T return x; var r = f(3);");
		rt(h, "new-generic-two", "function f<T, U>(a:T, b:U) return a; var r = f(1, \"x\");");
		rt(h, "new-map-comprehension", "var m = [1 => \"a\", 2 => \"b\"]; var c = [for (k => v in m) k => v]; var n = 0; for (k => v in c) n++; var r = n;");
		rt(h, "new-wildcard-import", "import haxe.ds.*; var r = 1;");
		rt(h, "new-wildcard-import-use", "import haxe.ds.*; var m = new StringMap(); m.set(\"a\", 1); var r = m.get(\"a\");");
	}

	/**
		Format v2 (version byte + widened lengths + CType/Argument encoding).
		These used to be silent losses; they are now hard assertions so a
		regression fails the suite instead of being quietly reported.
	**/
	static function testFormatAndPayloads(h:TestHarness):Void {
		rt(h, "default-arg-value", "function f(b:Int = 2) return b; var r = f();");
		rt(h, "default-arg-values-two", "function f(a:Int = 1, b:Int = 2) return a * 10 + b; var r = f();");
		rt(h, "default-arg-mixed", "function f(a, b:Int = 2) return a + b; var r = f(1);");
		rt(h, "cast-type", "var x = \"42\"; var r = cast(x, String);");
		rt(h, "var-type-annotation", "var a:Int = 1; var r = a;");
		rt(h, "function-return-type", "function f():Int return 3; var r = f();");
		rt(h, "catch-type-mismatch", "var r = 0; try { throw 5; } catch (e:String) { r = 1; }");
		rt(h, "catch-type-match", "var r = 0; try { throw \"x\"; } catch (e:String) { r = 1; }");
		var big = new StringBuf();
		for (i in 0...300) big.add("a");
		rt(h, "string-300-bytes", "var r = \"" + big.toString() + "\";");
		// collection counts used to be a single byte and wrapped above 255
		var args = [for (i in 0...300) Std.string(i)].join(",");
		rt(h, "call-300-args", "function f(a, ...rest) return rest.length; var r = f(" + args + ");");
		rt(h, "object-300-fields", "var o = {" + [for (i in 0...300) "f" + i + ": " + i].join(",") + "}; var r = o.f299;");

		// format versioning: an unknown version must fail loudly, not decode garbage
		var bytes = Bytes.encode(newParser().parseString("var r = 1;", "v.hx"));
		h.eq(bytes.get(0), Bytes.FORMAT_VERSION, "format: stream starts with FORMAT_VERSION");
		var bad = haxe.io.Bytes.alloc(bytes.length);
		bad.blit(0, bytes, 0, bytes.length);
		bad.set(0, (Bytes.FORMAT_VERSION + 1) & 0xFF);
		var msg = "";
		try Bytes.decode(bad) catch (e:Dynamic) msg = Std.string(e);
		h.check(msg.indexOf("Unsupported hscript bytes format version") == 0, "format: unknown version rejected (" + msg + ")");
		var empty = "";
		try Bytes.decode(haxe.io.Bytes.alloc(0)) catch (e:Dynamic) empty = Std.string(e);
		h.check(empty.indexOf("Empty hscript bytes stream") == 0, "format: empty stream rejected (" + empty + ")");
	}

	static function main() {
		var h = new TestHarness();
		run(h);
		Sys.println("== TestBytesCompat: " + h.summary() + " ==");
		if (h.failed > 0) {
			for (f in h.failures) Sys.println("  FAILED: " + f);
			Sys.exit(1);
		}
	}
}
