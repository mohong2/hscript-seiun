/*
 * Copyright (C)2008-2017 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package hscript;

import Type.ValueType;
import hscript.Expr;
import hscript.Tools;
import hscript.iris.Iris;
import hscript.iris.IrisUsingClass;
import hscript.iris.utils.UsingEntry;
import haxe.Constraints.IMap;
import haxe.PosInfos;

private enum Stop {
	SBreak;
	SContinue;
	SReturn;
}

@:structInit
class LocalVar {
	public var r: Dynamic;
	public var const: Bool;
}

@:structInit
class DeclaredVar {
	public var n: String;
	public var old: LocalVar;
}

class Interp {
	public var scriptObject(default, set):Dynamic;
	public function set_scriptObject(v:Dynamic) {
		var c:Class<Dynamic> = Type.getClass(v);
		__instanceFields = (c == null) ? [] : Type.getInstanceFields(c);
		return scriptObject = v;
	}
	public var errorHandler:Error->Void;
	public var importFailedCallback:Array<String>->Bool;

	#if haxe3
	public var variables: Map<String, Dynamic>;
	public var imports: Map<String, Dynamic>;
	public var customClasses: Map<String, Dynamic>;
	public var publicVariables: Map<String, Dynamic>;
	public var staticVariables: Map<String, Dynamic>;

	public var locals: Map<String, LocalVar>;
	#else
	public var variables: Hash<Dynamic>;
	public var imports: Hash<Dynamic>;
	public var customClasses: Hash<Dynamic>;
	public var publicVariables: Hash<Dynamic>;
	public var staticVariables: Hash<Dynamic>;

	public var locals: Hash<LocalVar>;
	#end

	var depth: Int;
	var inTry: Bool;
	// Script call chain, kept in flat arrays: pushing a frame is three array
	// writes and an int increment, so it stays affordable on the hot call path.
	// The trace is only materialised when an error is built.
	static inline var MAX_TRACE = 64;
	var traceNames: Array<String> = [];
	var traceLines: Array<Int> = [];
	var traceOrigins: Array<String> = [];
	var traceDepth: Int = 0;
	var declared: Array<DeclaredVar>;
	var returnValue: Dynamic;

	#if hscriptPos
	var curExpr: Expr;
	#end

	public var showPosOnLog: Bool = true;

	public var importEnabled:Bool = true;
	public var allowStaticVariables:Bool = false;
	public var allowPublicVariables:Bool = false;

	public var importBlocklist:Array<String> = [];

	public static var importRedirects:Map<String, String> = new Map();
	public var localImportRedirects:Map<String, String> = new Map();
	public function getImportRedirect(className:String):String {
		if (importRedirects.exists(className))
			className = importRedirects.get(className);
		if (localImportRedirects.exists(className))
			className = localImportRedirects.get(className);
		return className;
	}

	/** Field redirects for `get`/`set`, keyed by class name (hscript-improved). */
	public static var getRedirects:Map<String, Dynamic->String->Dynamic> = [];
	public static var setRedirects:Map<String, Dynamic->String->Dynamic->Dynamic> = [];

	var __instanceFields:Array<String> = [];
	/** Package prefixes introduced by `import some.pkg.*;` expressions. */
	var wildcardImports:Array<String> = [];
	var isBypassAccessor:Bool = false;

	public function new() {
		depth = 0;
		inTry = false;
		returnValue = null;
		#if haxe3
		locals = new Map();
		#else
		locals = new Hash();
		#end
		declared = new Array();
		resetVariables();
	}

	private function resetVariables() {
		#if haxe3
		variables = new Map<String, Dynamic>();
		imports = new Map<String, Dynamic>();
		customClasses = new Map<String, Dynamic>();
		publicVariables = new Map<String, Dynamic>();
		staticVariables = new Map<String, Dynamic>();
		#else
		variables = new Hash();
		imports = new Hash();
		customClasses = new Hash();
		publicVariables = new Hash();
		staticVariables = new Hash();
		#end

		variables.set("null", null);
		variables.set("true", true);
		variables.set("false", false);
		variables.set("trace", Reflect.makeVarArgs(function(el) {
			var inf = posInfos();
			var v = el.shift();
			if (el.length > 0)
				inf.customParams = el;
			haxe.Log.trace(Std.string(v), inf);
		}));
	}

	inline function pushFrame(name: String, line: Int, origin: String): Void {
		var d = traceDepth;
		traceDepth = d + 1;
		if (d >= MAX_TRACE)
			return;
		if (d == traceNames.length) {
			traceNames.push(name);
			traceLines.push(line);
			traceOrigins.push(origin);
		} else {
			traceNames[d] = name;
			traceLines[d] = line;
			traceOrigins[d] = origin;
		}
	}

	inline function popFrame(): Void {
		if (traceDepth > 0)
			traceDepth--;
	}

	#if hscriptPos
	/** Materialises the active script call chain into a thrown Error. */
	function attachTrace(err: Error): Void {
		var d = traceDepth;
		if (d <= 0)
			return;
		var out: Array<String> = [];
		var i = (d < MAX_TRACE ? d : MAX_TRACE) - 1;
		// innermost frame first, like every other stack trace
		while (i >= 0) {
			out.push(traceNames[i] + " (" + traceOrigins[i] + ":" + traceLines[i] + ")");
			i--;
		}
		if (out.length > 0)
			err.stack = out;
	}
	#end

	public function posInfos(): PosInfos {
		#if hscriptPos
		if (curExpr != null)
			return cast {fileName: curExpr.origin, lineNumber: curExpr.line};
		#end
		return cast {fileName: "hscript", lineNumber: 0};
	}

	/**
	 * Binary-operator dispatch.
	 *
	 * This used to be a Map<String, Interp->Expr->Expr->Dynamic> that was looked
	 * up on every evaluation and then invoked through a dynamic closure. A direct
	 * switch keeps exactly the same semantics (including &&/|| short-circuiting
	 * and the ?? fallback) while removing a hash lookup plus an indirect call
	 * from the hottest path in the interpreter.
	 */
	/**
	 * Binary-operator dispatch.
	 *
	 * Operators used to be looked up in a Map<String, closure> and then invoked
	 * through a dynamic call on every evaluation. A plain switch on the operator
	 * string is not a good fit either: on hxcpp a string switch compiles to a
	 * chain of string comparisons, so rare operators pay for every earlier case.
	 * Dispatching on the first character first is a jump table, and the second
	 * character (or a length check) settles the handful of collisions.
	 */
	function binop(op: String, e1: Expr, e2: Expr): Dynamic {
		if (op.length == 0)
			return error(EInvalidOp(op));
		switch (op.charCodeAt(0)) {
			case 43: // +
				if (op.length == 1) return expr(e1) + expr(e2);
				return evalAssignOp(op, e1, e2);
			case 45: // -
				if (op.length == 1) return expr(e1) - expr(e2);
				return evalAssignOp(op, e1, e2);
			case 42: // *
				if (op.length == 1) return expr(e1) * expr(e2);
				return evalAssignOp(op, e1, e2);
			case 47: // /
				if (op.length == 1) return expr(e1) / expr(e2);
				return evalAssignOp(op, e1, e2);
			case 37: // %
				if (op.length == 1) return expr(e1) % expr(e2);
				return evalAssignOp(op, e1, e2);
			case 94: // ^
				if (op.length == 1) return expr(e1) ^ expr(e2);
				return evalAssignOp(op, e1, e2);
			case 38: // &
				if (op.length == 1) return expr(e1) & expr(e2);
				if (op == "&&") return expr(e1) == true && expr(e2) == true;
				return evalAssignOp(op, e1, e2);
			case 124: // |
				if (op.length == 1) return expr(e1) | expr(e2);
				if (op == "||") return expr(e1) == true || expr(e2) == true;
				return evalAssignOp(op, e1, e2);
			case 60: // <
				if (op.length == 1) return expr(e1) < expr(e2);
				if (op == "<=") return expr(e1) <= expr(e2);
				if (op == "<<") return expr(e1) << expr(e2);
			case 62: // >
				if (op.length == 1) return expr(e1) > expr(e2);
				if (op == ">=") return expr(e1) >= expr(e2);
				if (op == ">>") return expr(e1) >> expr(e2);
				if (op == ">>>") return expr(e1) >>> expr(e2);
			case 61: // =
				if (op.length == 1) return assign(e1, e2);
				if (op == "==") return expr(e1) == expr(e2);
			case 33: // !
				if (op == "!=") return expr(e1) != expr(e2);
			case 63: // ?
				if (op == "??") {
					var v: Dynamic = expr(e1);
					return v == null ? expr(e2) : v;
				}
				return evalAssignOp(op, e1, e2); // ??=
			case 46: // .
				if (op == "...") return new InterpIterator(this, e1, e2);
		}
		// remaining compound assignments: += -= *= /= %= &= |= ^= <<= >>= >>>= ??=
		if (op.charAt(op.length - 1) != "=")
			return error(EInvalidOp(op));
		return evalAssignOp(op, e1, e2);
	}

	/**
	 * Writes a value back to identifier \`id\`, whose local slot is \`l\` (null
	 * when the name is not a local). Shared by assignment, compound assignment
	 * and ++/-- so the routing rules live in exactly one place.
	 */
	function writeIdent(id: String, l: LocalVar, v: Dynamic): Void {
		if (l == null) {
			if (!variables.exists(id) && !staticVariables.exists(id) && !publicVariables.exists(id) && scriptObject != null) {
				if (Type.typeof(scriptObject) == TObject) {
					Reflect.setField(scriptObject, id, v);
				} else {
					if (isBypassAccessor && __instanceFields.contains(id)) {
						Reflect.setField(scriptObject, id, v);
					} else if (__instanceFields.contains(id)) {
						Reflect.setProperty(scriptObject, id, v);
					} else if (__instanceFields.contains('set_$id')) { // setter
						Reflect.getProperty(scriptObject, 'set_$id')(v);
					} else {
						setVar(id, v);
					}
				}
			} else {
				if (staticVariables.exists(id)) staticVariables.set(id, v);
				else if (publicVariables.exists(id)) publicVariables.set(id, v);
				else setVar(id, v);
			}
		} else {
			if (l.const != true) {
				l.r = v;
				// keep depth-0 map entries in sync so object field reads
				// (obj.field) see the latest value
				if (variables.exists(id)) variables.set(id, v);
				else if (publicVariables.exists(id)) publicVariables.set(id, v);
				else if (staticVariables.exists(id)) staticVariables.set(id, v);
			} else
				warn(ECustom("Cannot reassign final, for constant expression -> " + id));
		}
	}

	public function setVar(name: String, v: Dynamic) {
		if (allowStaticVariables && staticVariables.exists(name))
			staticVariables.set(name, v);
		else if (allowPublicVariables && publicVariables.exists(name))
			publicVariables.set(name, v);
		else
			variables.set(name, v);
	}

	function assign(e1: Expr, e2: Expr): Dynamic {
		var v = expr(e2);
		switch (Tools.expr(e1)) {
			case EIdent(id):
				writeIdent(id, locals.get(id), v);
			case EField(e, f, s):
				var e = expr(e);
				if (e == null)
					if (!s)
						error(EInvalidAccess(f));
					else
						return null;
				v = set(e, f, v);
			case EArray(e, index):
				var arr: Dynamic = expr(e);
				var index: Dynamic = expr(index);
				if (isMap(arr)) {
					setMapValue(arr, index, v);
				} else {
					arr[index] = v;
				}

			default:
				error(EInvalidOp("="));
		}
		return v;
	}

	static inline function applyAssignOp(op: String, a: Dynamic, b: Dynamic): Dynamic {
		return switch (op) {
			case "+=": a + b;
			case "-=": a - b;
			case "*=": a * b;
			case "/=": a / b;
			case "%=": a % b;
			case "&=": a & b;
			case "|=": a | b;
			case "^=": a ^ b;
			case "<<=": a << b;
			case ">>=": a >> b;
			case ">>>=": a >>> b;
			case "??=": a == null ? b : a;
			default: a;
		}
	}

	function evalAssignOp(op: String, e1, e2): Dynamic {
		var v;
		switch (Tools.expr(e1)) {
			case EIdent(id):
				var l = locals.get(id);
				v = applyAssignOp(op, (l == null) ? resolve(id) : l.r, expr(e2));
				writeIdent(id, l, v);
			case EField(e, f, s):
				var obj = expr(e);
				if (obj == null)
					if (!s)
						error(EInvalidAccess(f));
					else
						return null;
				v = applyAssignOp(op, get(obj, f), expr(e2));
				v = set(obj, f, v);
			case EArray(e, index):
				var arr: Dynamic = expr(e);
				var key: Dynamic = expr(index);
				if (isMap(arr)) {
					v = applyAssignOp(op, getMapValue(arr, key), expr(e2));
					setMapValue(arr, key, v);
				} else {
					v = applyAssignOp(op, arr[key], expr(e2));
					arr[key] = v;
				}
			default:
				return error(EInvalidOp(op));
		}
		return v;
	}

	function increment(e: Expr, prefix: Bool, delta: Int): Dynamic {
		#if hscriptPos
		curExpr = e;
		var e = e.e;
		#end
		switch (e) {
			case EIdent(id):
				var l = locals.get(id);
				var v: Dynamic = (l == null) ? resolve(id) : l.r;
				var stored: Dynamic;
				if (prefix) {
					v += delta;
					stored = v;
				} else
					stored = v + delta;
				writeIdent(id, l, stored);
				return v;
			case EField(e, f, s):
				var obj = expr(e);
				if (obj == null)
					if (!s)
						error(EInvalidAccess(f));
					else
						return null;
				var v: Dynamic = get(obj, f);
				if (prefix) {
					v += delta;
					set(obj, f, v);
				} else
					set(obj, f, v + delta);
				return v;
			case EArray(e, index):
				var arr: Dynamic = expr(e);
				var index: Dynamic = expr(index);
				if (isMap(arr)) {
					var v = getMapValue(arr, index);
					if (prefix) {
						v += delta;
						setMapValue(arr, index, v);
					} else {
						setMapValue(arr, index, v + delta);
					}
					return v;
				} else {
					var v = arr[index];
					if (prefix) {
						v += delta;
						arr[index] = v;
					} else
						arr[index] = v + delta;
					return v;
				}
			default:
				return error(EInvalidOp((delta > 0) ? "++" : "--"));
		}
	}

	public function execute(expr: Expr): Dynamic {
		depth = 0;
		traceDepth = 0;
		#if haxe3
		locals = new Map();
		#else
		locals = new Hash();
		#end
		declared = new Array();
		return exprReturn(expr);
	}

	public function exprReturn(e): Dynamic {
		try {
			try {
				return expr(e);
			} catch (e:Stop) {
				switch (e) {
					case SBreak:
						throw "Invalid break";
					case SContinue:
						throw "Invalid continue";
					case SReturn:
						var v = returnValue;
						returnValue = null;
						return v;
				}
			} catch (e:Error) {
				// already an hscript error (ErrorDef enum without hscriptPos,
				// Error class with it): keep the original type and position
				throw e;
			} catch (e:Dynamic) {
				// `Std.string` (not `e.toString()`): enum ErrorDef values have
				// no toString method on native targets, which used to swallow
				// every error as "Cannot call null" without -D hscriptPos
				error(ECustom(Std.string(e)));
				return null;
			}
		} catch (e:Error) {
			if (errorHandler != null)
				errorHandler(e);
			else
				throw e;
			return null;
		} catch (e:Dynamic) {
			trace(e);
		}
		return null;
	}

	public function duplicate<T>(h: #if haxe3 Map<String, T> #else Hash<T> #end) {
		#if haxe3
		return cast h.copy();
		#else
		var h2 = new Hash();
		for (k in h.keys())
			h2.set(k, h.get(k));
		return h2;
		#end
	}

	function restore(old: Int) {
		while (declared.length > old) {
			var d = declared.pop();
			locals.set(d.n, d.old);
		}
	}

	/**
	 * Structural match for an enum-constructor case pattern, binding identifier
	 * arguments (`case E.B(v):`). Compares the constructor name and parameter
	 * count, then recurses into the parameter patterns. Script enums are built
	 * from strings (`EEnum`), so the constructor name is the only type signature
	 * available at runtime.
	 */
	static function isEnumLike(v:Dynamic):Bool {
		return v != null && (Reflect.isEnumValue(v) || Std.isOfType(v, Tools.EnumValue));
	}

	function matchEnumPattern(callee:Expr, args:Array<Expr>, val:Dynamic):Bool {
		var ctorName:String = switch (Tools.expr(callee)) {
			case EField(_, f, _): f;
			case EIdent(id): id;
			default: null;
		}
		if (ctorName == null)
			return false;
		var params:Array<Dynamic>;
		if (Std.isOfType(val, Tools.EnumValue)) {
			// script enums are plain `hscript.Tools.EnumValue` objects, not Haxe
			// enums, so `Reflect.isEnumValue` is false for them
			var ev:Tools.EnumValue = cast val;
			if (ev.name != ctorName)
				return false;
			params = ev.args;
		} else {
			if (Type.enumConstructor(val) != ctorName)
				return false;
			params = Type.enumParameters(val);
		}
		if (params == null)
			params = [];
		if (params.length != args.length)
			return false;
		for (i in 0...args.length)
			if (!matchPatternArg(args[i], params[i]))
				return false;
		return true;
	}

	/**
	 * Structural match for Haxe-style switch patterns:
	 *
	 *   case [a, b]:        binds a and b when the array has exactly 2 elements
	 *   case [a, ...rest]:  binds a and rest
	 *   case {x: v}:        binds v to field x (also {x} shorthand)
	 *   case [1, _]:        literal elements and _ wildcards compose
	 *
	 * Bindings are pushed to the declared stack so the enclosing case restores
	 * them when a later alternative or guard rejects the match.
	 */
	function matchPattern(pattern: Expr, value: Dynamic): Bool {
		switch (Tools.expr(pattern)) {
			case EIdent("_"):
				return true;
			case EIdent(id):
				declared.push({n: id, old: locals.get(id)});
				locals.set(id, {r: value, const: false});
				return true;
			case EArrayDecl(items):
				if (!Std.isOfType(value, Array))
					return false;
				var arr: Array<Dynamic> = cast value;
				var i = 0;
				for (item in items) {
					switch (Tools.expr(item)) {
						case EUnop("...", _, rest):
							// [a, ...rest]: bind the remaining elements
							return matchPattern(rest, arr.slice(i));
						default:
					}
					if (i >= arr.length || !matchPattern(item, arr[i]))
						return false;
					i++;
				}
				return i == arr.length;
			case EObject(fields):
				if (value == null || !Reflect.isObject(value) || Reflect.isFunction(value))
					return false;
				for (f in fields)
					if (!matchPattern(f.e, get(value, f.name)))
						return false;
				return true;
			default:
				return expr(pattern) == value;
		}
	}

	/** Merges the fields of src into dst (object spread, see EObject). */
	static function copyObjectFields(dst: Dynamic, src: Dynamic): Void {
		if (src == null || dst == null)
			return;
		if (src is IMap) {
			var m: IMap<Dynamic, Dynamic> = cast src;
			for (k in m.keys())
				Reflect.setField(dst, Std.string(k), m.get(k));
			return;
		}
		for (name in Reflect.fields(src))
			Reflect.setField(dst, name, Reflect.field(src, name));
	}

	function matchPatternArg(pattern:Expr, value:Dynamic):Bool {
		switch (Tools.expr(pattern)) {
			case EIdent("_"):
				return true;
			case EIdent(id):
				declared.push({n: id, old: locals.get(id)});
				locals.set(id, {r: value, const: false});
				return true;
			case ECall(callee, args):
				return matchEnumPattern(callee, args, value);
			default:
				return expr(pattern) == value;
		}
	}

	public inline function error(e: #if hscriptPos ErrorDef #else Error #end, rethrow = false): Dynamic {
		#if hscriptPos
		var err = new Error(e, curExpr.pmin, curExpr.pmax, curExpr.origin, curExpr.line);
		attachTrace(err);
		if (rethrow)
			this.rethrow(err)
		else
			throw err;
		#else
		if (rethrow)
			this.rethrow(e)
		else
			throw e;
		#end
		return null;
	}

	#if hscriptPos
	/** Like error(), with an extra diagnostic hint appended by the printer. */
	function errorHint(e: ErrorDef, hint: String): Dynamic {
		var err = new Error(e, curExpr.pmin, curExpr.pmax, curExpr.origin, curExpr.line);
		err.hint = hint;
		attachTrace(err);
		throw err;
		return null;
	}
	#end

	// ------------------------- typo suggestions -------------------------

	/** Levenshtein distance, two rolling rows (only runs on the error path). */
	static function editDistance(a: String, b: String): Int {
		var la = a.length, lb = b.length;
		if (la == 0)
			return lb;
		if (lb == 0)
			return la;
		var prev: Array<Int> = [];
		var cur: Array<Int> = [];
		for (j in 0...lb + 1)
			prev.push(j);
		for (i in 1...la + 1) {
			cur[0] = i;
			for (j in 1...lb + 1) {
				var cost = a.charCodeAt(i - 1) == b.charCodeAt(j - 1) ? 0 : 1;
				var v = prev[j] + 1;
				var ins = cur[j - 1] + 1;
				if (ins < v)
					v = ins;
				var sub = prev[j - 1] + cost;
				if (sub < v)
					v = sub;
				cur[j] = v;
			}
			var swap = prev;
			prev = cur;
			cur = swap;
		}
		return prev[lb];
	}

	/** Closest in-scope name for a typo, or null when nothing is close enough. */
	function suggestName(id: String): String {
		var best: String = null;
		var bestD = 1 << 30;
		var max = id.length <= 3 ? 1 : (id.length <= 8 ? 2 : 3);
		for (k in variables.keys()) {
			if (k == null || k == id || (k.length - id.length > max) || (id.length - k.length > max))
				continue;
			var d = editDistance(id, k);
			if (d < bestD) {
				bestD = d;
				best = k;
			}
		}
		for (k in locals.keys()) {
			if (k == null || k == id || (k.length - id.length > max) || (id.length - k.length > max))
				continue;
			var d = editDistance(id, k);
			if (d < bestD) {
				bestD = d;
				best = k;
			}
		}
		if (bestD > max)
			return null;
		return best;
	}

	inline function warn(e: #if hscriptPos ErrorDef #else Error #end): Dynamic {
		#if hscriptPos var e = new Error(e, curExpr.pmin, curExpr.pmax, curExpr.origin, curExpr.line); #end
		Iris.warn(Printer.errorToString(e, showPosOnLog), #if hscriptPos posInfos() #else null #end);
		return null;
	}

	inline function rethrow(e: Dynamic) {
		#if hl
		hl.Api.rethrow(e);
		#else
		throw e;
		#end
	}

	public function resolve(id: String): Dynamic {
		if (id == null)
			return null;

		// single lookup on the hot path: a local is always a non-null struct
		var l = locals.get(id);
		if (l != null)
			return l.r;

		// One hash lookup on the hit path: Map.get returns null for a missing
		// key, so only a null result needs the second (exists) lookup. The old
		// code did exists+get - two lookups - for every variable read.
		var v = variables.get(id);
		if (v != null || variables.exists(id))
			return v;

		v = imports.get(id);
		if (v != null || imports.exists(id))
			return v;

		v = publicVariables.get(id);
		if (v != null || publicVariables.exists(id))
			return v;

		v = staticVariables.get(id);
		if (v != null || staticVariables.exists(id))
			return v;

		v = customClasses.get(id);
		if (v != null || customClasses.exists(id))
			return v;

		if (scriptObject != null) {
			if (id == "this")
				return scriptObject;
			if ((Type.typeof(scriptObject) == TObject) && Reflect.hasField(scriptObject, id))
				return Reflect.field(scriptObject, id);
			if (__instanceFields.contains(id))
				return Reflect.getProperty(scriptObject, id);
			if (__instanceFields.contains('get_$id')) // getter
				return Reflect.getProperty(scriptObject, 'get_$id')();
		}

		// wildcard imports: `import some.pkg.*;` makes `Ident` resolve to
		// `some.pkg.Ident`
		for (prefix in wildcardImports) {
			var wildcardClass:Dynamic = getOrImportClass(prefix + "." + id);
			if (wildcardClass != null)
				return wildcardClass;
		}

		// last resort: a bare class / enum name. `resolve` never consulted the
		// class registry, so scripts needed an explicit `import` just to use
		// `Math`, `Std`, `Type`, `StringTools`, ... even though the host could
		// resolve them. Only reached when every scope lookup above failed.
		var cl:Dynamic = getOrImportClass(id);
		if (cl != null)
			return cl;

		#if hscriptPos
		var suggestion = suggestName(id);
		if (suggestion != null)
			return errorHint(EUnknownVariable(id), "did you mean '" + suggestion + "'?");
		#end
		error(EUnknownVariable(id));

		return null;
	}

	public function getOrImportClass(name: String): Dynamic {
		// `Map` is an abstract: Type.resolveClass("Map") is null, yet scripts use
		// `new Map()` routinely. A dynamic-key IMap stands in for it.
		if (name == "Map")
			return DynamicMap;
		if (Iris.proxyImports.exists(name))
			return Iris.proxyImports.get(name);
		var c:Dynamic = Tools.getClass(name);
		if (c == null)
			c = Type.resolveClass(name + "_HSC");
		return c;
	}

	public function expr(e: Expr): Dynamic {
		#if hscriptPos
		curExpr = e;
		var e = e.e;
		#end
		switch (e) {
			case EIgnore(_):
			case EConst(c):
				return switch (c) {
					case CInt(v): v;
					case CFloat(f): f;
					case CString(s): s;
					#if !haxe3
					case CInt32(v): v;
					#end
				}
			case EIdent(id):
				return resolve(id);
			case EVar(n, _, v, isConst, isPublic, isStatic):
				if (depth == 0 && isStatic == true) {
					// truly shared: don't shadow with a per-instance local
					if (!staticVariables.exists(n))
						staticVariables.set(n, (v == null) ? null : expr(v));
					return null;
				}
				declared.push({n: n, old: locals.get(n)});
				locals.set(n, {r: (v == null) ? null : expr(v), const: isConst});
				if (depth == 0) {
					(isPublic ? publicVariables : variables).set(n, locals.get(n).r);
				}
				return null;
			case EParent(e):
				return expr(e);
			case EBlock(exprs):
				var old = declared.length;
				var v = null;
				for (e in exprs)
					v = expr(e);
				restore(old);
				return v;
			case EField(e, f, true):
				var e = expr(e);
				if (e == null)
					return null;
				return get(e, f);
			case EField(e, f, false):
				return get(expr(e), f);
			case EBinop(op, e1, e2):
				return binop(op, e1, e2);
			case EUnop(op, prefix, e):
				return switch (op) {
					case "!":
						expr(e) != true;
					case "-":
						-expr(e);
					case "++":
						increment(e, prefix, 1);
					case "--":
						increment(e, prefix, -1);
					case "~":
						#if (neko && !haxe3)
						haxe.Int32.complement(expr(e));
						#else
						~expr(e);
						#end
					default:
						error(EInvalidOp(op));
						null;
				}
			case ECall(e, params):
				var args = new Array();
				for (p in params)
					switch (Tools.expr(p)) {
						case EUnop("...", _, spread):
							// spread call: `f(...arr)`
							var v = expr(spread);
							if (v == null)
								error(EInvalidAccess("..."));
							var arr:Array<Dynamic> = cast v;
							for (x in arr)
								args.push(x);
						default:
							args.push(expr(p));
					}

				switch (Tools.expr(e)) {
					case EField(e, f, s):
						var obj = expr(e);
						if (obj == null) {
							if (!s)
								error(EInvalidAccess(f));
							return null;
						}
						return fcall(obj, f, args);
					default:
						var callee:Dynamic = expr(e);
						if (callee is CustomClassHandler.ScriptSuper) {
							// Haxe-style `super(...)` inside a constructor: `super` is a
							// scope, not a function, so run the parent level's own `new`.
							var superCtor:Dynamic = cast(callee, CustomClassHandler.ScriptSuper).findMethod("new");
							return superCtor == null ? null : call(null, superCtor, args);
						}
						return call(null, callee, args);
				}
			case EIf(econd, e1, e2):
				return if (expr(econd) == true) expr(e1) else if (e2 == null) null else expr(e2);
			case EWhile(econd, e):
				whileLoop(econd, e);
				return null;
			case EDoWhile(econd, e):
				doWhileLoop(econd, e);
				return null;
			case EFor(v, it, e, ithv):
				forLoop(v, it, e, ithv);
				return null;
			case EBreak:
				throw SBreak;
			case EContinue:
				throw SContinue;
			case EReturn(e):
				returnValue = e == null ? null : expr(e);
				throw SReturn;
			case EImport(v, as):
				final aliasStr = (as != null ? " named " + as : ""); // for errors
				if (Iris.blocklistImports.contains(v) || importBlocklist.contains(v)) {
					error(ECustom("You cannot add a blacklisted import, for class " + v + aliasStr));
					return null;
				}

				// `import some.pkg.*;` is encoded by the parser as a trailing ".*" in
				// `v` (the AST shape stays EImport(v, as)). Register the package prefix
				// so later identifiers resolve as `prefix + "." + ident`.
				//
				// INTENDED BEHAVIOUR (README limitations): the prefix is NOT validated
				// here. A Haxe runtime cannot enumerate the classes of a package, so
				// `import does.not.exist.*;` is accepted and only fails - as a normal
				// EUnknownVariable - if an identifier that needs it is actually used.
				// Do not "fix" this by erroring eagerly. Pinned by TestRuntimeExt.
				if (v != null && v.length > 2 && v.substr(v.length - 2) == ".*") {
					var prefix = v.substr(0, v.length - 2);
					if (prefix.length == 0)
						return error(ECustom("Import" + aliasStr + " of class " + v + " could not be added"));
					if (wildcardImports.indexOf(prefix) < 0)
						wildcardImports.push(prefix);
					return null;
				}

				var n = Tools.last(v.split("."));
				if (imports.exists(n))
					return imports.get(n);

				var c: Dynamic = getOrImportClass(getImportRedirect(v));
				if (c == null) {
					// let the host (engine) try to load the module (e.g. another
					// script file) before giving up
					if (importFailedCallback != null && importFailedCallback(v.split(".")))
						return null;
					// if it's still null then warn instead of crashing
					return warn(ECustom("Import" + aliasStr + " of class " + v + " could not be added"));
				} else {
					imports.set(n, c);
					if (as != null)
						imports.set(as, c);
					// resembles older haxe versions where you could use both the alias and the import
					// for all the "Colour" enjoyers :D
				}
				return null; // yeah. -Crow

			case EFunction(params, fexpr, name, _, isPublic, isStatic, isOverride):
				var capturedLocals = duplicate(locals);
				var me = this;
				#if hscriptPos
				var frameOrigin = curExpr.origin;
				var frameLine = curExpr.line;
				#end
				var frameName = (name == null) ? "<anonymous>" : name;
				var hasOpt = false, minParams = 0;
				var hasRest = false;
				for (p in params)
					if (p.rest)
						hasRest = true;
					else if (p.opt || p.value != null)
						hasOpt = true;
					else
						minParams++;
				var f = function(args: Array<Dynamic>) {
					if (!hasRest && ((args == null) ? 0 : args.length) != params.length) {
						if (args.length < minParams) {
							var str = "Invalid number of parameters. Got " + args.length + ", required " + minParams;
							if (name != null)
								str += " for function '" + name + "'";
							error(ECustom(str));
						}
						// make sure mandatory args are forced
						var args2 = [];
						var extraParams = args.length - minParams;
						var pos = 0;
						for (p in params)
							if (p.opt || p.value != null) {
								if (extraParams > 0) {
									args2.push(args[pos++]);
									extraParams--;
								} else {
									// apply the parsed default value
									var defVal:Dynamic = null;
									if (p.value != null)
										defVal = expr(p.value);
									args2.push(defVal);
								}
							} else
								args2.push(args[pos++]);
						args = args2;
					}
					var old = me.locals, depth = me.depth;
					me.depth++;
					me.locals = me.duplicate(capturedLocals);
					var restIndex = -1;
					for (i in 0...params.length)
						if (params[i].rest)
							restIndex = i;
					if (restIndex >= 0) {
						// `function f(a, ...rest)` — pack the remaining args
						var restArgs = [];
						for (i in restIndex...args.length)
							restArgs.push(args[i]);
						for (i in 0...params.length)
							me.locals.set(params[i].name, {r: i == restIndex ? restArgs : args[i], const: false});
					} else {
						for (i in 0...params.length)
							me.locals.set(params[i].name, {r: args[i], const: false});
					}
					var r = null;
					var oldDecl = declared.length;
					#if hscriptPos
					me.pushFrame(frameName, frameLine, frameOrigin);
					#end
					if (inTry)
						try {
							r = me.exprReturn(fexpr);
						} catch (e:Dynamic) {
							#if hscriptPos
							me.popFrame();
							#end
							me.locals = old;
							me.depth = depth;
							#if neko
							neko.Lib.rethrow(e);
							#else
							throw e;
							#end
						}
					else
						r = me.exprReturn(fexpr);
					#if hscriptPos
					me.popFrame();
					#end
					restore(oldDecl);
					me.locals = old;
					me.depth = depth;
					return r;
				};
				var f = Reflect.makeVarArgs(f);
				if (name != null) {
					if (depth == 0) {
						// global function
						((isStatic && allowStaticVariables) ? staticVariables : ((isPublic && allowPublicVariables) ? publicVariables : variables)).set(name, f);
					} else {
						// function-in-function is a local function
						declared.push({n: name, old: locals.get(name)});
						var ref: LocalVar = {r: f, const: false};
						locals.set(name, ref);
						capturedLocals.set(name, ref); // allow self-recursion
					}
				}
				return f;
			case EArrayDecl(arr):
				if (arr.length > 0 && Tools.expr(arr[0]).match(EBinop("=>", _))) {
					var isAllString: Bool = true;
					var isAllInt: Bool = true;
					var isAllObject: Bool = true;
					var isAllEnum: Bool = true;
					var keys: Array<Dynamic> = [];
					var values: Array<Dynamic> = [];
					for (e in arr) {
						switch (Tools.expr(e)) {
							case EBinop("=>", eKey, eValue): {
									var key: Dynamic = expr(eKey);
									var value: Dynamic = expr(eValue);
									isAllString = isAllString && (key is String);
									isAllInt = isAllInt && (key is Int);
									isAllObject = isAllObject && Reflect.isObject(key);
									isAllEnum = isAllEnum && Reflect.isEnumValue(key);
									keys.push(key);
									values.push(value);
								}
							default: throw("=> expected");
						}
					}
					var map: Dynamic = {
						if (isAllInt)
							new haxe.ds.IntMap<Dynamic>();
						else if (isAllString)
							new haxe.ds.StringMap<Dynamic>();
						else if (isAllEnum)
							new haxe.ds.EnumValueMap<Dynamic, Dynamic>();
						else if (isAllObject)
							new haxe.ds.ObjectMap<Dynamic, Dynamic>();
						else
							throw 'Inconsistent key types';
					}
					for (n in 0...keys.length) {
						setMapValue(map, keys[n], values[n]);
					}
					return map;
				} else {
					var a = new Array();
					for (e in arr) {
						switch (Tools.expr(e)) {
							case EUnop("...", _, spreadArg):
								// array spread: [ ...xs, 1 ]
								var sv: Dynamic = expr(spreadArg);
								if (sv != null) {
									var items: Array<Dynamic> = cast sv;
									for (x in items)
										a.push(x);
								}
							default:
								a.push(expr(e));
						}
					}
					return a;
				}
			case EArray(e, index):
				var arr: Dynamic = expr(e);
				var index: Dynamic = expr(index);
				if (isMap(arr)) {
					return getMapValue(arr, index);
				} else {
					return arr[index];
				}
			case ENew(cl, params):
				var a = new Array();
				for (e in params)
					a.push(expr(e));
				return cnew(cl, a);
			case EThrow(e):
				throw expr(e);
			case ETry(e, n, _, ecatch):
				var old = declared.length;
				var oldTry = inTry;
				var oldTrace = traceDepth;
				try {
					inTry = true;
					var v: Dynamic = expr(e);
					restore(old);
					inTry = oldTry;
					return v;
				} catch (err:Stop) {
					inTry = oldTry;
					throw err;
				} catch (err:Dynamic) {
					// restore vars
					restore(old);
					inTry = oldTry;
					traceDepth = oldTrace;
					// declare 'v'
					declared.push({n: n, old: locals.get(n)});
					locals.set(n, {r: err, const: false});
					var v: Dynamic = expr(ecatch);
					restore(old);
					return v;
				}
			case EObject(fl):
				var o = {};
				for (f in fl)
					if (f.name == Tools.OBJECT_SPREAD)
						copyObjectFields(o, expr(f.e));
					else
						set(o, f.name, expr(f.e));
				return o;
			case ETernary(econd, e1, e2):
				return if (expr(econd) == true) expr(e1) else expr(e2);
			case ESwitch(e, cases, def):
				// Frozen or-pattern / binding rules (pinned by TestRuntimeExt):
				//  * alternatives in `c.values` are tried strictly left to right;
				//  * an identifier alternative (`case v:`) binds the switched value
				//    and matches ANY value, so `case v | 5:` always matches via v;
				//  * once ONE alternative has matched, `ifExpr` is evaluated with only
				//    that alternative's bindings in scope (e.g. `case 5 | x if (x == 5)`
				//    raises Unknown variable: x because the literal matched first);
				//  * bindings made by a case are restored when the case does not
				//    match, so they never leak into later cases or the outer scope.
				var val: Dynamic = expr(e);
				var match = false;
				for (c in cases) {
					var old = declared.length;
					var caseMatched = false;
					for (v in c.values) {
						var ve = Tools.expr(v);
						var isWildcard = Type.enumEq(ve, EIdent("_"));
						var valueMatched = false;
						if (isWildcard) {
							// A wildcard matches any value: an unguarded `case _:` was
							// hoisted into `def` by the parser, so a wildcard in `values`
							// is an or-pattern alternative or a guarded wildcard.
							valueMatched = true;
						} else switch (ve) {
							case EIdent(id):
								// `case x:` binds x to the switched value
								declared.push({n: id, old: locals.get(id)});
								locals.set(id, {r: val, const: false});
								valueMatched = true;
							case ECall(callee, cargs) if (isEnumLike(val)):
								// `case E.B(v):` (and or-patterns of them): structural match
								// that binds the constructor's parameters, instead of trying
								// to evaluate the pattern as an expression.
								valueMatched = matchEnumPattern(callee, cargs, val);
							case EArrayDecl(_), EObject(_):
								// structural patterns: case [a, b]: / case {x: v}:
								valueMatched = matchPattern(v, val);
							default:
								valueMatched = expr(v) == val;
						}
						if (valueMatched && (c.ifExpr == null || expr(c.ifExpr) == true)) {
							caseMatched = true;
							break;
						}
					}
					if (caseMatched) {
						val = expr(c.expr);
						restore(old);
						match = true;
						break;
					}
					restore(old);
				}
				if (!match)
					val = def == null ? null : expr(def);
				return val;
			case EMeta(_, _, e):
				return expr(e);
			case ECheckType(e, t):
				var v = expr(e);
				// best-effort checked cast (`cast (v, T)`): validate only when
				// the target resolves to a real class/enum; primitives, Dynamic
				// and script-defined types are always accepted
				switch (t) {
					case CTPath(p):
						var target = p.pack.concat([p.name]).join(".");
						var cl = Tools.getClass(target);
						if (cl != null && v != null && !Std.isOfType(v, cl))
							error(ECustom("Cast error: " + Std.string(v) + " cannot be cast to " + target));
					default:
				}
				return v;
			case EClass(name, fields, extend, interfaces):
				if (customClasses.exists(name))
					error(EAlreadyExistingClass(name));

				inline function importVar(thing:String):String {
					if (thing == null)
						return null;
					var variable:Dynamic = variables.exists(thing) ? variables.get(thing) : null;
					if (variable != null && Std.isOfType(variable, Class))
						return Type.getClassName(cast variable);
					return thing;
				}
				customClasses.set(name, new CustomClassHandler(this, name, fields, importVar(extend), [for (i in interfaces) importVar(i)]));

				// evaluate static members once at declaration time so
				// `ClassName.staticField` / `ClassName.staticFunc()` work
				// without instantiating the class (Haxe semantics)
				{
					var handler = customClasses.get(name);
					var sInterp = new Interp();
					sInterp.errorHandler = errorHandler;
					sInterp.importFailedCallback = importFailedCallback;
					sInterp.allowStaticVariables = allowStaticVariables;
					sInterp.allowPublicVariables = allowPublicVariables;
					sInterp.importEnabled = importEnabled;
					sInterp.staticVariables = staticVariables;
					sInterp.customClasses = customClasses;
					sInterp.variables = variables;
					sInterp.publicVariables = publicVariables;
					sInterp.imports = imports;
					#if haxe3
					sInterp.locals = new Map();
					#else
					sInterp.locals = new Hash();
					#end
					for (fexpr in fields) {
						switch (Tools.expr(fexpr)) {
							case EVar(n, _, _, _, _, true):
								sInterp.exprReturn(fexpr);
								if (staticVariables.exists(n))
									handler.staticFields.set(n, staticVariables.get(n));
							case EFunction(_, _, fname, _, isPublic, true, _):
								sInterp.exprReturn(fexpr);
								if (fname != null) {
									var f:Dynamic = null;
									if (staticVariables.exists(fname))
										f = staticVariables.get(fname);
									else if (allowPublicVariables && publicVariables.exists(fname))
										f = publicVariables.get(fname);
									else if (variables.exists(fname))
										f = variables.get(fname);
									if (f != null)
										handler.staticFields.set(fname, f);
								}
							default:
						}
					}
				}
				return null;
			case EEnum(enumName, fields):
				var obj = {};
				for (index => field in fields) {
					switch (field) {
						case ESimple(name):
							Reflect.setField(obj, name, new EnumValue(enumName, name, index, null));
						case EConstructor(name, params):
							var hasOpt = false, minParams = 0;
							for (p in params)
								if (p.opt)
									hasOpt = true;
								else
									minParams++;
							var f = function(args: Array<Dynamic>) {
								if (((args == null) ? 0 : args.length) != params.length) {
									if (args.length < minParams) {
										var str = "Invalid number of parameters. Got " + args.length + ", required " + minParams;
										if (enumName != null)
											str += " for enum '" + enumName + "'";
										error(ECustom(str));
									}
									// make sure mandatory args are forced
									var args2 = [];
									var extraParams = args.length - minParams;
									var pos = 0;
									for (p in params)
										if (p.opt) {
											if (extraParams > 0) {
												args2.push(args[pos++]);
												extraParams--;
											} else
												args2.push(null);
										} else
											args2.push(args[pos++]);
									args = args2;
								}
								return new EnumValue(enumName, name, index, args);
							};
							var f = Reflect.makeVarArgs(f);

							Reflect.setField(obj, name, f);
					}
				}

				variables.set(enumName, obj);
			case EDirectValue(value):
				return value;
			case EUsing(name):
				useUsing(name);
		}
		return null;
	}

	/**
	 * True when evaluating `e` may throw one of the control-flow signals a loop
	 * has to intercept (`break` / `continue` / `return`). Function, class and
	 * enum literals are their own execution unit, so a `return` inside one of
	 * them never reaches the enclosing loop and the scan stops there.
	 */
	static function anySignal(list: Array<Expr>): Bool {
		if (list == null)
			return false;
		for (x in list)
			if (maySignal(x))
				return true;
		return false;
	}

	static function anySwitchSignal(cases: Array<SwitchCase>): Bool {
		if (cases == null)
			return false;
		for (c in cases) {
			if (anySignal(c.values) || maySignal(c.expr))
				return true;
			if (c.ifExpr != null && maySignal(c.ifExpr))
				return true;
		}
		return false;
	}

	static function anyFieldSignal(fields: Array<ObjectDecl>): Bool {
		if (fields == null)
			return false;
		for (f in fields)
			if (maySignal(f.e))
				return true;
		return false;
	}

	static function maySignal(e: Null<Expr>): Bool {
		if (e == null)
			return false;
		return switch (e.e) {
			case EBreak, EContinue, EReturn(_): true;
			case EFunction(_, _, _, _, _, _, _), EClass(_, _, _, _), EEnum(_, _): false;
			case EConst(_), EIdent(_), EImport(_, _), EDirectValue(_), EUsing(_), EIgnore(_): false;
			case EParent(x), EMeta(_, _, x), ECheckType(x, _), EUnop(_, _, x), EThrow(x),
				EVar(_, _, x, _, _, _): maySignal(x);
			case EBlock(l): anySignal(l);
			case EField(x, _, _): maySignal(x);
			case EBinop(_, a, b), EArray(a, b), EWhile(a, b), EDoWhile(a, b), EFor(_, a, b, _):
				maySignal(a) || maySignal(b);
			case ECall(callee, args): maySignal(callee) || anySignal(args);
			case EIf(c, a, b): maySignal(c) || maySignal(a) || maySignal(b);
			case EArrayDecl(l): anySignal(l);
			case ENew(_, params): anySignal(params);
			case ETry(x, _, _, c): maySignal(x) || maySignal(c);
			case EObject(fl): anyFieldSignal(fl);
			case ETernary(c, a, b): maySignal(c) || maySignal(a) || maySignal(b);
			case ESwitch(x, cases, def): maySignal(x) || anySwitchSignal(cases) || maySignal(def);
		}
	}

	// Memoised `maySignal` per body expression. The AST is shared between
	// interpreters, so the cache must not live on the AST itself; one entry per
	// loop body keeps it tiny.
	var signalCache: haxe.ds.ObjectMap<Dynamic, Bool>;

	inline function loopSignals(body: Expr): Bool {
		var cache = signalCache;
		if (cache == null)
			cache = signalCache = new haxe.ds.ObjectMap();
		var cached = cache.get(body);
		if (cached != null)
			return cached;
		var r = maySignal(body);
		cache.set(body, r);
		return r;
	}

	function doWhileLoop(econd, e) {
		var old = declared.length;
		if (loopSignals(e)) {
			do {
				try {
					expr(e);
				} catch (err:Stop) {
					switch (err) {
						case SContinue:
						case SBreak:
							break;
						case SReturn:
							throw err;
					}
				}
			} while (expr(econd) == true);
		} else {
			// Nothing in the body can throw a Stop signal, so catching one per
			// iteration is pure overhead (a setjmp per iteration on hxcpp).
			do {
				expr(e);
			} while (expr(econd) == true);
		}
		restore(old);
	}

	function whileLoop(econd, e) {
		var old = declared.length;
		if (loopSignals(e)) {
			while (expr(econd) == true) {
				try {
					expr(e);
				} catch (err:Stop) {
					switch (err) {
						case SContinue:
						case SBreak:
							break;
						case SReturn:
							throw err;
					}
				}
			}
		} else {
			while (expr(econd) == true)
				expr(e);
		}
		restore(old);
	}

	function makeIterator(v: Dynamic, ?allowKeyValue = false): Iterator<Dynamic> {
		#if ((flash && !flash9) || (php && !php7 && haxe_ver < '4.0.0'))
		if (v.iterator != null)
			v = v.iterator();
		#else
		if (allowKeyValue) {
			try
				v = v.keyValueIterator()
			catch (e:Dynamic) {};
		}
		if (v.hasNext == null || v.next == null) {
			try
				v = v.iterator()
			catch (e:Dynamic) {};
		}
		#end
		if (v.hasNext == null || v.next == null)
			error(EInvalidIterator(v));
		return v;
	}

	function forLoop(n, it, e, ?ithv:String) {
		var isKeyValue = ithv != null;
		var old = declared.length;
		declared.push({n: n, old: locals.get(n)});
		if (isKeyValue)
			declared.push({n: ithv, old: locals.get(ithv)});
		var it = makeIterator(expr(it), isKeyValue);
		var _itHasNext = it.hasNext;
		var _itNext = it.next;
		if (loopSignals(e)) {
			while (_itHasNext()) {
				var next = _itNext();
				if (isKeyValue)
					locals.set(ithv, {r: next.key, const: false});
				locals.set(n, {r: isKeyValue ? next.value : next, const: false});
				try {
					expr(e);
				} catch (err:Stop) {
					switch (err) {
						case SContinue:
						case SBreak:
							break;
						case SReturn:
							throw err;
					}
				}
			}
		} else {
			while (_itHasNext()) {
				var next = _itNext();
				if (isKeyValue)
					locals.set(ithv, {r: next.key, const: false});
				locals.set(n, {r: isKeyValue ? next.value : next, const: false});
				expr(e);
			}
		}
		restore(old);
	}

	inline function isMap(o: Dynamic): Bool {
		return (o is IMap);
	}

	inline function getMapValue(map: Dynamic, key: Dynamic): Dynamic {
		return cast(map, IMap<Dynamic, Dynamic>).get(key);
	}

	inline function setMapValue(map: Dynamic, key: Dynamic, value: Dynamic): Void {
		cast(map, IMap<Dynamic, Dynamic>).set(key, value);
	}

	function get(o: Dynamic, f: String): Dynamic {
		if (o == null)
			error(EInvalidAccess(f));

		// script-class instances (hscript-plus style dynamic inheritance)
		if (DynamicClass.isDynamicObject(o)) {
			var v:Dynamic = DynamicClass.getField(o, f);
			return v == null ? Reflect.field(o, f) : v;
		}

		return {
			var redirect:Dynamic->String->Dynamic = null;
			var cls = Type.getClass(o);
			var cl:Null<String> = switch (Type.typeof(o)) {
				case TNull: "Null";
				case TInt: "Int";
				case TFloat: "Float";
				case TBool: "Bool";
				case _: cls != null ? Type.getClassName(cls) : null;
			};
			if (cl != null && getRedirects.exists(cl) && (redirect = getRedirects[cl]) != null) {
				return redirect(o, f);
			} else if (o is IHScriptCustomBehaviour) {
				var obj = cast(o, IHScriptCustomBehaviour);
				return obj.hget(f);
			} else {
				#if php
				// https://github.com/HaxeFoundation/haxe/issues/4915
				try {
					return Reflect.getProperty(o, f);
				} catch (e:Dynamic) {
					return Reflect.field(o, f);
				}
				#else
				var v = null;
				if (isBypassAccessor) {
					if ((v = Reflect.field(o, f)) == null && cls != null)
						v = Reflect.field(cls, f);
				}
				if (v == null) {
					if ((v = Reflect.getProperty(o, f)) == null && cls != null)
						v = Reflect.getProperty(cls, f);
				}
				return v;
				#end
			}
		}
	}

	function set(o: Dynamic, f: String, v: Dynamic): Dynamic {
		if (o == null)
			error(EInvalidAccess(f));

		if (DynamicClass.isDynamicObject(o))
			return DynamicClass.setField(o, f, v);

		var redirect:Dynamic->String->Dynamic->Dynamic = null;
		var cls = Type.getClass(o);
		var cl:Null<String> = switch (Type.typeof(o)) {
			case TNull: "Null";
			case TInt: "Int";
			case TFloat: "Float";
			case TBool: "Bool";
			case _: cls != null ? Type.getClassName(cls) : null;
		};
		if (cl != null && setRedirects.exists(cl) && (redirect = setRedirects[cl]) != null)
			redirect(o, f, v);
		else if (o is IHScriptCustomBehaviour) {
			var obj = cast(o, IHScriptCustomBehaviour);
			obj.hset(f, v);
		} else if (isBypassAccessor) {
			Reflect.setField(o, f, v);
		} else {
			Reflect.setProperty(o, f, v);
		}
		return v;
	}

	/**
	 * Meant for people to add their own usings.
	**/
	function registerUsingLocal(name: String, call: UsingCall): UsingEntry {
		var entry = new UsingEntry(name, call);
		usings.push(entry);
		return entry;
	}

	function useUsing(name: String): Void {
		for (us in Iris.registeredUsingEntries) {
			if (us.name == name) {
				if (usings.indexOf(us) == -1)
					usings.push(us);
				return;
			}
		}

		var cls = Tools.getClass(name);
		if (cls != null) {
			var fieldName = '__irisUsing_' + StringTools.replace(name, ".", "_");
			if (Reflect.hasField(cls, fieldName)) {
				var fields = Reflect.field(cls, fieldName);
				if (fields == null)
					return;

				var entry = new UsingEntry(name, function(o: Dynamic, f: String, args: Array<Dynamic>): Dynamic {
					if (!fields.exists(f))
						return null;
					var type: ValueType = Type.typeof(o);
					var valueType: ValueType = fields.get(f);

					// If we figure out a better way to get the types as the real ValueType, we can use this instead
					// if (Type.enumEq(valueType, type))
					//	return Reflect.callMethod(cls, Reflect.field(cls, f), [o].concat(args));

					var canCall = valueType == null ? true : switch (valueType) {
						case TEnum(null):
							type.match(TEnum(_));
						case TClass(null):
							type.match(TClass(_));
						case TClass(IMap): // if we don't check maps like this, it just doesn't work
							type.match(TClass(IMap) | TClass(haxe.ds.ObjectMap) | TClass(haxe.ds.StringMap) | TClass(haxe.ds.IntMap) | TClass(haxe.ds.EnumValueMap));
						default:
							Type.enumEq(type, valueType);
					}

					return canCall ? Reflect.callMethod(cls, Reflect.field(cls, f), [o].concat(args)) : null;
				});

				#if IRIS_DEBUG
				trace("Registered macro based using entry for " + name);
				#end

				Iris.registeredUsingEntries.push(entry);
				usings.push(entry);
				return;
			}

			// Use reflection to generate the using entry
			var entry = new UsingEntry(name, function(o: Dynamic, f: String, args: Array<Dynamic>): Dynamic {
				if (!Reflect.hasField(cls, f))
					return null;
				var field = Reflect.field(cls, f);
				if (!Reflect.isFunction(field))
					return null;

				// invalid if the function has no arguments
				var totalArgs = Tools.argCount(field);
				if (totalArgs == 0)
					return null;

				// todo make it check if the first argument is the correct type

				return Reflect.callMethod(cls, field, [o].concat(args));
			});

			#if IRIS_DEBUG
			trace("Registered reflection based using entry for " + name);
			#end

			Iris.registeredUsingEntries.push(entry);
			usings.push(entry);
			return;
		}
		warn(ECustom("Unknown using class " + name));
	}

	/**
	 * List of components that allow using static methods on objects.
	 * This only works if you do
	 * ```haxe
	 * var result = "Hello ".trim();
	 * ```
	 * and not
	 * ```haxe
	 * var trim = "Hello ".trim;
	 * var result = trim();
	 * ```
	 */
	var usings: Array<UsingEntry> = [];

	function fcall(o: Dynamic, f: String, args: Array<Dynamic>): Dynamic {
		for (_using in usings) {
			var v = _using.call(o, f, args);
			if (v != null)
				return v;
		}
		if (o == CustomClassHandler.staticHandler && scriptObject != null)
			return Reflect.callMethod(scriptObject, Reflect.field(scriptObject, "_HX_SUPER__" + f), args);
		return call(o, get(o, f), args);
	}

	function call(o: Dynamic, f: Dynamic, args: Array<Dynamic>): Dynamic {
		if (f == CustomClassHandler.staticHandler)
			return null;
		return Reflect.callMethod(o, f, args);
	}

	function cnew(cl: String, args: Array<Dynamic>): Dynamic {
		var c:Dynamic = null;
		try {
			c = resolve(cl);
		} catch (e:Dynamic) {
			c = null;
		}
		if (c == null)
			c = Type.resolveClass(cl);
		if (c == null)
			c = Type.resolveClass(cl + "_HSX");
		if (c == null)
			error(ECustom("Class not found: " + cl));
		return (c is IHScriptCustomConstructor) ? cast(c, IHScriptCustomConstructor).hnew(args) : Type.createInstance(c, args);
	}
}

