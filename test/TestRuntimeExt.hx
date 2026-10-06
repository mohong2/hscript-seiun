/*
 * hscript-seiun runtime test-suite (T2): constructor/inheritance regressions,
 * Math/Std/Map resolution, enum + switch pattern semantics.
 * See LICENSE and NOTICE for details.
 */
package;

import hscript.Expr;
import hscript.Interp;
import hscript.Parser;
import hscript.Tools;

class TestRuntimeExt {
	public static function run(h:TestHarness):Void {
		ctorRegressions(h);
		inheritanceSemantics(h);
		builtinResolution(h);
		enumPatterns(h);
		switchSemanticsSynthetic(h);
		newSyntaxRuntime(h);
		wildcardImportLimits(h);
		orPatternBindingRules(h);
	}

	// ----------------------------- GOAL A: constructor bug --------------------
	static function ctorRegressions(h:TestHarness):Void {
		try {
			eq(h, 'class A { public var x:Int = 0; public function new(v) { x = v; } } var r = new A(5).x;', "r", 5,
				"ctor: no-base script class takes constructor args");
			eq(h, 'class A { public var x:Int = 3; } var r = new A().x;', "r", 3,
				"ctor: no-base script class without a constructor");
			eq(h, 'class A { public var x:Int = 0; public function new(v) { x = v; } } class B extends A { } var r = new B(5).x;', "r", 5,
				"ctor: child inherits the parent constructor");
			eq(h, 'class A { public var x:Int = 0; public function new(v) { x = v; } } class B extends A { public function new(v) { super.new(v); } } var r = new B(5).x;', "r", 5,
				"ctor: super.new(v) initialises the child instance");
			eq(h, 'class A { public var x:Int = 0; public function new(v) { x = v; } } class B extends A { public function new(v) { super(v); } } var r = new B(7).x;', "r", 7,
				"ctor: Haxe-style super(v) call");
			eq(h, 'class A { public var x:Int = 0; } class B extends A { public function new(v) { super(); x = v; } } var r = new B(9).x;', "r", 9,
				"ctor: super() with a parent that has no constructor");
			eq(h, 'class A { public var x:Int = 0; public function new(v) { x = v; } } class B extends A { public var y:Int = 0; public function new(v) { super.new(v); y = v + 1; } } var r = new B(5).y;', "r", 6,
				"ctor: child field initialised after super.new");
			#if CUSTOM_CLASSES
			var _:Class<script.TestBaseClass> = script.TestBaseClass;
			eq(h, 'class A extends script.TestBaseClass { } var r = new A().baseValue;', "r", 100,
				"ctor: shadow class inherits the Haxe base");
			eq(h, 'class A extends script.TestBaseClass { } var r = new A(250).baseValue;', "r", 250,
				"ctor: Haxe base still receives constructor args");
			eq(h, 'class A extends script.TestBaseClass { public function new(v) { super(v); } } var r = new A(42).baseValue;', "r", 42,
				"ctor: super(v) forwards args to the Haxe base constructor");
			#end
		} catch (e:Dynamic) {
			h.crashed("ctorRegressions", e);
		}
	}

	// ---------------------- GOAL A/B: inheritance + super chain ---------------
	static function inheritanceSemantics(h:TestHarness):Void {
		try {
			eq(h, 'class A { public var x:Int = 1; public function who() return "A"; } class B extends A { public function who() return "B-" + x; } class C extends B { public function who() return "C-" + super.who(); } var r = new C().who();',
				"r", "C-B-1", "super: grandparent chain, child-bound this");
			eq(h, 'class A { public var n:String = "animal"; public function speak() return n; } class B extends A { public function speak() return "woof-" + n; } var d = new B(); d.n = "rex"; var r = d.speak();',
				"r", "woof-rex", "super: field writes are visible to methods");
			eq(h, 'class A { public var n:String = "animal"; public function speak() return n; } class B extends A { public function speak() return "woof-" + n; } var d = new B(); var r = d.super.speak();',
				"r", "animal", "super: parent implementation runs, not the override");
			eq(h, 'class A { static var made = 0; public function new() { made++; } } class B extends A { } var a = new B(); var b = new B(); var r = A.made;',
				"r", 2, "super: static state shared across script inheritance");
		} catch (e:Dynamic) {
			h.crashed("inheritanceSemantics", e);
		}
	}

