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

class Printer {
	var buf: StringBuf;
	var tabs: String;

	var indent: String = "  ";

	public function new() {}

	public function exprToString(e: Expr) {
		buf = new StringBuf();
		tabs = "";
		expr(e);
		return buf.toString();
	}

	public function typeToString(t: CType) {
		buf = new StringBuf();
		tabs = "";
		type(t);
		return buf.toString();
	}

	inline function add<T>(s: T)
		buf.add(s);

	public function typePath(tp: TypePath) {
		add(tp.pack.join("."));
		if (tp.pack.length > 0)
			add(".");
		add(tp.name);
		add((tp.sub != null && tp.sub.length > 0) ? "." + tp.sub : "");
		if (tp.params != null && tp.params.length > 0) {
			add("<");
			var first = true;
			for (p in tp.params) {
				if (first)
					first = false
				else
					add(", ");
				type(p);
			}
			add(">");
		}
	}

	function type(t: CType) {
		switch (t) {
			case CTOpt(t):
				add('?');
				type(t);
			case CTPath(path):
				typePath(path);
			case CTNamed(name, t):
				add(name);
				add(':');
				type(t);
			case CTFun(args, ret) if (Lambda.exists(args, function(a) return a.match(CTNamed(_, _)))):
				add('(');
				for (a in args)
					switch a {
						case CTNamed(_, _): type(a);
						default: type(CTNamed('_', a));
					}
				add(')->');
				type(ret);
			case CTFun(args, ret):
				if (args.length == 0)
					add("Void -> ");
				else {
					for (a in args) {
						type(a);
						add(" -> ");
					}
				}
				type(ret);
			case CTAnon(fields):
				add("{");
				var first = true;
				for (f in fields) {
					if (first) {
						first = false;
						add(" ");
					} else
						add(", ");
					add(f.name + " : ");
					type(f.t);
				}
				add(first ? "}" : " }");
			case CTParent(t):
				add("(");
				type(t);
				add(")");
			case CTExtend(t, fields):
				add("{");
				var first = true;
				for (f in t) {
					if (first) {
						first = false;
						add(" ");
					} else
						add(", ");
					typePath(f);
				}
				var first = true;
				for (f in fields) {
					if (first) {
						first = false;
						add(" ");
					} else
						add(", ");
					add(f.name + " : ");
					type(f.t);
				}
				add(first ? "}" : " }");
			case CTIntersection(types):
				for (i => t in types) {
					type(t);
					if (i < types.length - 1)
						add(" & ");
				}
		}
	}

	function addType(t: CType) {
		if (t != null) {
			add(" : ");
			type(t);
		}
	}

	function addArgument(a: Argument) {
		if (a.rest)
			add("...");
		if (a.opt)
			add("?");
		add(a.name);
		addType(a.t);
	}

