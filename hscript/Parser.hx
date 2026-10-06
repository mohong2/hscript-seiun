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

import hscript.Expr;
import hscript.Tools;

using StringTools;

enum Token {
	TEof;
	TConst(c: Const);
	TId(s: String);
	TOp(s: String);
	TPOpen;
	TPClose;
	TBrOpen;
	TBrClose;
	TDot;
	TComma;
	TSemicolon;
	TBkOpen;
	TBkClose;
	TQuestion;
	TDoubleDot;
	TMeta(s: String);
	TPrepro(s: String);
	TQuestionDot;
	// interpolated string literal: parts are String chunks and Expr pieces
	TInterp(parts: Array<Dynamic>);
}

#if hscriptPos
class TokenPos {
	public var t: Token;
	public var min: Int;
	public var max: Int;

	public function new(t, min, max) {
		this.t = t;
		this.min = min;
		this.max = max;
	}
}
#end

class Parser {

	// config / variables
	public var line: Int;
	public var opChars: String;
	public var identChars: String;
	#if haxe3
	public var opPriority: Map<String, Int>;
	public var opRightAssoc: Map<String, Bool>;
	#else
	public var opPriority: Hash<Int>;
	public var opRightAssoc: Hash<Bool>;
	#end

	/**
		allows to check for #if / #else in code
	**/
	public var preprocessorValues: Map<String, Dynamic> = new Map();
	/**
	 * Set by `readString` when a string literal contains `$` interpolation;
	 * the tokenizer then returns `TInterp(parts)` instead of a plain CString.
	 * Parts are alternating String chunks and parsed Expr pieces.
	 */
	var interpParts: Array<Dynamic> = null;

	/**
		Compatibility alias for the historical (misspelled) iris field name.
		New code should use `preprocessorValues`.
	**/
	public var preprocesorValues(get, set): Map<String, Dynamic>;
	inline function get_preprocesorValues(): Map<String, Dynamic> return preprocessorValues;
	inline function set_preprocesorValues(v: Map<String, Dynamic>): Map<String, Dynamic> return preprocessorValues = v;

	/**
		activate JSON compatiblity
	**/
	public var allowJSON: Bool;

	/**
		allow types declarations
	**/
	public var allowTypes: Bool;

	/**
		allow haxe metadata declarations
	**/
	public var allowMetadata: Bool;

	/**
		resume from parsing errors (when parsing incomplete code, during completion for example)
	**/
	public var resumeErrors: Bool;

	/*
		package name, set when using "package;" in your script.
	 */
	public var packageName: String = null;

	// access-modifier state for class/field parsing (hscript-improved style)
	var nextIsPublic:Bool = false;
	var nextIsStatic:Bool = false;
	var nextIsOverride:Bool = false;

	// implementation
	var input: String;
	var readPos: Int;

	var char: Int;
	var ops: Array<Bool>;
	var idents: Array<Bool>;
	var uid: Int = 0;

	#if hscriptPos
	var origin: String;
	var tokenMin: Int;
	var tokenMax: Int;
	var oldTokenMin: Int;
	var oldTokenMax: Int;
	// PERF: the pending-token stack used to be a List/Array of freshly
	// allocated TokenPos objects. It is now three parallel arrays plus an
	// index, which removes one TokenPos allocation per pushed token.
	var tokStack: Array<Token>;
	var tokMinStack: Array<Int>;
	var tokMaxStack: Array<Int>;
	var tokDepth: Int;
	#else
	static inline var p1 = 0;
	static inline var tokenMin = 0;
	static inline var tokenMax = 0;

	#if haxe3
	var tokens: haxe.ds.GenericStack<Token>;
	#else
	var tokens: haxe.FastList<Token>;
	#end
	#end
	public function new() {
		line = 1;
		opChars = "+*/-=!><&|^%~";
		identChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";
		var priorities = [
			["%"],
			["*", "/"],
			["+", "-"],
			["<<", ">>", ">>>"],
			["|", "&", "^"],
			["==", "!=", ">", "<", ">=", "<="],
			["..."],
			["&&"],
			["||"],
			[
				"=",
				"+=",
				"-=",
				"*=",
				"/=",
				"%=",
				"??" + "=",
				"<<=",
				">>=",
				">>>=",
				"|=",
				"&=",
				"^=",
				"=>"
			],
			["->"]
		];
		#if haxe3
		opPriority = new Map();
		opRightAssoc = new Map();
		#else
		opPriority = new Hash();
		opRightAssoc = new Hash();
		#end
		for (i in 0...priorities.length)
			for (x in priorities[i]) {
				opPriority.set(x, i);
				if (i == 9)
					opRightAssoc.set(x, true);
			}
		for (x in ["!", "++", "--", "~"]) // unary "-" handled in parser directly!
			opPriority.set(x, x == "++" || x == "--" ? -1 : -2);
	}

	// ------------------------ PERF lookup tables ------------------------

	/**
		Names recognized by parseStructure. This Map is a cheap pre-filter: the
		29-case string switch behind it costs about twice as much, and the
		overwhelming majority of identifiers are not statement keywords.
	**/
	static var keywordNames: Map<String, Bool>;

	static function isKeywordName(id: String): Bool {
		var m = keywordNames;
		if (m == null) {
			m = new Map();
			for (k in [
				"if", "override", "static", "public", "private", "dynamic", "var", "final", "while", "do", "for",
				"break", "continue", "else", "inline", "function", "return", "new", "throw", "cast", "untyped",
				"try", "switch", "import", "class", "enum", "typedef", "using", "package"
			])
				m.set(k, true);
			keywordNames = m;
		}
		return m.exists(id);
	}

	// The caches below are lazily initialised and never mutated afterwards:
	// on a threaded host two threads may build the same table twice, which is
	// harmless (each hands out equivalent immutable values).
	//
	// Single-character tokens repeat constantly. Enums are immutable values, so
	// one shared instance per character can be handed out instead of allocating
	// (and slicing) a fresh one for every occurrence.
	static var singleIdTokens: Array<Token>;
	static var singleOpTokens: Array<Token>;
	static var spreadToken: Token;
	static var genericOpenToken: Token;

	static function identToken(first:Int, src:String, start:Int, end:Int):Token {
		if (end - start == 1) {
			var a = singleIdTokens;
			if (a == null) {
				a = [];
				singleIdTokens = a;
			}
			var t = a[first];
			if (t == null) {
				t = TId(String.fromCharCode(first));
				a[first] = t;
			}
			return t;
		}
		return TId(src.substring(start, end));
	}

	static function opToken(first:Int, src:String, start:Int, end:Int):Token {
		if (end - start == 1) {
			var a = singleOpTokens;
			if (a == null) {
				a = [];
				singleOpTokens = a;
			}
			var t = a[first];
			if (t == null) {
				t = TOp(src.substring(start, end));
				a[first] = t;
			}
			return t;
		}
		return TOp(src.substring(start, end));
	}

	public inline function error(err, pmin, pmax) {
		if (!resumeErrors)
			#if hscriptPos
			throw new Error(err, pmin, pmax, origin, line);
			#else
			throw err;
			#end
	}

	public function invalidChar(c) {
		error(EInvalidChar(c), readPos - 1, readPos - 1);
	}

	function initParser(origin) {
		// line=1 - don't reset line : it might be set manualy
		preprocStack = [];
		#if hscriptPos
		this.origin = origin;
		readPos = 0;
		tokenMin = oldTokenMin = 0;
		tokenMax = oldTokenMax = 0;
		tokStack = [];
		tokMinStack = [];
		tokMaxStack = [];
		tokDepth = 0;
		#elseif haxe3
		tokens = new haxe.ds.GenericStack<Token>();
		#else
		tokens = new haxe.FastList<Token>();
		#end
		char = -1;
		ops = new Array();
		idents = new Array();
		uid = 0;
		nextIsPublic = false;
		nextIsStatic = false;
		nextIsOverride = false;
		for (i in 0...opChars.length)
			ops[opChars.charCodeAt(i)] = true;
		for (i in 0...identChars.length)
			idents[identChars.charCodeAt(i)] = true;
	}

	public function parseString(s: String, ?origin: String = "hscript") {
		initParser(origin);
		input = s;
		readPos = 0;
		var a = new Array();
		while (true) {
			var tk = token();
			if (tk == TEof)
				break;
			push(tk);
			parseFullExpr(a);
		}
		return if (a.length == 1) a[0] else mk(EBlock(a), 0);
	}

	function unexpected(tk): Dynamic {
		error(EUnexpected(tokenString(tk)), tokenMin, tokenMax);
		return null;
	}

	inline function push(tk) {
		#if hscriptPos
		tokStack[tokDepth] = tk;
		tokMinStack[tokDepth] = tokenMin;
		tokMaxStack[tokDepth] = tokenMax;
		tokDepth++;
		tokenMin = oldTokenMin;
		tokenMax = oldTokenMax;
		#else
		tokens.add(tk);
		#end
	}

	/**
		Push a token with explicit source positions. Used when the tokenizer has
		to split an operator token (for example >> into > and >).
	**/
	inline function pushAt(tk, mn:Int, mx:Int) {
		#if hscriptPos
		tokStack[tokDepth] = tk;
		tokMinStack[tokDepth] = mn;
		tokMaxStack[tokDepth] = mx;
		tokDepth++;
		#else
		tokens.add(tk);
		#end
	}

	inline function ensure(tk) {
		var t = token();
		if (t != tk)
			unexpected(t);
	}

	inline function ensureToken(tk) {
		var t = token();
		if (!Type.enumEq(t, tk))
			unexpected(t);
	}

	function maybe(tk) {
		var t = token();
		// PERF: nullary tokens compare by value with ==, avoiding the
		// reflective Type.enumEq call on the common path.
		if (t == tk || Type.enumEq(t, tk))
			return true;
		push(t);
		return false;
	}

	function getIdent() {
		var tk = token();
		return extractIdent(tk);
	}

	function extractIdent(tk: Token): String {
		switch (tk) {
			case TId(id):
				return id;
			default:
				unexpected(tk);
				return null;
		}
	}

	inline function expr(e: Expr) {
		#if hscriptPos
		return e.e;
		#else
		return e;
		#end
	}