/**
 * Dynamic-key map used for `new Map()` inside scripts.
 *
 * Haxe picks a concrete `IMap` implementation from the key type, but hscript
 * only sees the erased `ENew("Map")`, and `Type.resolveClass("Map")` is null
 * because `Map` is an abstract. This single implementation accepts any key; keys
 * are compared with `==` (value equality for primitives, reference for objects).
 */
class DynamicMap implements IMap<Dynamic, Dynamic> {
	var keyArr:Array<Dynamic> = [];
	var valArr:Array<Dynamic> = [];

	public function new() {}

	public function get(key:Dynamic):Null<Dynamic> {
		for (i in 0...keyArr.length)
			if (keyArr[i] == key)
				return valArr[i];
		return null;
	}

	public function set(key:Dynamic, value:Dynamic):Void {
		for (i in 0...keyArr.length)
			if (keyArr[i] == key) {
				valArr[i] = value;
				return;
			}
		keyArr.push(key);
		valArr.push(value);
	}

	public function exists(key:Dynamic):Bool {
		for (k in keyArr)
			if (k == key)
				return true;
		return false;
	}

	public function remove(key:Dynamic):Bool {
		for (i in 0...keyArr.length)
			if (keyArr[i] == key) {
				keyArr.splice(i, 1);
				valArr.splice(i, 1);
				return true;
			}
		return false;
	}

	public function clear():Void {
		keyArr = [];
		valArr = [];
	}

	public function keys():Iterator<Dynamic> return keyArr.iterator();

	public function iterator():Iterator<Dynamic> return valArr.iterator();

	public function keyValueIterator():KeyValueIterator<Dynamic, Dynamic> return new haxe.iterators.MapKeyValueIterator(this);

	public function copy():IMap<Dynamic, Dynamic> {
		var out = new DynamicMap();
		for (i in 0...keyArr.length) {
			out.keyArr.push(keyArr[i]);
			out.valArr.push(valArr[i]);
		}
		return out;
	}

	public function toString():String {
		var parts = [];
		for (i in 0...keyArr.length)
			parts.push(Std.string(keyArr[i]) + " => " + Std.string(valArr[i]));
		return "{" + parts.join(", ") + "}";
	}
}