	function expr(e: Expr) {
		if (e == null) {
			add("??NULL??");
			return;
		}
		switch (Tools.expr(e)) {
			case EIgnore(_):
			case EConst(c):
				switch (c) {
					case CInt(i): add(i);
					case CFloat(f):
						// Std.string(1.0) == "1", which would re-parse as CInt;
						// keep the value a float by forcing a decimal point.
						var fs = Std.string(f);
						if (fs.indexOf(".") < 0 && fs.indexOf("e") < 0 && fs.indexOf("E") < 0)
							fs += ".0";
						add(fs);
					case CString(s):
						add(quoteString(s));
				}
			case EIdent(v):
				add(v);
			case EVar(n, t, e, c, isPublic, isStatic):
				// `typedef Name = SomeClass;` parses to EVar(Name, EDirectValue(class)).
				// Re-emit it as a typedef so the printed form re-parses; the generic
				// `<Internal Value ...>` form is not valid hscript source.
				if (e != null && !isStatic && !isPublic && !c)
					switch (Tools.expr(e)) {
						case EDirectValue(value) if (Std.isOfType(value, Class)):
							var className = Type.getClassName(cast value);
							if (className != null) {
								add("typedef " + n + " = " + className);
								return;
							}
						default:
					}
				if (isStatic)
					add("static ");
				else if (isPublic)
					add("public ");
				if (c) {
					add("final " + n);
				} else {
					add("var " + n);
				}
				addType(t);
				if (e != null) {
					add(" = ");
					expr(e);
				}
			case EParent(e):
				add("(");
				expr(e);
				add(")");
			case EBlock(el):
				if (el.length == 0) {
					add("{}");
					return;
				}

				incrementIndent();
				add("{\n");
				for (e in el) {
					add(tabs);
					expr(e);
					add(";\n");
				}
				decrementIndent();
				add(tabs);
				add("}");
			case EField(e, f, s):
				exprFieldBase(e);
				if (s) {
					add("?." + f);
				} else {
					add("." + f);
				}
			case EBinop(op, e1, e2):
				expr(e1);
				add(" " + op + " ");
				expr(e2);
			case EUnop(op, pre, e):
				if (op == "...") {
					// the parser stores spread arguments as a POSTFIX EUnop("...", false, e)
					// even though the accepted source syntax is the prefix `...e`.
					add("...");
					expr(e);
				} else if (pre) {
					add(op);
					expr(e);
				} else {
					expr(e);
					add(op);
				}
			case ECall(e, args):
				if (e == null)
					expr(e);
				else
					switch (Tools.expr(e)) {
						case EField(_), EIdent(_), EConst(_):
							expr(e);
						default:
							add("(");
							expr(e);
							add(")");
					}
				add("(");
				var first = true;
				for (a in args) {
					if (first)
						first = false
					else
						add(", ");
					expr(a);
				}
				add(")");
			case EIf(cond, e1, e2):
				add("if( ");
				expr(cond);
				add(" ) ");
				expr(e1);
				if (e2 != null) {
					add(" else ");
					expr(e2);
				}
			case EWhile(cond, e):
				add("while( ");
				expr(cond);
				add(" ) ");
				expr(e);
			case EDoWhile(cond, e):
				add("do ");
				expr(e);
				add(" while ( ");
				expr(cond);
				add(" )");
			case EFor(v, it, e, ithv):
				if (ithv != null)
					add("for( " + ithv + " => " + v + " in ");
				else
					add("for( " + v + " in ");
				expr(it);
				add(" ) ");
				expr(e);
			case EBreak:
				add("break");
			case EContinue:
				add("continue");
			case EFunction(params, e, name, ret, isPublic, isStatic, isOverride):
				if (isOverride)
					add("override ");
				if (isStatic)
					add("static ");
				else if (isPublic)
					add("public ");
				add("function");
				if (name != null)
					add(" " + name);
				add("(");
				var first = true;
				for (a in params) {
					if (first)
						first = false
					else
						add(", ");
					addArgument(a);
				}
				add(")");
				addType(ret);
				add(" ");
				expr(e);
			case EReturn(e):
				add("return");
				if (e != null) {
					add(" ");
					expr(e);
				}
			case EImport(v, as):
				add("import " + v);
				if (as != null)
					add(" as " + as);
			case EClass(name, fields, extend, interfaces):
				add("class " + name);
				if (extend != null)
					add(" extends " + extend);
				for (_interface in interfaces)
					add(" implements " + _interface);
				add(" {");
				if (fields.length > 0) {
					incrementIndent();
					add("\n");
					for (f in fields) {
						add(tabs);
						expr(f);
						add(";\n");
					}
					decrementIndent();
					add(tabs);
				}
				add("}");
			case EArray(e, index):
				exprFieldBase(e);
				add("[");
				expr(index);
				add("]");
			case EArrayDecl(el):
				add("[");
				var first = true;
				for (e in el) {
					if (first)
						first = false
					else
						add(", ");
					expr(e);
				}
				add("]");
			case ENew(cl, args):
				add("new " + cl + "(");
				var first = true;
				for (e in args) {
					if (first)
						first = false
					else
						add(", ");
					expr(e);
				}
				add(")");
			case EThrow(e):
				add("throw ");
				expr(e);
			case ETry(e, v, t, ecatch):
				add("try ");
				expr(e);
				add(" catch( " + v);
				addType(t);
				add(") ");
				expr(ecatch);
			case EObject(fl):
				if (fl.length == 0) {
					add("{}");
					return;
				}
				incrementIndent();
				add("{\n");
				for (i => f in fl) {
					add(tabs);
					add(f.name + " : ");
					expr(f.e);
					if (i < fl.length - 1)
						add(",");
					add("\n");
				}
				decrementIndent();
				add(tabs);
				add("}");
			case ETernary(c, e1, e2):
				expr(c);
				add(" ? ");
				expr(e1);
				add(" : ");
				expr(e2);
			case ESwitch(e, cases, def):
				add("switch ");
				expr(e);
				add(" {");
				incrementIndent();
				// The parser represents an unguarded `case _:` BOTH as a wildcard case and
				// as the hoisted defaultExpr. Emitting `default:` as well would produce two
				// defaults on re-parse (rejected), so the wildcard case already carries it.
				var hasWildcardCase = false;
				for (c in cases)
					if (c.ifExpr == null)
						for (v in c.values)
							switch (Tools.expr(v)) {
								case EIdent("_"): hasWildcardCase = true;
								default:
							}
				for (c in cases) {
					add("\n");
					add(tabs);
					add("case ");
					var first = true;
					for (v in c.values) {
						if (first)
							first = false
						else
							// or-pattern alternatives (T1): one SwitchCase.values entry per alternative
							add(" | ");
						// A bare EBinop/ETernary value would re-parse differently once the
						// parser supports or-patterns (case 1 | 2 vs case (1 | 2)); keep it atomic.
						switch (Tools.expr(v)) {
							case EBinop(_, _, _) | ETernary(_, _, _):
								add("(");
								expr(v);
								add(")");
							default:
								expr(v);
						}
					}
					// guarded case: the parser stores the guard in SwitchCase.ifExpr
					if (c.ifExpr != null) {
						add(" if ");
						expr(c.ifExpr);
					}
					add(": ");
					expr(c.expr);
					add(";");
				}
				if (def != null && !hasWildcardCase) {
					add("\n");
					add(tabs);
					add("default: ");
					expr(def);
					add(";");
				}
				decrementIndent();
				if (cases.length > 0) {
					add("\n");
					add(tabs);
				}
				add("}");
			case EMeta(name, args, e):
				add("@");
				add(name);
				if (args != null && args.length > 0) {
					add("(");
					var first = true;
					for (a in args) {
						if (first)
							first = false
						else
							add(", ");
						expr(a);
					}
					add(")");
				}
				add(" ");
				expr(e);
			case ECheckType(e, t):
				add("(");
				expr(e);
				add(" : ");
				type(t);
				add(")");
			case EEnum(name, params):
				if (params.length == 0) {
					add("enum " + name + " {}");
					return;
				}
				add("enum " + name + " {\n");
				incrementIndent();
				for (p in params) {
					add(tabs);
					switch p {
						case EConstructor(name, args):
							add(name);
							add("(");
							for (a in args)
								addArgument(a);
							add(")");
						case ESimple(name):
							add(name);
					}
					add(";\n");
				}
				decrementIndent();
				add(tabs);
				add("}");
			case EDirectValue(value):
				add("<Internal Value " + value + ">");
			case EUsing(name):
				add("using ");
				add(name);
		}
	}