	inline function pmin(e: Expr) {
		#if hscriptPos
		return e == null ? 0 : e.pmin;
		#else
		return 0;
		#end
	}

	inline function pmax(e: Expr) {
		#if hscriptPos
		return e == null ? 0 : e.pmax;
		#else
		return 0;
		#end
	}

	inline function mk(e, ?pmin, ?pmax): Expr {
		#if hscriptPos
		if (e == null)
			return null;
		if (pmin == null)
			pmin = tokenMin;
		if (pmax == null)
			pmax = tokenMax;
		return {
			e: e,
			pmin: pmin,
			pmax: pmax,
			origin: origin,
			line: line
		};
		#else
		return e;
		#end
	}

	function isBlock(e) {
		if (e == null)
			return false;
		return switch (expr(e)) {
			case EBlock(_), EObject(_), ESwitch(_), EEnum(_, _), EClass(_, _, _, _): true;
			case EFunction(_, e, _, _, _, _, _): isBlock(e);
			case EVar(_, t, e, _, _, _): e != null ? isBlock(e) : t != null ? t.match(CTAnon(_)) : false;
			case EIf(_, e1, e2): if (e2 != null) isBlock(e2) else isBlock(e1);
			case EBinop(_, _, e): isBlock(e);
			case EUnop(_, prefix, e): !prefix && isBlock(e);
			case EWhile(_, e): isBlock(e);
			case EDoWhile(_, e): isBlock(e);
			case EFor(_, _, e, _): isBlock(e);
			case EReturn(e): e != null && isBlock(e);
			case ETry(_, _, _, e): isBlock(e);
			case EMeta(_, _, e): isBlock(e);
			case EIgnore(skipSemicolon): skipSemicolon;
			default: false;
		}
	}

	function parseFullExpr(exprs: Array<Expr>) {
		var e = parseExpr();
		// PERF: a switch avoids the anonymous-pattern value that
		// ExprDef.match(EIgnore(_)) builds on every statement.
		var isIgnore = false;
		var isBlockStmt = false;
		if (e != null) {
			switch (expr(e)) {
				case EIgnore(_): isIgnore = true;
				case EBlock(_): isBlockStmt = true;
				default:
			}
		}
		if (!isIgnore)
			exprs.push(e);

		// destructuring declarations (`var [a, b] = arr;`) desugar into an
		// EBlock of plain EVars; splice them into the statement list so the
		// variables are declared in the enclosing scope, not a synthetic block
		if (isBlockStmt) {
			var list:Array<Expr> = null;
			switch (expr(e)) {
				case EBlock(l): list = l;
				default:
			}
			if (list != null && list.length > 0) {
				var isDestr = false;
				switch (Tools.expr(list[0])) {
					case EVar(n, _, _, _, _, _):
						isDestr = StringTools.startsWith(n, "__destr_");
					default:
				}
				if (isDestr) {
					exprs.pop();
					for (x in list)
						exprs.push(x);
					e = list[list.length - 1];
				}
			}
		}

		var tk = token();
		// this is a hack to support var a,b,c; with a single EVar
		while (tk == TComma && e != null && isVarExpr(e)) {
			e = parseStructure("var"); // next variable
			if (e != null && !isIgnoreExpr(e))
				exprs.push(e);
			tk = token();
		}

		if (tk != TSemicolon && tk != TEof) {
			if (isBlock(e))
				push(tk);
			else
				unexpected(tk);
		}
	}

	inline function isIgnoreExpr(e:Expr):Bool {
		return switch (expr(e)) {
			case EIgnore(_): true;
			default: false;
		}
	}

	inline function isVarExpr(e:Expr):Bool {
		return switch (expr(e)) {
			case EVar(_, _, _, _, _, _): true;
			default: false;
		}
	}

	// ---------------------- destructuring patterns ----------------------

	/**
		Parses var [a, b] = e; and var {x: y, z = 1} = e;.

		The AST is frozen, so every pattern is desugared into plain EVar nodes.
		The source expression is evaluated exactly once into a hidden temporary
		(__destr_<n>) and every binding reads from that temporary:

			var [a, b] = arr;        ->  var __destr_0 = arr;
			                             var a = __destr_0[0];
			                             var b = __destr_0[1];
			var {x: y} = obj;        ->  var __destr_1 = obj;  var y = __destr_1.x;
			var {x = 1} = obj;       ->  var __destr_2 = obj;
			                             var __destr_3 = __destr_2.x;
			                             var x = __destr_3 == null ? 1 : __destr_3;
			var [a, ...rest] = arr;  ->  ... var rest = __destr_4.slice(1);
			var [[a],[b]] = pairs;   ->  var a = __destr_5[0][0];
			                             var b = __destr_5[1][0];
	**/
	function parseDestrDecl(isConst:Bool, p1:Int):Expr {
		var tmp = "__destr_" + (uid++);
		var bindings:Array<Expr> = [];
		parsePatternAt(mk(EIdent(tmp), p1), bindings, isConst, p1);
		ensureToken(TOp("="));
		var value = parseExpr();
		var exprs:Array<Expr> = [mk(EVar(tmp, null, value, isConst, nextIsPublic, nextIsStatic), p1)];
		for (b in bindings)
			exprs.push(b);
		nextIsPublic = false;
		nextIsStatic = false;
		return mk(EBlock(exprs), p1);
	}

	/** Consumes [ ... ] or { ... } and appends one EVar per binding. */
	function parsePatternAt(access:Expr, out:Array<Expr>, isConst:Bool, p1:Int):Void {
		var before = out.length;
		var tk = token();
		switch (tk) {
			case TBkOpen:
				parseArrayPattern(access, out, isConst, p1);
			case TBrOpen:
				parseObjectPattern(access, out, isConst, p1);
			default:
				unexpected(tk);
		}
		// `var [] = a;` / `var {} = o;` bind nothing: always a mistake
		if (out.length == before)
			error(ECustom("Empty destructuring pattern"), tokenMin, tokenMax);
	}

	/**
		Array pattern: [a, b], [a, ...rest], [[a],[b]], elided slots.
		Every element reads access[index].
	**/
	function parseArrayPattern(access:Expr, out:Array<Expr>, isConst:Bool, p1:Int):Void {
		var index = 0;
		while (true) {
			var tk = token();
			switch (tk) {
				case TBkClose:
					return;
				case TComma:
					index++; // elided element
					continue;
				case TOp("..."):
					var restName = getIdent();
					var slice = mk(ECall(mk(EField(access, "slice", false), p1), [mk(EConst(CInt(index)), p1)]), p1);
					out.push(mk(EVar(restName, null, slice, isConst, nextIsPublic, nextIsStatic), p1));
					ensure(TBkClose);
					return;
				case TId(name):
					out.push(mk(EVar(name, null, mk(EArray(access, mk(EConst(CInt(index)), p1)), p1), isConst, nextIsPublic, nextIsStatic), p1));
				case TBkOpen, TBrOpen:
					push(tk);
					parsePatternAt(mk(EArray(access, mk(EConst(CInt(index)), p1)), p1), out, isConst, p1);
				default:
					unexpected(tk);
			}
			index++;
			var t2 = token();
			switch (t2) {
				case TBkClose:
					return;
				case TComma:
				default:
					unexpected(t2);
			}
		}
	}

	/**
		Object pattern: {x}, {x: y} (rename), {x = 1} (default), {x: [a, b]} (nested).
		Every field reads access.name.
	**/
	function parseObjectPattern(access:Expr, out:Array<Expr>, isConst:Bool, p1:Int):Void {
		while (true) {
			var tk = token();
			switch (tk) {
				case TBrClose:
					return;
				case TComma:
					continue;
				case TId(name):
					var fieldAccess = mk(EField(access, name, false), p1);
					var t2 = token();
					switch (t2) {
						case TDoubleDot:
							// rename (x: y) or nested pattern (x: [a, b])
							var t3 = token();
							switch (t3) {
								case TId(alias):
									var t4 = token();
									if (Type.enumEq(t4, TOp("="))) {
										bindDefault(alias, fieldAccess, parseExpr(), out, isConst, p1);
									} else {
										push(t4);
										out.push(mk(EVar(alias, null, fieldAccess, isConst, nextIsPublic, nextIsStatic), p1));
									}
								case TBkOpen, TBrOpen:
									push(t3);
									parsePatternAt(fieldAccess, out, isConst, p1);
								default:
									unexpected(t3);
							}
						case TOp("="):
							bindDefault(name, fieldAccess, parseExpr(), out, isConst, p1);
						case TComma:
							out.push(mk(EVar(name, null, fieldAccess, isConst, nextIsPublic, nextIsStatic), p1));
						case TBrClose:
							out.push(mk(EVar(name, null, fieldAccess, isConst, nextIsPublic, nextIsStatic), p1));
							return;
						default:
							unexpected(t2);
					}
				default:
					unexpected(tk);
			}
		}
	}

	/**
		{x = 1}: read the source slot once into its own temporary (so the source
		expression is never evaluated twice) and fall back to the default only
		when the value is null.
	**/
	function bindDefault(name:String, access:Expr, def:Expr, out:Array<Expr>, isConst:Bool, p1:Int):Void {
		var tv = "__destr_" + (uid++);
		out.push(mk(EVar(tv, null, access, true, false, false), p1));
		var isNull = mk(EBinop("==", mk(EIdent(tv), p1), mk(EIdent("null"), p1)), p1);
		var picked = mk(ETernary(isNull, def, mk(EIdent(tv), p1)), p1);
		out.push(mk(EVar(name, null, picked, isConst, nextIsPublic, nextIsStatic), p1));
	}

	/**
		Assignment form (statement or expression position):
			[a, b] = f();   {x} = obj;   [a, ...rest] = arr;
		Desugared to var t = rhs; a = t[0]; b = t[1]; inside an EBlock whose last
		expression is the temporary, so it still yields the source value.
	**/
	function isPatternAssignTarget(e:Expr):Bool {
		return switch (expr(e)) {
			case EArrayDecl(_), EObject(_): true;
			default: false;
		}
	}