	// ------------------------------ GOAL D: Math / Std / Map -----------------
	static function builtinResolution(h:TestHarness):Void {
		try {
			eq(h, 'var r = Math.floor(2.7) + Math.ceil(0.2);', "r", 3, "builtin: Math resolves");
			eq(h, 'var r = Std.parseInt("42");', "r", 42, "builtin: Std resolves");
			eq(h, 'var r = Std.string(12) + "!";', "r", "12!", "builtin: Std.string resolves");
			eq(h, 'var r = Type.typeof(1);', "r", Type.ValueType.TInt, "builtin: Type resolves");
			eq(h, 'var m = new Map(); m.set("a", 1); var r = m.get("a");', "r", 1, "builtin: new Map() set/get");
			eq(h, 'var m = new Map(); m["k"] = 7; var r = m["k"];', "r", 7, "builtin: Map array access");
			eq(h, 'var m = new Map(); m.set("a", 1); m.set("b", 2); var t = 0; for (k => v in m) t += v; var r = t;', "r", 3,
				"builtin: Map key/value iteration");
			eq(h, 'var m = new Map(); m.set("a", 1); var e1 = m.exists("a"); m.remove("a"); var r = e1 && !m.exists("a");', "r", true,
				"builtin: Map exists/remove");
			eq(h, 'var m = new Map(); m.set(1, "one"); var r = m.get(1);', "r", "one", "builtin: Map with non-string keys");
			eq(h, 'var r = StringTools.replace("a-b", "-", "+");', "r", "a+b", "builtin: bare StringTools without import");
		} catch (e:Dynamic) {
			h.crashed("builtinResolution", e);
		}
	}

	// ------------------------------ GOAL D: enum patterns --------------------
	static function enumPatterns(h:TestHarness):Void {
		try {
			eq(h, 'enum E { A; B(v:Int); } var e = E.B(3); var r = switch(e) { case E.B(v): v; default: 0; };', "r", 3,
				"enum: case E.B(v) binds the parameter");
			eq(h, 'enum E { A; B(v:Int); } var e = E.B(3); var r = switch(e) { case E.B(_): 9; default: 0; };', "r", 9,
				"enum: wildcard parameter");
			eq(h, 'enum E { A; B(v:Int); } var e = E.A; var r = switch(e) { case E.A: 1; default: 0; };', "r", 1,
				"enum: constructor without parameters");
			eq(h, 'enum E { P(a:Int, b:Int); } var e = E.P(4, 5); var r = switch(e) { case E.P(a, b): a + b; default: 0; };', "r", 9,
				"enum: several bound parameters");
			eq(h, 'enum E { A; B(v:Int); } var e = E.B(3); var r = switch(e) { case E.A: 1; default: 0; };', "r", 0,
				"enum: non-matching constructor falls through");
			eq(h, 'enum E { B(v:Int); } var e = E.B(3); var r = switch(e) { case E.B(v) if (v > 2): "big"; default: "small"; };', "r", "big",
				"enum: guard sees the bound parameter");
			eq(h, 'enum E { B(v:Int); } var e = E.B(3); var r = switch(e) { case E.B(3): "exact"; default: "no"; };', "r", "exact",
				"enum: constant parameter pattern");
			eq(h, 'enum E { N(v:Int); } var e = E.N(2); var r = switch(e) { case E.N(v): v * 10; default: 0; } + switch(e) { case E.N(v): v * 100; default: 0; };',
				"r", 220, "enum: bindings do not leak between switches");
			eq(h, 'enum E { A; B(v:Int); } var e = E.B(3); var r = Std.string(e);', "r", "E.B(3)",
				"enum: script enum values still stringify");
		} catch (e:Dynamic) {
			h.crashed("enumPatterns", e);
		}
	}