	/**
	 * Re-escapes a string literal so it parses back to exactly the same value.
	 * Backslash and '$' matter as much as the quote/newline escapes: the parser
	 * treats '\' as an escape introducer (unknown escapes are errors) and '$'
	 * as string-interpolation start.
	 */
	/**
	 * Prints the target of a postfix operator (`.`/`[]`). A block expression
	 * returned by the array-comprehension desugaring must be parenthesised,
	 * otherwise the parser drops the postfix operator and the meaning changes.
	 */
	function exprFieldBase(e: Expr) {
		switch (Tools.expr(e)) {
			case EBlock(_):
				add("(");
				expr(e);
				add(")");
			default:
				expr(e);
		}
	}

	static function quoteString(s: String): String {
		var b = new StringBuf();
		b.add('"');
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			switch (c) {
				case 34: b.add('\\"'); // "
				case 92: b.add('\\\\'); // backslash
				case 36: b.add(String.fromCharCode(36) + String.fromCharCode(36)); // $ -> $$
				case 10: b.add('\\n');
				case 13: b.add('\\r');
				case 9: b.add('\\t');
				default: b.addChar(c);
			}
		}
		b.add('"');
		return b.toString();
	}

	inline function incrementIndent() {
		tabs += indent;
	}

	inline function decrementIndent() {
		tabs = tabs.substr(indent.length);
	}

	public static function toString(e: Expr) {
		return new Printer().exprToString(e);
	}

	public static function errorToString(e: Expr.Error, showPos: Bool = true) {
		var message = switch (#if hscriptPos e.e #else e #end) {
			case EInvalidChar(c): "Invalid character: '" + (StringTools.isEof(c) ? "EOF" : String.fromCharCode(c)) + "' (" + c + ")";
			case EUnexpected(s): "Unexpected token: \"" + s + "\"";
			case EUnterminatedString: "Unterminated string";
			case EUnterminatedComment: "Unterminated comment";
			case EInvalidPreprocessor(str): "Invalid preprocessor (" + str + ")";
			case EUnknownVariable(v): "Unknown variable: " + v;
			case EInvalidIterator(v): "Invalid iterator: " + v;
			case EInvalidOp(op): "Invalid operator: " + op;
			case EInvalidAccess(f): "Invalid access to field " + f;
			case ECustom(msg): msg;
			case EInvalidClass(className): "Invalid class: " + className;
			case EAlreadyExistingClass(className): "Class already exists: " + className;
			default: "Unknown Error.";
		};
		#if hscriptPos
		if (showPos)
			return e.origin + ":" + e.line + ": " + message;
		else
			return message;
		#else
		return message;
		#end
	}
}