	function desugarPatternAssign(target:Expr, value:Expr, p1:Int):Expr {
		var tmp = "__destr_" + (uid++);
		var stmts:Array<Expr> = [mk(EVar(tmp, null, value, false, false, false), p1)];
		assignPattern(target, mk(EIdent(tmp), p1), stmts, p1);
		stmts.push(mk(EIdent(tmp), p1));
		return mk(EBlock(stmts), p1, pmax(value));
	}

	function assignPattern(target:Expr, access:Expr, out:Array<Expr>, p1:Int):Void {
		switch (expr(target)) {
			case EIdent(_), EField(_, _, _):
				out.push(mk(EBinop("=", target, access), p1));
			case EArrayDecl(el):
				var i = 0;
				for (t in el) {
					switch (expr(t)) {
						case EUnop("...", _, inner):
							var slice = mk(ECall(mk(EField(access, "slice", false), p1), [mk(EConst(CInt(i)), p1)]), p1);
							assignPattern(inner, slice, out, p1);
							return;
						default:
					}
					assignPattern(t, mk(EArray(access, mk(EConst(CInt(i)), p1)), p1), out, p1);
					i++;
				}
			case EObject(fl):
				for (f in fl)
					assignPattern(f.e, mk(EField(access, f.name, false), p1), out, p1);
			default:
				error(ECustom("Invalid destructuring assignment target"), pmin(target), pmax(target));
		}
	}

	// ------------------- or-patterns / comprehensions -------------------

	/**
		Case patterns: an unparenthesised top-level | chain is a list of
		alternatives, so case 1 | 2: matches either. A parenthesised
		case (1|2): stays one EParent value, i.e. the bitwise OR.
	**/
	function flattenOrPattern(e:Expr, out:Array<Expr>):Void {
		switch (expr(e)) {
			case EBinop("|", e1, e2):
				flattenOrPattern(e1, out);
				flattenOrPattern(e2, out);
			default:
				out.push(e);
		}
	}

	/** True when a comprehension body is a k => v pair. */
	function isMapComprBody(e:Expr):Bool {
		if (e == null)
			return false;
		return switch (expr(e)) {
			case EFor(_, _, e2, _): isMapComprBody(e2);
			case EWhile(_, e2): isMapComprBody(e2);
			case EDoWhile(_, e2): isMapComprBody(e2);
			case EIf(_, e1, e2) if (e2 == null): isMapComprBody(e1);
			case EBlock([e2]): isMapComprBody(e2);
			case EParent(e2): isMapComprBody(e2);
			case EBinop("=>", _, _): true;
			default: false;
		}
	}

	/** Like mapCompr, but fills a Map through set(k, v) instead of push. */
	function mapComprSet(tmp:String, e:Expr) {
		if (e == null)
			return null;
		var edef = switch (expr(e)) {
			case EFor(v, it, e2, ithv):
				EFor(v, it, mapComprSet(tmp, e2), ithv);
			case EWhile(cond, e2):
				EWhile(cond, mapComprSet(tmp, e2));
			case EDoWhile(cond, e2):
				EDoWhile(cond, mapComprSet(tmp, e2));
			case EIf(cond, e1, e2) if (e2 == null):
				EIf(cond, mapComprSet(tmp, e1), null);
			case EBlock([e2]):
				EBlock([mapComprSet(tmp, e2)]);
			case EParent(e2):
				EParent(mapComprSet(tmp, e2));
			case EBinop("=>", k, v):
				ECall(mk(EField(mk(EIdent(tmp), pmin(e), pmax(e)), "set", false), pmin(e), pmax(e)), [k, v]);
			default:
				ECall(mk(EField(mk(EIdent(tmp), pmin(e), pmax(e)), "push", false), pmin(e), pmax(e)), [e]);
		}
		return mk(edef, pmin(e), pmax(e));
	}

	/**
		Erases an optional <T, U> type-parameter list after a function name
		(function f<T>(x:T):T). Type parameters are a compile-time concept.
	**/
	function skipGenericParams():Void {
		var lt = genericOpenToken;
		if (lt == null)
			lt = genericOpenToken = TOp("<");
		var tk = token();
		if (!Type.enumEq(tk, lt)) {
			push(tk);
			return;
		}
		var depth = 1;
		while (depth > 0) {
			var t = token();
			switch (t) {
				case TOp(op) if (op.charCodeAt(0) == "<".code):
					var opens = 0;
					while (opens < op.length && op.charCodeAt(opens) == "<".code)
						opens++;
					depth += opens;
				case TOp(op) if (op.charCodeAt(0) == ">".code):
					var closes = 0;
					while (closes < op.length && op.charCodeAt(closes) == ">".code)
						closes++;
					depth -= closes;
				case TEof:
					unexpected(t);
				default:
			}
		}
	}

	function parseObject(p1) {
		// parse object
		var fl: Array<ObjectDecl> = [];
		while (true) {
			var tk = token();
			var id = null;
			switch (tk) {
				case TId(i):
					id = i;
				case TConst(c):
					if (!allowJSON)
						unexpected(tk);
					switch (c) {
						case CString(s): id = s;
						default: unexpected(tk);
					}
			case TBrClose:
				break;
			default:
				unexpected(tk);
				break;
		}
		var tk2 = token();
		if (tk2 == TDoubleDot) {
			// `key: value` — the `:` is consumed here
			fl.push({name: id, e: parseExpr()});
		} else {
			// `key` followed by `,` or `}` — Haxe 4 shorthand `{x}` means `{x: x}`;
			// leave the separator for the trailing switch below
			push(tk2);
			if (id != null)
				fl.push({name: id, e: mk(EIdent(id))});
			else
				unexpected(tk2);
		}
		tk = token();
			switch (tk) {
				case TBrClose:
					break;
				case TComma:
				default:
					unexpected(tk);
			}
		}
		return parseExprNext(mk(EObject(fl), p1));
	}

	function parseExpr() {
		var tk = token();
		#if hscriptPos
		var p1 = tokenMin;
		#end
		switch (tk) {
			case TId(id):
				var e = parseStructure(id);
				if (e == null)
					e = mk(EIdent(id));
				return parseExprNext(e);
			case TInterp(parts):
				// `"a$x${y + 1}"` → EConst("a") + EIdent(x) + EConst(...) chain
				var e:Expr = null;
				for (p in parts) {
					var pe:Expr = Std.isOfType(p, String) ? mk(EConst(CString(p))) : p;
					if (e == null)
						e = pe;
					else
						e = mk(EBinop("+", e, pe));
				}
				if (e == null)
					e = mk(EConst(CString("")));
				return parseExprNext(e);
			case TConst(c):
				return parseExprNext(mk(EConst(c)));
			case TPOpen:
				tk = token();
				if (tk == TPClose) {
					ensureToken(TOp("->"));
					var eret = parseExpr();
					return mk(EFunction([], mk(EReturn(eret), p1)), p1);
				}
				push(tk);
				var e = parseExpr();
				tk = token();
				switch (tk) {
					case TPClose:
						return parseExprNext(mk(EParent(e), p1, tokenMax));
					case TDoubleDot:
						var t = parseType();
						tk = token();
						switch (tk) {
							case TPClose:
								return parseExprNext(mk(ECheckType(e, t), p1, tokenMax));
							case TComma:
								switch (expr(e)) {
									case EIdent(v): return parseLambda([{name: v, t: t}], pmin(e));
									default:
								}
							default:
						}
					case TComma:
						switch (expr(e)) {
							case EIdent(v): return parseLambda([{name: v}], pmin(e));
							default:
						}
					default:
				}
				return unexpected(tk);
			case TBrOpen:
				tk = token();
				switch (tk) {
					case TBrClose:
						return parseExprNext(mk(EObject([]), p1));
					case TId(_):
						var tk2 = token();
						push(tk2);
						push(tk);
						switch (tk2) {
							case TDoubleDot, TComma, TBrClose:
								// `{a: 1}` regular field, `{a}` / `{a, b}` Haxe 4 shorthand
								return parseExprNext(parseObject(p1));
							default:
						}
					case TConst(c):
						if (allowJSON) {
							switch (c) {
								case CString(_):
									var tk2 = token();
									push(tk2);
									push(tk);
									switch (tk2) {
										case TDoubleDot:
											return parseExprNext(parseObject(p1));
										default:
									}
								default:
									push(tk);
							}
						} else push(tk);
					default:
						push(tk);
				}
				var a = new Array();
				while (true) {
					parseFullExpr(a);
					tk = token();
					if (tk == TBrClose || (resumeErrors && tk == TEof))
						break;
					push(tk);
				}
				return mk(EBlock(a), p1);
			case TOp(op):
				if (op == "-") {
					var start = tokenMin;
					var e = parseExpr();
					if (e == null)
						return makeUnop(op, e);
					switch (expr(e)) {
						case EConst(CInt(i)):
							return mk(EConst(CInt(-i)), start, pmax(e));
						case EConst(CFloat(f)):
							return mk(EConst(CFloat(-f)), start, pmax(e));
						default:
							return makeUnop(op, e);
					}
				}
				if (opPriority.get(op) < 0)
					return makeUnop(op, parseExpr());
				return unexpected(tk);
			case TBkOpen:
				var a = new Array();
				tk = token();
				while (tk != TBkClose && (!resumeErrors || tk != TEof)) {
					var st = spreadToken;
					if (st == null)
						st = spreadToken = TOp("...");
					if (Type.enumEq(tk, st)) {
						// spread element; only meaningful as a destructuring target
						// (`[a, ...rest] = arr;`), consumed by the assignment desugaring
						var arg = parseExpr();
						a.push(mk(EUnop("...", false, arg), pmin(arg)));
					} else {
						push(tk);
						a.push(parseExpr());
					}
					tk = token();
					if (tk == TComma)
						tk = token();
				}
				if (a.length == 1 && a[0] != null)
					switch (expr(a[0])) {
						case EFor(_, _, _, _) if (isMapComprBody(a[0])):
							// [for (k => v in map) k => v] builds a Map
							var mtmp = "__map_" + (uid++);
							var me = mk(EBlock([
								mk(EVar(mtmp, null, mk(ENew("Map", []), p1), false, false, false), p1),
								mapComprSet(mtmp, a[0]),
								mk(EIdent(mtmp), p1),
							]), p1);
							return parseExprNext(me);
						case EFor(_), EWhile(_), EDoWhile(_):
							var tmp = "__a_" + (uid++);
							var e = mk(EBlock([
								mk(EVar(tmp, null, mk(EArrayDecl([]), p1)), p1),
								mapCompr(tmp, a[0]),
								mk(EIdent(tmp), p1),
							]), p1);
							return parseExprNext(e);
						default:
					}
				return parseExprNext(mk(EArrayDecl(a), p1));
			case TMeta(id) if (allowMetadata):
				var args = parseMetaArgs();
				return mk(EMeta(id, args, parseExpr()), p1);
			case TSemicolon:
				// bare empty statement (`;;`) is a no-op, like Haxe. EIgnore(true)
				// makes parseFullExpr treat it as block-like and hand the following
				// token back instead of demanding a semicolon.
				return mk(EIgnore(true));
			default:
				return unexpected(tk);
		}
	}