	// --------- GOAL C: ESwitch semantics, independent of parser timing --------
	static function switchSemanticsSynthetic(h:TestHarness):Void {
		try {
			eqDyn(h, evalSwitch(x(EIdent("_")), 5), "big", "switch: guarded wildcard matches when guard is true");
			eqDyn(h, evalSwitch(x(EIdent("_")), 1), "small", "switch: guarded wildcard falls through when guard is false");
			eqDyn(h, evalUnguardedWildcard(x(EIdent("_")), 5), "big", "switch: unguarded wildcard value matches");
			eqDyn(h, evalOrPattern([x(EConst(CInt(1))), x(EConst(CInt(2)))], 2), "yes", "switch: or-pattern second alternative matches");
			eqDyn(h, evalOrPattern([x(EConst(CInt(1))), x(EConst(CInt(2)))], 9), "no", "switch: or-pattern falls through");
			eqDyn(h, evalOrPattern([x(EConst(CInt(1))), x(EIdent("_"))], 9), "yes", "switch: or-pattern with a wildcard alternative");
			var pat = x(ECall(x(EField(x(EIdent("E")), "A", false)), [x(EIdent("v"))]));
			var pat2 = x(ECall(x(EField(x(EIdent("E")), "B", false)), [x(EIdent("v"))]));
			var interp = new Interp();
			interp.variables.set("e", new hscript.Tools.EnumValue("E", "B", 1, [7]));
			var sc:SwitchCase = {values: [pat, pat2], expr: x(EIdent("v")), ifExpr: null};
			var result = interp.execute(x(ESwitch(x(EIdent("e")), [sc], x(EConst(CInt(0))))));
			eqDyn(h, result, 7, "switch: or-pattern of enum patterns binds the matching alternative");
		} catch (e:Dynamic) {
			h.crashed("switchSemanticsSynthetic", e);
		}
	}

	// -------- GOAL C: new syntax end-to-end (needs parser-dev's parser) -------
	static function newSyntaxRuntime(h:TestHarness):Void {
		try {
			eq(h, 'var x = 2; var r = switch(x) { case 1 | 2: "yes"; default: "no"; };', "r", "yes",
				"syntax: or-pattern case 1 | 2");
			eq(h, 'var x = 9; var r = switch(x) { case 1 | 2: "yes"; default: "no"; };', "r", "no",
				"syntax: or-pattern falls through");
			eq(h, 'var x = 5; var r = switch(x) { case _ if (x > 3): "big"; default: "small"; };', "r", "big",
				"syntax: guarded wildcard matches");
			eq(h, 'var x = 1; var r = switch(x) { case _ if (x > 3): "big"; default: "small"; };', "r", "small",
				"syntax: guarded wildcard does not swallow default");
			eq(h, 'var x = "b"; var r = switch(x) { case "a" | "b" if (x == "b"): "hit"; default: "miss"; };', "r", "hit",
				"syntax: or-pattern with a guard");
			eq(h, 'import haxe.ds.*; var m = new StringMap(); m.set("x", 5); var r = m.get("x");', "r", 5,
				"syntax: wildcard import resolves package members");
			eq(h, 'import haxe.ds.*; var m = new IntMap(); m.set(1, 5); var r = m.get(1);', "r", 5,
				"syntax: wildcard import resolves a second package member");
			eq(h, 'var src = ["a" => 1, "b" => 2]; var m = [for (k => v in src) k => v * 2]; var r = m.get("b");', "r", 4,
				"syntax: map comprehension [for (k => v in m) k => v]");
			eq(h, 'var [a, ...rest] = [1,2,3]; var r = a + rest.length;', "r", 3, "syntax: destructuring rest");
			eq(h, 'var {x: y} = {x: 5}; var r = y;', "r", 5, "syntax: destructuring rename");
			eq(h, 'var {x = 9} = {}; var r = x;', "r", 9, "syntax: destructuring default");
			eq(h, 'var {a: [b, c]} = {a: [3, 4]}; var r = b + c;', "r", 7, "syntax: nested object/array destructuring");
			eq(h, 'var [[a],[b]] = [[1],[2]]; var r = a + b;', "r", 3, "syntax: nested array destructuring");
			eq(h, 'var t = 0; for ([a, b] in [[1,2],[3,4]]) t += a + b; var r = t;', "r", 10, "syntax: for-in destructuring");
			eq(h, 'var a = 0; var b = 0; [a, b] = [7, 8]; var r = a * 10 + b;', "r", 78, "syntax: assignment destructuring");
			eq(h, 'function f<T>(x:T):T return x; var r = f(3);', "r", 3, "syntax: generic function type parameters");
		} catch (e:Dynamic) {
			h.crashed("newSyntaxRuntime", e);
		}
	}

	// ------- F1: wildcard import of a missing package is deferred on purpose -
	static function wildcardImportLimits(h:TestHarness):Void {
		try {
			var interp = runCode('import does.not.exist.*; var r = 1;');
			h.eq(interp.variables.get("r"), 1,
				"wildcard import: unknown package is accepted, the import itself does not fail");
			expectError(h, 'import does.not.exist.*; var r = Nope;', "Unknown variable",
				"wildcard import: an unknown identifier fails on first use");
		} catch (e:Dynamic) {
			h.crashed("wildcardImportLimits", e);
		}
	}

	// ------- F3: frozen or-pattern binding rules ------------------------------
	static function orPatternBindingRules(h:TestHarness):Void {
		try {
			eq(h, 'var x = 9; var r = switch(x) { case v | 5: v; default: 0; };', "r", 9,
				"or-pattern: an identifier alternative matches any value (left to right)");
			eq(h, 'var x = 5; var r = switch(x) { case v | 5: v; default: 0; };', "r", 5,
				"or-pattern: the identifier alternative binds the switched value");
			eq(h, 'var x = 7; var r = switch(x) { case 1 | v: v; default: 0; };', "r", 7,
				"or-pattern: a literal first, then the identifier alternative matches");
			expectError(h, 'var n = 5; var r = switch(n) { case 5 | x if (x == 5): "hit"; default: "miss"; };',
				"Unknown variable: x",
				"or-pattern: the guard sees only the matching alternative's bindings");
			expectError(h, 'var n = 10; var r = switch(n) { case 1 | y if (y < 5): "hit"; default: "after"; }; var leaked = y;',
				"Unknown variable: y",
				"or-pattern: bindings are restored when the case does not match");
		} catch (e:Dynamic) {
			h.crashed("orPatternBindingRules", e);
		}
	}

	// -------------------------------- helpers --------------------------------
	static function runCode(code:String, ?setup:Interp->Void):Interp {
		var p = new Parser();
		p.allowTypes = true;
		var ast = p.parseString(code, "runtime-ext.hx");
		var interp = new Interp();
		if (setup != null)
			setup(interp);
		interp.execute(ast);
		return interp;
	}

	static function eq(h:TestHarness, code:String, key:String, want:Dynamic, name:String):Void {
		var interp = runCode(code);
		h.eq(interp.variables.get(key), want, name);
	}

	static function eqDyn(h:TestHarness, got:Dynamic, want:Dynamic, name:String):Void {
		h.eq(got, want, name);
	}

	#if hscriptPos
	static inline function x(e:ExprDef):Expr {
		var out:Expr = {e: e, pmin: 0, pmax: 0, origin: "synthetic", line: 1};
		return out;
	}
	#else
	static inline function x(e:Expr):Expr return e;
	#end

	static function evalSwitch(pattern:Expr, value:Int):Dynamic {
		var interp = new Interp();
		interp.variables.set("x", value);
		var body = x(EConst(CString("big")));
		var guard = x(EBinop(">", x(EIdent("x")), x(EConst(CInt(3)))));
		var sc:SwitchCase = {values: [pattern], expr: body, ifExpr: guard};
		return interp.execute(x(ESwitch(x(EIdent("x")), [sc], x(EConst(CString("small"))))));
	}

	static function evalUnguardedWildcard(pattern:Expr, value:Int):Dynamic {
		var interp = new Interp();
		interp.variables.set("x", value);
		var sc:SwitchCase = {values: [pattern], expr: x(EConst(CString("big"))), ifExpr: null};
		return interp.execute(x(ESwitch(x(EIdent("x")), [sc], x(EConst(CString("small"))))));
	}

	static function evalOrPattern(values:Array<Expr>, value:Int):Dynamic {
		var interp = new Interp();
		var sc:SwitchCase = {values: values, expr: x(EConst(CString("yes"))), ifExpr: null};
		return interp.execute(x(ESwitch(x(EConst(CInt(value))), [sc], x(EConst(CString("no"))))));
	}

	/** Runs `code` and asserts the runtime error text contains `needle`. */
	static function expectError(h:TestHarness, code:String, needle:String, name:String):Void {
		var p = new Parser();
		p.allowTypes = true;
		var ast = p.parseString(code, "runtime-ext.hx");
		var interp = new Interp();
		var captured:String = null;
		interp.errorHandler = function(e) captured = Std.string(e);
		interp.execute(ast);
		h.check(captured != null && captured.indexOf(needle) >= 0, name + " (got " + Std.string(captured) + ")");
	}

	static function main() {
		var h = new TestHarness();
		run(h);
		Sys.println("TestRuntimeExt: " + h.summary());
		if (h.failed > 0)
			Sys.exit(1);
	}
}