	function parseLambda(args: Array<Argument>, pmin) {
		while (true) {
			var id = getIdent();
			var t = maybe(TDoubleDot) ? parseType() : null;
			args.push({name: id, t: t});
			var tk = token();
			switch (tk) {
				case TComma:
				case TPClose:
					break;
				default:
					unexpected(tk);
					break;
			}
		}
		ensureToken(TOp("->"));
		var eret = parseExpr();
		return mk(EFunction(args, mk(EReturn(eret), pmin)), pmin);
	}

	function parseMetaArgs() {
		var tk = token();
		if (tk != TPOpen) {
			push(tk);
			return null;
		}
		var args = [];
		tk = token();
		if (tk != TPClose) {
			push(tk);
			while (true) {
				args.push(parseExpr());
				switch (token()) {
					case TComma:
					case TPClose:
						break;
					case tk:
						unexpected(tk);
				}
			}
		}
		return args;
	}

	function mapCompr(tmp: String, e: Expr) {
		if (e == null)
			return null;
		var edef = switch (expr(e)) {
			case EFor(v, it, e2):
				EFor(v, it, mapCompr(tmp, e2));
			case EWhile(cond, e2):
				EWhile(cond, mapCompr(tmp, e2));
			case EDoWhile(cond, e2):
				EDoWhile(cond, mapCompr(tmp, e2));
			case EIf(cond, e1, e2) if (e2 == null):
				EIf(cond, mapCompr(tmp, e1), null);
			case EBlock([e]):
				EBlock([mapCompr(tmp, e)]);
			case EParent(e2):
				EParent(mapCompr(tmp, e2));
			default:
				ECall(mk(EField(mk(EIdent(tmp), pmin(e), pmax(e)), "push", false), pmin(e), pmax(e)), [e]);
		}
		return mk(edef, pmin(e), pmax(e));
	}

	function makeUnop(op, e) {
		if (e == null && resumeErrors)
			return null;
		return switch (expr(e)) {
			case EBinop(bop, e1, e2): mk(EBinop(bop, makeUnop(op, e1), e2), pmin(e1), pmax(e2));
			case ETernary(e1, e2, e3): mk(ETernary(makeUnop(op, e1), e2, e3), pmin(e1), pmax(e3));
			default: mk(EUnop(op, true, e), pmin(e), pmax(e));
		}
	}

	function makeBinop(op, e1, e, prio) {
		// PERF: the caller already looked this operator's priority up in
		// opPriority and passes it in; only opRightAssoc (public API, so it must
		// keep being read) still needs a query.
		var rightAssoc = opRightAssoc.exists(op);
		if (e == null && resumeErrors)
			return mk(EBinop(op, e1, e), pmin(e1), pmax(e1));
		return switch (expr(e)) {
			case EBinop(op2, e2, e3):
				if (prio <= opPriority.get(op2)
					&& !rightAssoc) mk(EBinop(op2, makeBinop(op, e1, e2, prio), e3), pmin(e1), pmax(e3)); else mk(EBinop(op, e1, e), pmin(e1), pmax(e));
			case ETernary(e2, e3, e4):
				if (rightAssoc) mk(EBinop(op, e1, e), pmin(e1), pmax(e)); else mk(ETernary(makeBinop(op, e1, e2, prio), e3, e4), pmin(e1), pmax(e));
			default:
				mk(EBinop(op, e1, e), pmin(e1), pmax(e));
		}
	}

	function parseStructure(id) {
		#if hscriptPos
		var p1 = tokenMin;
		#end
		// PERF: identifiers that are not statement keywords fall to the default
		// branch below. This Map pre-filter is about half the cost of running
		// the 29-case string switch for every identifier in the source.
		if (!isKeywordName(id))
			return null;
		return switch (id) {
			case "if":
				ensure(TPOpen);
				var cond = parseExpr();
				ensure(TPClose);
				var e1 = parseExpr();
				var e2 = null;
				var semic = false;
				var tk = token();
				if (tk == TSemicolon) {
					semic = true;
					tk = token();
				}
				if (Type.enumEq(tk, TId("else")))
					e2 = parseExpr();
				else {
					push(tk);
					if (semic)
						push(TSemicolon);
				}
				mk(EIf(cond, e1, e2), p1, (e2 == null) ? tokenMax : pmax(e2));
			case "override":
				nextIsOverride = true;
				var nextToken = token();
				switch (nextToken) {
					case TId("public"): var str = parseStructure("public"); nextIsOverride = false; str;
					case TId("function"): var str = parseStructure("function"); nextIsOverride = false; str;
					case TId("static"): var str = parseStructure("static"); nextIsOverride = false; str;
					case TId("var"): var str = parseStructure("var"); nextIsOverride = false; str;
					case TId("final"): var str = parseStructure("final"); nextIsOverride = false; str;
					default: unexpected(nextToken); nextIsOverride = false; null;
				}
			case "static":
				nextIsStatic = true;
				var nextToken = token();
				switch (nextToken) {
					case TId("public"): var str = parseStructure("public"); nextIsStatic = false; str;
					case TId("function"): var str = parseStructure("function"); nextIsStatic = false; str;
					case TId("override"): var str = parseStructure("override"); nextIsStatic = false; str;
					case TId("var"): var str = parseStructure("var"); nextIsStatic = false; str;
					case TId("final"): var str = parseStructure("final"); nextIsStatic = false; str;
					default: unexpected(nextToken); nextIsStatic = false; null;
				}
			case "public":
				nextIsPublic = true;
				var nextToken = token();
				switch (nextToken) {
					case TId("static"): var str = parseStructure("static"); nextIsPublic = false; str;
					case TId("function"): var str = parseStructure("function"); nextIsPublic = false; str;
					case TId("override"): var str = parseStructure("override"); nextIsPublic = false; str;
					case TId("var"): var str = parseStructure("var"); nextIsPublic = false; str;
					case TId("final"): var str = parseStructure("final"); nextIsPublic = false; str;
					default: unexpected(nextToken); nextIsPublic = false; null;
				}
			case "private":
				var nextToken = token();
				switch (nextToken) {
					case TId("function"): parseStructure("function");
					case TId("var"): parseStructure("var");
					case TId("final"): parseStructure("final");
					case TId("static"): parseStructure("static");
					case TId("class"): parseStructure("class");
					default: unexpected(nextToken); null;
				}
			case "dynamic":
				if (!maybe(TId("function")))
					unexpected(TId("dynamic"));
				parseStructure("function");
			case "var", "final":
				var isConst = id == "final";
				var tk = token();
				if (tk == TBkOpen || tk == TBrOpen) {
					// destructuring declaration, desugared by parseDestrDecl
					push(tk);
					return parseDestrDecl(isConst, p1);
				}
				push(tk);
				var ident = getIdent();
				tk = token();
				var t = null;
				if (tk == TDoubleDot && allowTypes) {
					t = parseType();
					tk = token();
				}
				var e = null;
				if (Type.enumEq(tk, TOp("=")))
					e = parseExpr();
				else
					push(tk);
				mk(EVar(ident, t, e, id == "final", nextIsPublic, nextIsStatic), p1, (e == null) ? tokenMax : pmax(e));
			case "while":
				var econd = parseExpr();
				var e = parseExpr();
				mk(EWhile(econd, e), p1, pmax(e));
			case "do":
				var e = parseExpr();
				var tk = token();
				switch (tk) {
					case TId("while"): // Valid
					default: unexpected(tk);
				}
				var econd = parseExpr();
				mk(EDoWhile(econd, e), p1, pmax(econd));
			case "for":
				ensure(TPOpen);
				var t0 = token();
				if (t0 == TBkOpen || t0 == TBrOpen) {
					// for ([a, b] in pairs) ->
					//   for (__destr_N in pairs) { var a = __destr_N[0]; var b = __destr_N[1]; <body> }
					push(t0);
					var dtmp = "__destr_" + (uid++);
					var dbind:Array<Expr> = [];
					parsePatternAt(mk(EIdent(dtmp), p1), dbind, false, p1);
					ensureToken(TId("in"));
					var diter = parseExpr();
					ensure(TPClose);
					var dbody = parseExpr();
					dbind.push(dbody);
					return mk(EFor(dtmp, diter, mk(EBlock(dbind), p1), null), p1, pmax(dbody));
				}
				push(t0);
				var ithv:String = null;
				var vname = getIdent();
				var tk = token();
				if (Type.enumEq(tk, TOp("=>"))) {
					var old = vname;
					vname = getIdent();
					ithv = old;
				} else {
					push(tk);
				}
				ensureToken(TId("in"));
				var eiter = parseExpr();
				ensure(TPClose);
				var e = parseExpr();
				mk(EFor(vname, eiter, e, ithv), p1, pmax(e));
			case "break": mk(EBreak);
			case "continue": mk(EContinue);
			case "else": unexpected(TId(id));
			case "inline":
				if (!maybe(TId("function")))
					unexpected(TId("inline"));
				return parseStructure("function");
			case "function":
				var tk = token();
				var name = null;
				switch (tk) {
					case TId(id): name = id;
					default: push(tk);
				}
				if (name != null)
					skipGenericParams();
				var inf = parseFunctionDecl();
				mk(EFunction(inf.args, inf.body, name, inf.ret, nextIsPublic, nextIsStatic, nextIsOverride), p1, pmax(inf.body));
			case "return":
				var tk = token();
				push(tk);
				var e = if (tk == TSemicolon) null else parseExpr();
				mk(EReturn(e), p1, if (e == null) tokenMax else pmax(e));
			case "new":
				var a = new Array();
				a.push(getIdent());
				while (true) {
					var tk = token();
					switch (tk) {
						case TDot:
							a.push(getIdent());
						case TPOpen:
							break;
						case TOp("<"):
							// generic type params start right after the class path
							push(tk);
							break;
						default:
							unexpected(tk);
							break;
					}
				}
				var tk = token();
				if (Type.enumEq(tk, TOp("<"))) {
					// generic type parameters (`new Array<Int>()`) are a
					// compile-time concept — parse and discard them
					var depth = 1;
					while (depth > 0) {
						var t2 = token();
						switch (t2) {
							case TOp(op) if (op.charCodeAt(0) == "<".code):
								var opens = 0;
								while (opens < op.length && op.charCodeAt(opens) == "<".code)
									opens++;
								depth += opens;
							case TOp(op) if (op.charCodeAt(0) == ">".code):
								var closes = 0;
								while (closes < op.length && op.charCodeAt(closes) == ">".code)
									closes++;
								depth -= closes;
							case TEof:
								unexpected(t2);
								break;
							default:
						}
					}
					tk = token(); // the consumed `(` of the argument list
					if (tk != TPOpen)
						unexpected(tk);
				} else {
					// no generics: tk is the first argument (or the closing `)`)
					push(tk);
				}
				var args = parseExprList(TPClose);
				mk(ENew(a.join("."), args), p1);
			case "throw":
				var e = parseExpr();
				mk(EThrow(e), p1, pmax(e));
			case "cast":
				var tk = token();
				if (tk == TPOpen) {
					// checked cast: `cast (expr, Type)`
					var e = parseExpr();
					ensure(TComma);
					var t = parseType();
					ensure(TPClose);
					return mk(ECheckType(e, t), p1, pmax(e));
				}
				// unchecked cast: `cast expr` — identity in the interpreter
				push(tk);
				return parseExpr();
			case "untyped":
				// compile-time hint only: evaluate the wrapped expression
				return parseExpr();
			case "try":
				var e = parseExpr();
				ensureToken(TId("catch"));
				ensure(TPOpen);
				var vname = getIdent();
				// `catch (e)` without a type annotation is valid Haxe
				var t = null;
				var tcolon = token();
				if (tcolon == TDoubleDot) {
					if (allowTypes)
						t = parseType();
					else
						ensureToken(TId("Dynamic"));
				} else
					push(tcolon);
				ensure(TPClose);
				var ec = parseExpr();
				mk(ETry(e, vname, t, ec), p1, pmax(ec));
			case "switch":
				var parentExpr = parseExpr();
				var def = null, cases = [];
				ensure(TBrOpen);
				while (true) {
					var tk = token();
					switch (tk) {
						case TId("case"):
							var c: SwitchCase = {values: [], expr: null, ifExpr: null};
							cases.push(c);
							while (true) {
								var e = parseExpr();
						// an unparenthesised top-level `|` splits into alternatives;
						// `case (1|2):` stays a single parenthesised bitwise OR
						flattenOrPattern(e, c.values);
								tk = token();
								switch (tk) {
									case TComma:
										// next expr
									case TId("if"):
										// if( Type.enumEq(e, EIdent("_")) )
										//	unexpected(TId("if"));

										var e = parseExpr();
										c.ifExpr = e;
										switch tk = token() {
											case TComma:
											case TDoubleDot: break;
											case _:
												unexpected(tk);
												break;
										}
									case TDoubleDot:
										break;
									default:
										unexpected(tk);
										break;
								}
							}
							var exprs = [];
							while (true) {
								tk = token();
								push(tk);
								switch (tk) {
									case TId("case"), TId("default"), TBrClose:
										break;
									case TEof if (resumeErrors):
										break;
									default:
										parseFullExpr(exprs);
								}
							}
							c.expr = if (exprs.length == 1) exprs[0]; else if (exprs.length == 0) mk(EBlock([]), tokenMin,
								tokenMin); else mk(EBlock(exprs), pmin(exprs[0]), pmax(exprs[exprs.length - 1]));

							// `case _ if (cond):` is an ordinary guarded wildcard case: only an
							// unguarded bare `_` is hoisted to defaultExpr, otherwise a later
							// real `default:` would be rejected.
							if (c.ifExpr == null) {
								for (i in c.values) {
									switch Tools.expr(i) {
										case EIdent("_"):
											def = c.expr;
										case _:
									}
								}
							}
						case TId("default"):
							if (def != null)
								unexpected(tk);
							ensure(TDoubleDot);
							var exprs = [];
							while (true) {
								tk = token();
								push(tk);
								switch (tk) {
									case TId("case"), TId("default"), TBrClose:
										break;
									case TEof if (resumeErrors):
										break;
									default:
										parseFullExpr(exprs);
								}
							}
							def = if (exprs.length == 1) exprs[0]; else if (exprs.length == 0) mk(EBlock([]), tokenMin,
								tokenMin); else mk(EBlock(exprs), pmin(exprs[0]), pmax(exprs[exprs.length - 1]));
						case TBrClose:
							break;
						default:
							unexpected(tk);
							break;
					}
				}
				mk(ESwitch(parentExpr, cases, def), p1, tokenMax);
			case "import":
				var path = [getIdent()];
				var asStr: String = null;
				var star: Bool = false;

				while (true) {
					var t = token();
					if (t != TDot) {
						push(t);
						break;
					}
					t = token();
					switch (t) {
						case TOp("*"): star = true;
						case TId(id): path.push(id);
						default: unexpected(t);
					}
				}

				final asErr = " -> " + path.join(".") + " as " + asStr;

				if (maybe(TId("as"))) {
					asStr = getIdent();
					final uppercased: Bool = asStr.charAt(0) == asStr.charAt(0).toUpperCase();
					if (asStr == null || asStr == "null" || asStr == "")
						unexpected(TId("as"));
					if (!uppercased)
						error(ECustom("Import aliases must begin with an uppercase letter." + asErr), readPos, readPos);
				}
				// trace(asStr);
				/*
					if (token() != TSemicolon) {
						error(ECustom("Missing semicolon at the end of a \"import\" declaration. -> "+asErr), readPos, readPos);
						null;
					}
				 */
				if (star && asStr != null)
					error(ECustom("Wildcard imports cannot be aliased." + asErr), readPos, readPos);
				// `import haxe.ds.*;` -> EImport("haxe.ds.*", null): the frozen
				// EImport(v, as) has no wildcard flag, so the package prefix is
				// encoded by the trailing ".*". Module-level DImport keeps its
				// own `everything` flag.
				mk(EImport(star ? path.join('.') + ".*" : path.join('.'), asStr));

			case "class":
				var tk = token();
				var name = null;
				switch (tk) {
					case TId(id): name = id;
					default: push(tk);
				}

				var extend:String = null;
				var interfaces:Array<String> = [];

				// optional: `extends Base` and `implements A, B`
				while (true) {
					var t = token();
					switch (t) {
						case TId("extends"):
							var parts = [getIdent()];
							while (true) {
								var t2 = token();
								if (t2 == TDot) parts.push(getIdent());
								else { push(t2); break; }
							}
							if (extend != null)
								error(ECustom('Cannot extend a class twice.'), 0, 0);
							extend = parts.join(".");
						case TId("implements"):
							var parts = [getIdent()];
							while (true) {
								var t2 = token();
								if (t2 == TDot) parts.push(getIdent());
								else { push(t2); break; }
							}
							interfaces.push(parts.join("."));
						default:
							push(t);
							break;
					}
				}

				var fields = [];
				ensure(TBrOpen);
				while (!maybe(TBrClose)) {
					var tk2 = token();
					if (tk2 == TSemicolon) continue;
					push(tk2);
					var a = parseExpr();
					fields.push(a);
				}

				var tk3 = token();
				push(tk3);
				mk(EClass(name, fields, extend, interfaces), p1);

			case "enum":
				var name = getIdent();

				ensure(TBrOpen);

				var fields = [];

				var currentName = "";
				var currentArgs: Array<Argument> = null;

				while (true) {
					var tk = token();
					switch (tk) {
						case TBrClose:
							break;
						case TSemicolon | TComma:
							if (currentName == "")
								continue;

							if (currentArgs != null && currentArgs.length > 0) {
								fields.push(EnumType.EConstructor(currentName, currentArgs));
								currentArgs = null;
							} else {
								fields.push(EnumType.ESimple(currentName));
							}
							currentName = "";
						case TPOpen:
							if (currentArgs != null) {
								error(ECustom("Cannot have multiple argument lists in one enum constructor"), tokenMin, tokenMax);
								break;
							}
							currentArgs = parseFunctionArgs();
						default:
							if (currentName != "") {
								error(ECustom("Expected comma or semicolon"), tokenMin, tokenMax);
								break;
							}
							var name = extractIdent(tk);
							currentName = name;
					}
				}

				mk(EEnum(name, fields));
			case "typedef":
				// typedef Name = Type;

				/*
					Ignore parsing if its, typedef Name = {
						> Person
						var name:String;
						var age:Int;
					}

					If the value is a class then it will be parsed as a EVar(Name, value);
				 */

				var name = getIdent();

				ensureToken(TOp("="));

				var t = parseType();

				switch (t) {
					case CTAnon(_) | CTExtend(_) | CTIntersection(_) | CTFun(_):
						mk(EIgnore(true));
					case CTPath(tp):
						var path = tp.pack.concat([tp.name]);
						var params = tp.params;
						if (params != null && params.length > 1)
							error(ECustom("Typedefs can't have parameters"), tokenMin, tokenMax);

						if (path.length == 0)
							error(ECustom("Typedefs can't be empty"), tokenMin, tokenMax);

						{
							var className = path.join(".");
							var cl = Tools.getClass(className);
							if (cl != null) {
								return mk(EVar(name, null, mk(EDirectValue(cl))));
							}
						}

						var expr = mk(EIdent(path.shift()));
						while (path.length > 0) {
							expr = mk(EField(expr, path.shift(), false));
						}

						// todo? add import to the beginning of the file?
						mk(EVar(name, null, expr));
					default:
						error(ECustom("Typedef, unknown type " + t), tokenMin, tokenMax);
						null;
				}

			case "using":
				var path = parsePath();
				mk(EUsing(path.join(".")));
			case "package":
				// ignore package
				var tk = token();
				push(tk);
				packageName = "";
				if (tk == TSemicolon)
					return mk(EIgnore(false));

				var path = parsePath();
				// mk(EPackage(path.join(".")));
				packageName = path.join(".");
				mk(EIgnore(false));
			default:
				null;
		}
	}

	function parseExprNext(e1: Expr) {
		var tk = token();
		switch (tk) {
			case TOp(op):
				if (op == "->") {
					// single arg reinterpretation of `f -> e` , `(f) -> e` and `(f:T) -> e`
					switch (expr(e1)) {
						case EIdent(i), EParent(expr(_) => EIdent(i)):
							var eret = parseExpr();
							return mk(EFunction([{name: i}], mk(EReturn(eret), pmin(eret))), pmin(e1));
						case ECheckType(expr(_) => EIdent(i), t):
							var eret = parseExpr();
							return mk(EFunction([{name: i, t: t}], mk(EReturn(eret), pmin(eret))), pmin(e1));
						default:
					}
					unexpected(tk);
				}

				var opPrio = opPriority.get(op);
				if (opPrio == -1) {
					if (isBlock(e1) || switch (expr(e1)) {
							case EParent(_): true;
							default: false;
						}) {
						push(tk);
						return e1;
						}
					return parseExprNext(mk(EUnop(op, false, e1), pmin(e1)));
				}
				if (op == "=" && isPatternAssignTarget(e1))
					return desugarPatternAssign(e1, parseExpr(), pmin(e1));
				return makeBinop(op, e1, parseExpr(), opPrio);
			case TDot | TQuestionDot:
				var field = getIdent();
				return parseExprNext(mk(EField(e1, field, tk == TQuestionDot), pmin(e1)));
			case TPOpen:
				return parseExprNext(mk(ECall(e1, parseExprList(TPClose)), pmin(e1)));
			case TBkOpen:
				var e2 = parseExpr();
				ensure(TBkClose);
				return parseExprNext(mk(EArray(e1, e2), pmin(e1)));
			case TQuestion:
				var e2 = parseExpr();
				ensure(TDoubleDot);
				var e3 = parseExpr();
				return mk(ETernary(e1, e2, e3), pmin(e1), pmax(e3));
			default:
				push(tk);
				return e1;
		}
	}

	function parseFunctionArgs() {
		var args = new Array();
		var tk = token();
		if (tk != TPClose) {
			var done = false;
			while (!done) {
				var name = null, opt = false, rest = false;
				switch (tk) {
					case TQuestion:
						opt = true;
						tk = token();
					case TOp("..."):
						rest = true;
						tk = token();
					default:
				}
				switch (tk) {
					case TId(id):
						name = id;
					default:
						unexpected(tk);
						break;
				}
				var arg: Argument = {name: name, rest: rest};
				args.push(arg);
				if (opt)
					arg.opt = true;
				if (allowTypes) {
					if (maybe(TDoubleDot))
						arg.t = parseType();
					if (maybe(TOp("=")))
						arg.value = parseExpr();
				}
				tk = token();
				switch (tk) {
					case TComma:
						tk = token();
					case TPClose:
						done = true;
					default:
						unexpected(tk);
				}
			}
		}
		return args;
	}

	function parseFunctionDecl() {
		ensure(TPOpen);
		var args = parseFunctionArgs();
		var ret = null;
		if (allowTypes) {
			var tk = token();
			if (tk != TDoubleDot)
				push(tk);
			else
				ret = parseType();
		}
		return {args: args, ret: ret, body: parseExpr()};
	}

	function parsePath() {
		var path = [getIdent()];
		while (true) {
			var t = token();
			if (t != TDot) {
				push(t);
				break;
			}
			path.push(getIdent());
		}
		return path;
	}

	function parseType(): CType {
		var t = token();
		switch (t) {
			case TId(v):
				// PERF: collect the dotted path straight away instead of pushing the
				// identifier back for parsePath() to read (and pop) again.
				var path = [v];
				while (true) {
					var t2 = token();
					if (t2 == TDot)
						path.push(getIdent());
					else {
						push(t2);
						break;
					}
				}
				var name = path.pop();
				var params = null;
				t = token();
				switch (t) {
					case TOp(op):
						if (op == "<") {
							params = [];
							while (true) {
								params.push(parseType());
								t = token();
								switch (t) {
									case TComma: continue;
									case TOp(op):
										if (op == ">")
											break;
										if (op.charCodeAt(0) == ">".code) {
											pushAt(TOp(op.substr(1)), tokenMax - op.length - 1, tokenMax);
											break;
										}
									default:
								}
								unexpected(t);
								break;
							}
						} else push(t);
					default:
						push(t);
				}
				return parseTypeNext(CTPath({
					pack: path,
					params: params,
					sub: null,
					name: name
				}));
			case TPOpen:
				var a = token(), b = token();

				push(b);
				push(a);

				function withReturn(args) {
					switch token() { // I think it wouldn't hurt if ensure used enumEq
						case TOp('->'):
						case t:
							unexpected(t);
					}

					return CTFun(args, parseType());
				}

				switch [a, b] {
					case [TPClose, _] | [TId(_), TDoubleDot]:
						var args = [
							for (arg in parseFunctionArgs()) {
								switch arg.value {
									case null:
									case v:
										error(ECustom('Default values not allowed in function types'), #if hscriptPos v.pmin, v.pmax #else 0, 0 #end);
								}

								CTNamed(arg.name, if (arg.opt) CTOpt(arg.t) else arg.t);
							}
						];

						return withReturn(args);
					default:
						var t = parseType();
						return switch token() {
							case TComma:
								var args = [t];

								while (true) {
									args.push(parseType());
									if (!maybe(TComma))
										break;
								}
								ensure(TPClose);
								withReturn(args);
							case TPClose:
								parseTypeNext(CTParent(t));
							case t: unexpected(t);
						}
				}
			case TBrOpen:
				var curType = null;
				var fields = [];
				var tps = [];
				var meta = null;
				while (true) {
					t = token();
					switch (t) {
						case TBrClose: break;
						case TId("var"):
							var name = getIdent();
							ensure(TDoubleDot);
							fields.push({name: name, t: parseType(), meta: meta});
							meta = null;
							ensure(TSemicolon);
						case TId(name):
							ensure(TDoubleDot);
							fields.push({name: name, t: parseType(), meta: meta});
							t = token();
							switch (t) {
								case TComma:
								case TBrClose: break;
								default: unexpected(t);
							}
						case TMeta(name):
							if (meta == null)
								meta = [];
							meta.push({name: name, params: parseMetaArgs()});
						case TOp(">"):
							var tp = parseType();
							switch (tp) {
								case CTPath(tp):
									tps.push(tp);
								default:
									unexpected(t);
							}
							t = token();
							switch (t) {
								case TComma:
								case TBrClose: break;
								default: unexpected(t);
							}
						default:
							trace(t, fields, tps);
							unexpected(t);
							break;
					}
				}
				return parseTypeNext(tps.length == 0 ? CTAnon(fields) : CTExtend(tps, fields));
			default:
				return unexpected(t);
		}
	}

	function parseTypeNext(t: CType) {
		var tk = token();
		var isIntersection = false;
		switch (tk) {
			case TOp(op):
				if (op != "->" && op != "&") {
					push(tk);
					return t;
				}
				isIntersection = op == "&";
			default:
				push(tk);
				return t;
		}
		var t2 = parseType();
		switch (t2) {
			case CTFun(args, _):
				args.unshift(t);
				return t2;
			default:
				if (isIntersection)
					return CTIntersection([t, t2]);
				return CTFun([t], t2);
		}
	}

	function parseExprList(etk) {
		var args = new Array();
		var tk = token();
		if (tk == etk)
			return args;
		push(tk);
		while (true) {
			// spread argument: `f(...arr)` (Haxe 4)
			var spread = false;
			var tk0 = token();
			if (Type.enumEq(tk0, TOp("..."))) {
				spread = true;
			} else {
				push(tk0);
			}
			var arg = parseExpr();
			args.push(spread ? mk(EUnop("...", false, arg)) : arg);
			tk = token();
			switch (tk) {
				case TComma:
				default:
					if (tk == etk)
						break;
					unexpected(tk);
					break;
			}
		}
		return args;
	}

	// ------------------------ module -------------------------------

	public function parseModule(content: String, ?origin: String = "hscript") {
		initParser(origin);
		input = content;
		readPos = 0;
		allowTypes = true;
		allowMetadata = true;
		var decls = [];
		while (true) {
			var tk = token();
			if (tk == TEof)
				break;
			push(tk);
			decls.push(parseModuleDecl());
		}
		return decls;
	}

	function parseMetadata(): Metadata {
		var meta = [];
		while (true) {
			var tk = token();
			switch (tk) {
				case TMeta(name):
					meta.push({name: name, params: parseMetaArgs()});
				default:
					push(tk);
					break;
			}
		}
		return meta;
	}

	function parseParams() {
		if (maybe(TOp("<")))
			error(EInvalidOp("Unsupported class type parameters"), readPos, readPos);
		return {};
	}

	function parseModuleDecl(): ModuleDecl {
		var meta = parseMetadata();
		var ident = getIdent();
		var isPrivate = false, isExtern = false;
		while (true) {
			switch (ident) {
				case "private":
					isPrivate = true;
				case "extern":
					isExtern = true;
				default:
					break;
			}
			ident = getIdent();
		}
		switch (ident) {
			case "package":
				var path = parsePath();
				ensure(TSemicolon);
				return DPackage(path);
			case "import":
				var path = [getIdent()];
				var star = false;
				var as = "";
				while (true) {
					var t = token();
					if (t != TDot) {
						push(t);
						break;
					}
					t = token();
					switch (t) {
						case TId(id):
							path.push(id);
						case TOp("*"):
							star = true;
						default:
							unexpected(t);
					}
				}
				ensure(TSemicolon);
				return DImport(path, star, as);
			case "class":
				var name = getIdent();
				var params = parseParams();
				var extend = null;
				var implement = [];

				while (true) {
					var t = token();
					switch (t) {
						case TId("extends"):
							extend = parseType();
						case TId("implements"):
							implement.push(parseType());
						default:
							push(t);
							break;
					}
				}

				var fields = [];
				ensure(TBrOpen);
				while (!maybe(TBrClose))
					fields.push(parseField());

				return DClass({
					name: name,
					meta: meta,
					params: params,
					extend: extend,
					implement: implement,
					fields: fields,
					isPrivate: isPrivate,
					isExtern: isExtern,
				});
			case "typedef":
				var name = getIdent();
				var params = parseParams();
				ensureToken(TOp("="));
				var t = parseType();
				return DTypedef({
					name: name,
					meta: meta,
					params: params,
					isPrivate: isPrivate,
					t: t,
				});
			default:
				unexpected(TId(ident));
		}
		return null;
	}

	function parseField(): FieldDecl {
		var meta = parseMetadata();
		var access = [];
		while (true) {
			var id = getIdent();
			switch (id) {
				case "override":
					access.push(AOverride);
				case "public":
					access.push(APublic);
				case "private":
					access.push(APrivate);
				case "inline":
					access.push(AInline);
				case "static":
					access.push(AStatic);
				case "macro":
					access.push(AMacro);
				case "function":
					var name = getIdent();
					skipGenericParams();
					var inf = parseFunctionDecl();
					return {
						name: name,
						meta: meta,
						access: access,
						kind: KFunction({
							args: inf.args,
							expr: inf.body,
							ret: inf.ret,
						}),
					};
				case "var", "final":
					var name = getIdent();
					var get = null, set = null;
					if (maybe(TPOpen)) {
						get = getIdent();
						ensure(TComma);
						set = getIdent();
						ensure(TPClose);
					}
					var type = maybe(TDoubleDot) ? parseType() : null;
					var expr = maybe(TOp("=")) ? parseExpr() : null;

					if (expr != null) {
						if (isBlock(expr))
							maybe(TSemicolon);
						else
							ensure(TSemicolon);
					} else if (type != null && type.match(CTAnon(_))) {
						maybe(TSemicolon);
					} else
						ensure(TSemicolon);

					return {
						name: name,
						meta: meta,
						access: access,
						kind: KVar({
							get: get,
							set: set,
							type: type,
							expr: expr,
						}),
					};
				default:
					unexpected(TId(id));
					break;
			}
		}
		return null;
	}

	// ------------------------ lexing -------------------------------

	inline function readChar() {
		return StringTools.fastCodeAt(input, readPos++);
	}

	function readString(until:Int) {
		// PERF fast path: the vast majority of string literals contain neither an
		// escape nor a `$`. Scan for the terminator first and return one
		// substring, instead of allocating a StringBuf, a flushLit closure and a
		// fresh string per accumulated character.
		var start = readPos;
		var src = input;
		var len = src.length;
		var p = start;
		var simple = false;
		while (p < len) {
			var fc = StringTools.fastCodeAt(src, p);
			if (fc == until) {
				simple = true;
				break;
			}
			// backslash (92), dollar (36) or newline (10): full slow path
			if (fc == 92 || fc == 36 || fc == 10)
				break;
			p++;
		}
		if (simple) {
			readPos = p + 1;
			interpParts = null;
			return src.substring(start, p);
		}
		return readStringSlow(until, start);
	}

	function readStringSlow(until:Int, start:Int) {
		readPos = start;
		var c = 0;
		var b = new StringBuf();
		var esc = false;
		var old = line;
		var s = input;
		#if hscriptPos
		var p1 = readPos - 1;
		#end
		// interpolation support: parts alternate String chunks and Expr pieces.
		// fast path (no `$`) keeps returning a plain string with zero overhead.
		var parts:Array<Dynamic> = null;
		var pending = -1;
		function flushLit() {
			if (parts != null) {
				parts.push(b.toString());
				b = new StringBuf();
			}
		}
		while (true) {
			c = pending >= 0 ? pending : readChar();
			pending = -1;
			if (StringTools.isEof(c)) {
				line = old;
				error(EUnterminatedString, p1, p1);
				break;
			}
			if (esc) {
				esc = false;
				switch (c) {
					case 'n'.code:
						b.addChar('\n'.code);
					case 'r'.code:
						b.addChar('\r'.code);
					case 't'.code:
						b.addChar('\t'.code);
					case "'".code, '"'.code, '\\'.code:
						b.addChar(c);
					case '/'.code:
						if (allowJSON)
							b.addChar(c)
						else
							invalidChar(c);
					case "u".code:
						if (!allowJSON)
							invalidChar(c);
						var k = 0;
						for (i in 0...4) {
							k <<= 4;
							var char = readChar();
							switch (char) {
								case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57: // 0-9
									k += char - 48;
								case 65, 66, 67, 68, 69, 70: // A-F
									k += char - 55;
								case 97, 98, 99, 100, 101, 102: // a-f
									k += char - 87;
								default:
									if (StringTools.isEof(char)) {
										line = old;
										error(EUnterminatedString, p1, p1);
									}
									invalidChar(char);
							}
						}
						b.addChar(k);
					default:
						invalidChar(c);
				}
			} else if (c == 92)
				esc = true;
			else if (c == '$'.code) {
				if (parts == null)
					parts = [];
				var n = readChar();
				if (n == '$'.code) {
					// `$$` is the escaped dollar, like Haxe
					b.addChar('$'.code);
				} else if (n == '{'.code) {
					// `${expr}` — parse the embedded expression from the same
					// source stream, then expect the closing brace
					flushLit();
					var e = parseExpr();
					var tk = token();
					if (tk != TBrClose)
						unexpected(tk);
					parts.push(e);
				} else if (n >= 0 && idents[n]) {
					// `$ident`
					flushLit();
					var id = String.fromCharCode(n);
					while (true) {
						var ch = readChar();
						if (StringTools.isEof(ch) || !idents[ch]) {
							pending = ch;
							break;
						}
						id += String.fromCharCode(ch);
					}
					parts.push(mk(EIdent(id), readPos, readPos));
				} else {
					// lone `$` before a non-identifier: keep it literal
					b.addChar('$'.code);
					pending = n;
				}
			}
			else if (c == until)
				break;
			else {
				if (c == 10)
					line++;
				b.addChar(c);
			}
		}
		if (parts != null)
			parts.push(b.toString());
		interpParts = parts;
		return b.toString();
	}

	function token():Token {
	#if hscriptPos
	if (tokDepth > 0) {
		tokDepth--;
		tokenMin = tokMinStack[tokDepth];
		tokenMax = tokMaxStack[tokDepth];
		return tokStack[tokDepth];
	}
	oldTokenMin = tokenMin;
	oldTokenMax = tokenMax;
	tokenMin = (this.char < 0) ? readPos : readPos - 1;
	var tk = _token();
	tokenMax = (this.char < 0) ? readPos - 1 : readPos - 2;
	return tk;
	#else
	if (!tokens.isEmpty())
		return tokens.pop();
	return _token();
	#end
	}

	// PERF: _token used to be a local function declared inside token(), which
	// made the eval target build a closure on every single token() call. It is
	// an ordinary method now.
	function _token():Token {
		var char;
		if (this.char < 0)
			char = readChar();
		else {
			char = this.char;
			this.char = -1;
		}
		while (true) {
			if (StringTools.isEof(char)) {
				this.char = char;
				return TEof;
			}
			switch (char) {
				case 0:
					return TEof;
				case 32, 9, 13: // space, tab, CR
					#if hscriptPos
					tokenMin++;
					#end
				case 10:
					line++; // LF
					#if hscriptPos
					tokenMin++;
					#end
				case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57: // 0...9
					var n = (char - 48) * 1.0;
					var exp = 0.;
					while (true) {
						char = readChar();
						exp *= 10;
						switch (char) {
							case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
								n = n * 10 + (char - 48);
							case '_'.code:
							case "e".code, "E".code:
								var tk = token();
								var pow: Null<Int> = null;
								switch (tk) {
									case TConst(CInt(e)): pow = e;
									case TOp("-"):
										tk = token();
										switch (tk) {
											case TConst(CInt(e)): pow = -e;
											default: push(tk);
										}
									default:
										push(tk);
								}
								if (pow == null)
									invalidChar(char);
								return TConst(CFloat((Math.pow(10, pow) / exp) * n * 10));
							case ".".code:
								if (exp > 0) {
									// in case of '0...'
									if (exp == 10 && readChar() == ".".code) {
										push(TOp("..."));
										var i = Std.int(n);
										return TConst((i == n) ? CInt(i) : CFloat(n));
									}
									invalidChar(char);
								}
								exp = 1.;
							case "x".code:
								if (n > 0 || exp > 0)
									invalidChar(char);
								// read hexa
								#if haxe3
								var n = 0;
								while (true) {
									char = readChar();
									switch (char) {
										case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57: // 0-9
											n = (n << 4) + char - 48;
										case 65, 66, 67, 68, 69, 70: // A-F
											n = (n << 4) + (char - 55);
										case 97, 98, 99, 100, 101, 102: // a-f
											n = (n << 4) + (char - 87);
										case '_'.code:
										default:
											this.char = char;
											return TConst(CInt(n));
									}
								}
								#else
								var n = haxe.Int32.ofInt(0);
								while (true) {
									char = readChar();
									switch (char) {
										case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57: // 0-9
											n = haxe.Int32.add(haxe.Int32.shl(n, 4), cast(char - 48));
										case 65, 66, 67, 68, 69, 70: // A-F
											n = haxe.Int32.add(haxe.Int32.shl(n, 4), cast(char - 55));
										case 97, 98, 99, 100, 101, 102: // a-f
											n = haxe.Int32.add(haxe.Int32.shl(n, 4), cast(char - 87));
										case '_'.code:
										default:
											this.char = char;
											// we allow to parse hexadecimal Int32 in Neko, but when the value will be
											// evaluated by Interpreter, a failure will occur if no Int32 operation is
											// performed
											var v = try CInt(haxe.Int32.toInt(n)) catch (e:Dynamic) CInt32(n);
											return TConst(v);
									}
								}
								#end
							case "b".code: // Custom thing, not supported in haxe
								if (n > 0 || exp > 0)
									invalidChar(char);
								// read binary
								#if haxe3
								var n = 0;
								while (true) {
									char = readChar();
									switch (char) {
										case 48, 49: // 0-1
											n = (n << 1) + char - 48;
										case '_'.code:
										default:
											this.char = char;
											return TConst(CInt(n));
									}
								}
								#else
								var n = haxe.Int32.ofInt(0);
								while (true) {
									char = readChar();
									switch (char) {
										case 48, 49: // 0-1
											n = haxe.Int32.add(haxe.Int32.shl(n, 1), cast(char - 48));
										case '_'.code:
										default:
											this.char = char;
											// we allow to parse binary Int32 in Neko, but when the value will be
											// evaluated by Interpreter, a failure will occur if no Int32 operation is
											// performed
											var v = try CInt(haxe.Int32.toInt(n)) catch (e:Dynamic) CInt32(n);
											return TConst(v);
									}
								}
								#end
							default:
								this.char = char;
								var i = Std.int(n);
								return TConst((exp > 0) ? CFloat(n * 10 / exp) : ((i == n) ? CInt(i) : CFloat(n)));
						}
					}
				case ";".code:
					return TSemicolon;
				case "(".code:
					return TPOpen;
				case ")".code:
					return TPClose;
				case ",".code:
					return TComma;
				case ".".code:
					char = readChar();
					switch (char) {
						case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
							var n = char - 48;
							var exp = 1;
							while (true) {
								char = readChar();
								exp *= 10;
								switch (char) {
									case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
										n = n * 10 + (char - 48);
									default:
										this.char = char;
										return TConst(CFloat(n / exp));
								}
							}
						case ".".code:
							char = readChar();
							if (char != ".".code)
								invalidChar(char);
							return TOp("...");
						default:
							this.char = char;
							return TDot;
					}
				case "{".code:
					return TBrOpen;
				case "}".code:
					return TBrClose;
				case "[".code:
					return TBkOpen;
				case "]".code:
					return TBkClose;
				case "'".code, '"'.code:
					interpParts = null;
					var s = readString(char);
					return interpParts != null ? TInterp(interpParts) : TConst(CString(s));
				case "?".code:
					char = readChar();
					if (char == ".".code)
						return TQuestionDot;
					else if (char == "?".code) {
						char = readChar();
						if (char == "=".code)
							return TOp("??" + "=");
						return TOp("??");
					}
					this.char = char;
					return TQuestion;
				case ":".code:
					return TDoubleDot;
				case '='.code:
					char = readChar();
					if (char == '='.code)
						return TOp("==");
					else if (char == '>'.code)
						return TOp("=>");
					this.char = char;
					return TOp("=");
				case '@'.code:
					char = readChar();
					if (idents[char] || char == ':'.code) {
						var id = String.fromCharCode(char);
						while (true) {
							char = readChar();
							if (!idents[char]) {
								this.char = char;
								return TMeta(id);
							}
							id += String.fromCharCode(char);
						}
					}
					invalidChar(char);
				case '#'.code:
					char = readChar();
					if (idents[char]) {
						var id = String.fromCharCode(char);
						while (true) {
							char = readChar();
							if (StringTools.isEof(char))
								char = 0;
							if (!idents[char]) {
								this.char = char;
								return preprocess(id);
							}
							id += String.fromCharCode(char);
						}
					}
					invalidChar(char);
				default:
					if (ops[char]) {
						// PERF: slice the operator out of the source instead of building it
						// one String.fromCharCode at a time; single-character operators
						// reuse a cached token.
						var opStart = readPos - 1;
						var opChar0 = char;
						while (true) {
							char = readChar();
							if (StringTools.isEof(char))
								char = 0;
							if (!ops[char]) {
								this.char = char;
								return opToken(opChar0, input, opStart, readPos - 1);
							}
							var op = input.substring(opStart, readPos);
							var pop = input.substring(opStart, readPos - 1);
							if (!opPriority.exists(op) && opPriority.exists(pop)) {
								if (op == "//" || op == "/*")
									return tokenComment(op, char);
								this.char = char;
								return opToken(opChar0, input, opStart, readPos - 1);
							}
						}
					}
					if (idents[char]) {
						// PERF: identifiers are sliced out of the source instead of being
						// built one String.fromCharCode at a time; single-character
						// identifiers reuse a cached token.
						var idChar0 = char;
						var idStart = readPos - 1;
						while (true) {
							char = readChar();
							if (StringTools.isEof(char)) {
								this.char = 0;
								return identToken(idChar0, input, idStart, readPos - 1);
							}
							if (!idents[char]) {
								this.char = char;
								return identToken(idChar0, input, idStart, readPos - 1);
							}
						}
					}
					invalidChar(char);
			}
			char = readChar();
		}
		return null;
	}

	function preprocValue(id: String): Dynamic {
		return preprocessorValues.get(id);
	}

	var preprocStack: Array<PreprocessStackValue>;

	function parsePreproCond() {
		var tk = token();
		return switch (tk) {
			case TPOpen:
				push(TPOpen);
				parseExpr();
			case TId(id):
				mk(EIdent(id), tokenMin, tokenMax);
			case TOp("!"):
				mk(EUnop("!", true, parsePreproCond()), tokenMin, tokenMax);
			default:
				unexpected(tk);
		}
	}

	function evalPreproCond(e: Expr) {
		switch (expr(e)) {
			case EIdent(id):
				return preprocValue(id) != null;
			case EUnop("!", _, e):
				return !evalPreproCond(e);
			case EParent(e):
				return evalPreproCond(e);
			case EBinop("&&", e1, e2):
				return evalPreproCond(e1) && evalPreproCond(e2);
			case EBinop("||", e1, e2):
				return evalPreproCond(e1) || evalPreproCond(e2);
			default:
				error(EInvalidPreprocessor("Can't eval " + expr(e).getName()), readPos, readPos);
				return false;
		}
	}

	function preprocess(id: String): Token {
		switch (id) {
			case "if":
				var e = parsePreproCond();
				var v = evalPreproCond(e);
				preprocStack.push(new PreprocessStackValue(v, v));
				if (!v)
					skipTokens();
				return token();
			case "else", "elseif" if (preprocStack.length > 0):
				var cur = preprocStack[preprocStack.length - 1];
				if (id == "elseif") {
					if (!cur.seenTrue) {
						var e = parsePreproCond();
						var v = evalPreproCond(e);
						if (v) {
							cur.r = true;
							cur.seenTrue = true;
						}
					} else {
						// an earlier branch of this chain already matched:
						// every following branch stays inactive
						cur.r = false;
					}
				} else if (!cur.seenTrue) {
					// `#else` reached while no branch of this chain matched yet
					cur.r = true;
					cur.seenTrue = true;
				} else {
					cur.r = false;
				}
				if (!cur.r)
					skipTokens();
				return token();
			case "end" if (preprocStack.length > 0):
				preprocStack.pop();
				return token();
			default:
				return TPrepro(id);
		}
	}

	function skipTokens() {
		var spos = preprocStack.length - 1;
		var pos = readPos;
		while (true) {
			var tk = token();
			if (tk == TEof) {
				// upstream hscript-improved: tolerate EOF while skipping
				// an unclosed block's remainder (attribution in NOTICE)
				if (preprocStack.length != 0) {
					error(EInvalidPreprocessor("Unclosed"), pos, pos);
				} else {
					//  trace("line: " + pos);
					break;
				}
			}
			// resume parsing as soon as the block we are skipping either gets
			// popped (its matching `#end`) or a branch of the chain becomes
			// active again (`#else`/`#elseif` after an unmatched false branch)
			if (preprocStack.length <= spos || preprocStack[spos].r) {
				push(tk);
				break;
			}
		}
	}

	function tokenComment(op: String, char: Int) {
		var c = op.charCodeAt(1);
		var s = input;
		if (c == '/'.code) { // comment
			while (char != '\r'.code && char != '\n'.code) {
				char = readChar();
				if (StringTools.isEof(char))
					break;
			}
			this.char = char;
			return token();
		}
		if (c == '*'.code) {/* comment */
			var old = line;
			if (op == "/**/") {
				this.char = char;
				return token();
			}
			while (true) {
				while (char != '*'.code) {
					if (char == '\n'.code)
						line++;
					char = readChar();
					if (StringTools.isEof(char)) {
						line = old;
						error(EUnterminatedComment, tokenMin, tokenMin);
						break;
					}
				}
				char = readChar();
				if (StringTools.isEof(char)) {
					line = old;
					error(EUnterminatedComment, tokenMin, tokenMin);
					break;
				}
				if (char == '/'.code)
					break;
			}
			return token();
		}
		this.char = char;
		return TOp(op);
	}

	function constString(c) {
		return switch (c) {
			case CInt(v): Std.string(v);
			case CFloat(f): Std.string(f);
			case CString(s): s; // TODO : escape + quote
			#if !haxe3
			case CInt32(v): Std.string(v);
			#end
		}
	}

	function tokenString(t) {
		return switch (t) {
			case TEof: "<eof>";
			case TConst(c): constString(c);
			case TId(s): s;
			case TOp(s): s;
			case TPOpen: "(";
			case TPClose: ")";
			case TBrOpen: "{";
			case TBrClose: "}";
			case TDot: ".";
			case TComma: ",";
			case TSemicolon: ";";
			case TBkOpen: "[";
			case TBkClose: "]";
			case TQuestion: "?";
			case TDoubleDot: ":";
			case TMeta(id): "@" + id;
			case TPrepro(id): "#" + id;
			case TQuestionDot: "?.";
			case TInterp(parts): "<interp>";
		}
	}
}

@:structInit
final class PreprocessStackValue {
	public var r: Bool;
	public var seenTrue: Bool;

	public function new(r: Bool, seenTrue: Bool) {
		this.r = r;
		this.seenTrue = seenTrue;
	}
}
