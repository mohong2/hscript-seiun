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
import hscript.Types.ByteInt;
import haxe.Serializer;
import haxe.Unserializer;

enum abstract BytesExpr(ByteInt) from ByteInt to ByteInt {
	var EIdent = 0;
	var EVar = 1;
	var EConst = 2;
	var EParent = 3;
	var EBlock = 4;
	var EField = 5;
	var EBinop = 6;
	var EUnop = 7;
	var ECall = 8;
	var EIf = 9;
	var EWhile = 10;
	var EFor = 11;
	var EBreak = 12;
	var EContinue = 13;
	var EFunction = 14;
	var EReturn = 15;
	var EArray = 16;
	var EArrayDecl = 17;
	var ENew = 18;
	var EThrow = 19;
	var ETry = 20;
	var EObject = 21;
	var ETernary = 22;
	var ESwitch = 23;
	var EDoWhile = 24;
	var EMeta = 25;
	var ECheckType = 26;
	var EImport = 27;
	var EEnum = 28;
	var EDirectValue = 29;
	var EUsing = 30;
	var EClass = 31;
}

enum abstract BytesConst(ByteInt) from ByteInt to ByteInt {
	var CInt = 0;
	var CIntByte = 1;
	var CFloat = 2;
	var CString = 3;
	#if !haxe3
	var CInt32 = 4;
	#end
}

/** Sub-tags used by the CType codec (not ExprDef tags). */
enum abstract BytesCType(ByteInt) from ByteInt to ByteInt {
	var CTPath = 0;
	var CTFun = 1;
	var CTAnon = 2;
	var CTExtend = 3;
	var CTParent = 4;
	var CTOpt = 5;
	var CTNamed = 6;
	var CTIntersection = 7;
}

enum abstract BytesIntSize(ByteInt) from ByteInt to ByteInt {
	var I8;
	var I16;
	var I32;
	var N8;
	var N16;
	var N32;
}

class Bytes {
	/**
		Cache format version, written as the first byte of every stream and
		checked by decode(). 255 cannot collide with a pre-versioning cache:
		those started either with the string-table marker 0 (hscriptPos) or with
		an ExprDef tag in 0...31. Bump this whenever the layout changes; old
		streams then fail loudly instead of decoding into a corrupt tree.
	**/
	public static inline var FORMAT_VERSION = 255;

	var bin: haxe.io.Bytes;
	var bout: haxe.io.BytesBuffer;
	var pin: Int;
	var hstrings: #if haxe3 Map<String, Int> #else Hash<Int> #end;
	var strings: Array<String>;
	var nstrings: Int;
	var dstrings: Int;

	var opMap: Map<String, Int>;

	function new(?bin) {
		this.bin = bin;
		pin = 0;
		bout = new haxe.io.BytesBuffer();
		hstrings = #if haxe3 new Map() #else new Hash() #end;
		strings = [null];
		nstrings = 1;
		dstrings = 1;

		opMap = new Map();
		opMap.set("+", 0);
		opMap.set("-", 1);
		opMap.set("*", 2);
		opMap.set("/", 3);
		opMap.set("%", 4);
		opMap.set("&", 5);
		opMap.set("|", 6);
		opMap.set("^", 7);
		opMap.set("<<", 8);
		opMap.set(">>", 9);
		opMap.set(">>>", 10);
		opMap.set("==", 11);
		opMap.set("!=", 12);
		opMap.set(">=", 13);
		opMap.set("<=", 14);
		opMap.set(">", 15);
		opMap.set("<", 16);
		opMap.set("||", 17);
		opMap.set("&&", 18);
		opMap.set("=", 19);
		opMap.set("??", 20);
		opMap.set("...", 21);
		// Extra codes for operators the parser can emit but the original table
		// lacked: `=>` (map literals / key-value for) and the `++`/`--` unaries.
		// Without them Bytes.encode threw "Invalid operator".
		opMap.set("=>", 23);
		// unary
		opMap.set("!", 22);
		opMap.set("~", 24);
		opMap.set("++", 25);
		opMap.set("--", 26);

		for (key => value in opMap)
			opMap.set(key, value << 1); // make place for the isAssign
	}

	function doEncodeOp(op: String) {
		var isAssign = !opMap.exists(op) && op.charCodeAt(op.length - 1) == "=".code;
		var _op = op;
		if (isAssign) {
			op = op.substr(0, op.length - 1);
		}
		var v = opMap.get(op);
		if (v == null)
			throw "Invalid operator " + _op;
		// Op codes are stored pre-shifted by one so the low bit carries isAssign.
		// Not OR-ing it in silently rewrote `a += b` as `a + b`.
		bout.addByte(v | (isAssign ? 1 : 0));
	}

	function doDecodeOp(): String {
		var v = bin.get(pin++);
		var isAssign = (v & 1) != 0;
		var code = v >> 1;
		for (key => value in opMap)
			// opMap values are pre-shifted (see the constructor), so compare the
			// unshifted code; the old `value == v` test only ever matched "+".
			if ((value >> 1) == code)
				return key + (isAssign ? "=" : "");
		throw "Invalid operator " + v;
	}

	function doEncodeString(v: String) {
		var vid = hstrings.get(v);
		if (vid == null) {
			if (nstrings == 256) {
				hstrings = #if haxe3 new Map() #else new Hash() #end;
				nstrings = 1;
			}
			hstrings.set(v, nstrings);
			bout.addByte(0);
			var vb = haxe.io.Bytes.ofString(v);
			// 255 is an escape meaning "length follows as an encoded Int", so
			// literals longer than 254 bytes no longer truncate and desync.
			if (vb.length < 255)
				bout.addByte(vb.length);
			else {
				bout.addByte(255);
				doEncodeInt(vb.length);
			}
			bout.add(vb);
			nstrings++;
		} else
			bout.addByte(vid);
	}

	function doDecodeString() {
		var id = bin.get(pin++);
		if (id == 0) {
			var len = bin.get(pin++);
			if (len == 255)
				len = doDecodeInt();
			var str = #if (haxe_ver < 3.103) bin.readString(pin, len); #else bin.getString(pin, len); #end
			pin += len;
			// Mirror doEncodeString's reset exactly: the encoder opens a new table
			// right before handing out id 256, so the 255th distinct string keeps
			// id 255. Resetting on strings.length disagreed with that and corrupted
			// every cache containing >= 255 distinct strings.
			if (dstrings == 256) {
				strings = [null];
				dstrings = 1;
			}
			strings.push(str);
			dstrings++;
			return str;
		}
		return strings[id];
	}

	function doEncodeInt(v: Int) {
		var isNeg = v < 0;
		if (isNeg)
			v = -v;
		if (v >= 0 && v <= 255) {
			bout.addByte(isNeg ? N8 : I8);
			bout.addByte(v);
		} else if (v >= 0 && v <= 65535) {
			bout.addByte(isNeg ? N16 : I16);
			bout.addByte(v & 0xFF);
			bout.addByte((v >> 8) & 0xFF);
		} else {
			bout.addByte(isNeg ? N32 : I32);
			bout.addInt32(v);
		}
	}

	function doEncodeBool(v: Bool) {
		bout.addByte(v ? 1 : 0);
	}

	// ── CType codec ───────────────────────────────────────────────────────
	// Types used to be dropped entirely, which silently changed runtime
	// behaviour for `catch (e:T)` and `cast(x, T)` after a cache hit.

	function doEncodeCTypeOpt(t: Null<CType>) {
		if (t == null)
			bout.addByte(0);
		else {
			bout.addByte(1);
			doEncodeCType(t);
		}
	}

	function doDecodeCTypeOpt(): Null<CType> {
		return bin.get(pin++) == 0 ? null : doDecodeCType();
	}

	function doEncodeMetadata(m: Metadata) {
		if (m == null) {
			doEncodeInt(0);
			return;
		}
		doEncodeInt(m.length);
		for (e in m) {
			doEncodeString(e.name);
			if (e.params == null)
				doEncodeInt(0);
			else {
				doEncodeInt(e.params.length);
				for (p in e.params)
					doEncode(p);
			}
		}
	}

	function doDecodeMetadata(): Metadata {
		var n = doDecodeInt();
		var m:Metadata = [];
		for (i in 0...n) {
			var name = doDecodeString();
			var pn = doDecodeInt();
			var params:Array<Expr> = [];
			for (j in 0...pn)
				params.push(doDecode());
			m.push({name: name, params: params});
		}
		return m;
	}

	function doEncodeTypePath(p: TypePath) {
		if (p.pack == null)
			doEncodeInt(0);
		else {
			doEncodeInt(p.pack.length);
			for (s in p.pack)
				doEncodeString(s);
		}
		doEncodeString(p.name);
		if (p.params == null)
			doEncodeInt(0);
		else {
			doEncodeInt(p.params.length);
			for (t in p.params)
				doEncodeCType(t);
		}
		doEncodeString(p.sub == null ? "" : p.sub);
	}

	function doDecodeTypePath(): TypePath {
		var pn = doDecodeInt();
		var pack:Array<String> = [];
		for (i in 0...pn)
			pack.push(doDecodeString());
		var name = doDecodeString();
		var n = doDecodeInt();
		var params:Array<CType> = n == 0 ? null : [];
		for (i in 0...n)
			params.push(doDecodeCType());
		var sub = doDecodeString();
		return {pack: pack, name: name, params: params, sub: sub == "" ? null : sub};
	}

	function doEncodeAnonFields(fields: Array<{name:String, t:CType, ?meta:Metadata}>) {
		doEncodeInt(fields == null ? 0 : fields.length);
		if (fields == null)
			return;
		for (f in fields) {
			doEncodeString(f.name);
			doEncodeCType(f.t);
			doEncodeMetadata(f.meta);
		}
	}

	function doDecodeAnonFields(): Array<{name:String, t:CType, ?meta:Metadata}> {
		var n = doDecodeInt();
		var out:Array<{name:String, t:CType, ?meta:Metadata}> = [];
		for (i in 0...n) {
			var name = doDecodeString();
			var t = doDecodeCType();
			var meta = doDecodeMetadata();
			out.push({name: name, t: t, meta: meta});
		}
		return out;
	}

	function doEncodeCType(t: CType) {
		switch (t) {
			case CTPath(path):
				bout.addByte(BytesCType.CTPath);
				doEncodeTypePath(path);
			case CTFun(args, ret):
				bout.addByte(BytesCType.CTFun);
				doEncodeInt(args == null ? 0 : args.length);
				if (args != null)
					for (a in args)
						doEncodeCType(a);
				doEncodeCType(ret);
			case CTAnon(fields):
				bout.addByte(BytesCType.CTAnon);
				doEncodeAnonFields(fields);
			case CTExtend(types, fields):
				bout.addByte(BytesCType.CTExtend);
				doEncodeInt(types == null ? 0 : types.length);
				if (types != null)
					for (tp in types)
						doEncodeTypePath(tp);
				doEncodeAnonFields(fields);
			case CTParent(t):
				bout.addByte(BytesCType.CTParent);
				doEncodeCType(t);
			case CTOpt(t):
				bout.addByte(BytesCType.CTOpt);
				doEncodeCType(t);
			case CTNamed(n, t):
				bout.addByte(BytesCType.CTNamed);
				doEncodeString(n);
				doEncodeCType(t);
			case CTIntersection(types):
				bout.addByte(BytesCType.CTIntersection);
				doEncodeInt(types == null ? 0 : types.length);
				if (types != null)
					for (t in types)
						doEncodeCType(t);
		}
	}

	function doDecodeCType(): CType {
		return switch (bin.get(pin++)) {
			case CTPath:
				CTPath(doDecodeTypePath());
			case CTFun:
				var n = doDecodeInt();
				var args:Array<CType> = [];
				for (i in 0...n)
					args.push(doDecodeCType());
				CTFun(args, doDecodeCType());
			case CTAnon:
				CTAnon(doDecodeAnonFields());
			case CTExtend:
				var n = doDecodeInt();
				var types:Array<TypePath> = [];
				for (i in 0...n)
					types.push(doDecodeTypePath());
				CTExtend(types, doDecodeAnonFields());
			case CTParent:
				CTParent(doDecodeCType());
			case CTOpt:
				CTOpt(doDecodeCType());
			case CTNamed:
				var n = doDecodeString();
				CTNamed(n, doDecodeCType());
			case CTIntersection:
				var n = doDecodeInt();
				var types:Array<CType> = [];
				for (i in 0...n)
					types.push(doDecodeCType());
				CTIntersection(types);
			default:
				throw "Invalid CType code " + bin.get(pin - 1);
		}
	}

	function doEncodeConst(c: Const) {
		switch (c) {
			case CInt(v):
				if (v >= 0 && v <= 255) {
					bout.addByte(CIntByte);
					bout.addByte(v & 0xFF);
				} else {
					bout.addByte(CInt);
					doEncodeInt(v);
				}
			case CFloat(f):
				bout.addByte(CFloat);
				doEncodeString(Std.string(f));
			case CString(s):
				bout.addByte(CString);
				doEncodeString(s);
			#if !haxe3
			case CInt32(v):
				bout.addByte(CInt32);
				var mid = haxe.Int32.toInt(haxe.Int32.and(v, haxe.Int32.ofInt(0xFFFFFF)));
				bout.addByte(mid & 0xFF);
				bout.addByte((mid >> 8) & 0xFF);
				bout.addByte(mid >> 16);
				bout.addByte(haxe.Int32.toInt(haxe.Int32.ushr(v, 24)));
			#end
		}
	}

	function doDecodeInt() {
		var size = cast(bin.get(pin++), BytesIntSize);
		var i = switch (size) {
			case I8 | N8: bin.get(pin++);
			case I16 | N16: bin.get(pin++) | bin.get(pin++) << 8;
			case I32 | N32: bin.getInt32(pin);
		}
		switch (size) {
			case I8 | N8:
			case I16 | N16:
			case I32 | N32:
				pin += 4;
		}
		switch (size) {
			case N8 | N16 | N32:
				i = -i;
			default:
		}
		return i;
	}

	function doDecodeConst(): Const {
		return switch (bin.get(pin++)) {
			case CIntByte:
				CInt(bin.get(pin++));
			case CInt:
				var i = doDecodeInt();
				CInt(i);
			case CFloat:
				var s = doDecodeString();
				// Std.string() writes non-finite floats as "infinity"/"nan", which
				// Std.parseFloat() cannot read back, so map them explicitly.
				CFloat(switch (s) {
					case "infinity", "Infinity", "inf": Math.POSITIVE_INFINITY;
					case "-infinity", "-Infinity", "-inf": Math.NEGATIVE_INFINITY;
					case "nan", "NaN": Math.NaN;
					default: Std.parseFloat(s);
				});
			case CString:
				CString(doDecodeString());
			#if !haxe3
			case CInt32:
				var i = bin.get(pin) | (bin.get(pin + 1) << 8) | (bin.get(pin + 2) << 16);
				var j = bin.get(pin + 3);
				pin += 4;
				CInt32(haxe.Int32.or(haxe.Int32.ofInt(i), haxe.Int32.shl(haxe.Int32.ofInt(j), 24)));
			#end
			default:
				throw "Invalid code " + bin.get(pin - 1);
		}
	}

	function doDecodeArg(): Argument {
		var name = doDecodeString();
		var flags = bin.get(pin++);
		var value = doDecode();
		var t = doDecodeCTypeOpt();
		return {
			name: name,
			opt: (flags & 1) != 0,
			rest: (flags & 2) != 0,
			value: value,
			t: t
		};
	}

	function doEncodeExprType(t: BytesExpr) {
		/*switch (t) {
			case EIdent:
				bout.addString("EIdent");
			case EVar:
				bout.addString("EVar");
			case EConst:
				bout.addString("EConst");
			case EParent:
				bout.addString("EParent");
			case EBlock:
				bout.addString("EBlock");
			case EField:
				bout.addString("EField");
			case EBinop:
				bout.addString("EBinop");
			case EUnop:
				bout.addString("EUnop");
			case ECall:
				bout.addString("ECall");
			case EIf:
				bout.addString("EIf");
			case EWhile:
				bout.addString("EWhile");
			case EFor:
				bout.addString("EFor");
			case EBreak:
				bout.addString("EBreak");
			case EContinue:
				bout.addString("EContinue");
			case EFunction:
				bout.addString("EFunction");
			case EReturn:
				bout.addString("EReturn");
			case EArray:
				bout.addString("EArray");
			case EArrayDecl:
				bout.addString("EArrayDecl");
			case ENew:
				bout.addString("ENew");
			case EThrow:
				bout.addString("EThrow");
			case ETry:
				bout.addString("ETry");
			case EObject:
				bout.addString("EObject");
			case ETernary:
				bout.addString("ETernary");
			case ESwitch:
				bout.addString("ESwitch");
			case EDoWhile:
				bout.addString("EDoWhile");
			case EMeta:
				bout.addString("EMeta");
			case ECheckType:
				bout.addString("ECheckType");
			case EImport:
				bout.addString("EImport");
			case EEnum:
				bout.addString("EEnum");
			case EDirectValue:
				bout.addString("EDirectValue");
		}*/
		bout.addByte(t);
	}

	function doEncodeArg(a: Argument) {
		doEncodeString(a.name);
		// Bit 0 is the historical opt flag (0/1) so caches written before the rest
		// flag existed decode identically; bit 1 carries `...rest`, which used to
		// be dropped and made rest-only functions execute with a null rest array.
		bout.addByte((a.opt ? 1 : 0) | (a.rest ? 2 : 0));
		if (a.value == null)
			bout.addByte(255);
		else
			doEncode(a.value);
		doEncodeCTypeOpt(a.t);
	}

	function doEncode(e: Expr) {
		#if hscriptPos
		doEncodeString(e.origin);
		doEncodeInt(e.line);
		var e = e.e;
		#end
		switch (e) {
			case EIgnore(_):
				// EIgnore is a runtime no-op (see Interp.expr). Encode it as an empty
				// block so the stream stays aligned and re-encoding is stable without
				// introducing a new tag.
				doEncodeExprType(EBlock);
				doEncodeInt(0);
			case EConst(c):
				doEncodeExprType(EConst);
				doEncodeConst(c);
			case EIdent(v):
				doEncodeExprType(EIdent);
				doEncodeString(v);
			case EVar(n, t, e, c, isPublic, isStatic):
				doEncodeExprType(EVar);
				doEncodeString(n);
				doEncodeCTypeOpt(t);
				if (e == null)
					bout.addByte(255);
				else
					doEncode(e);
				doEncodeBool(c);
				doEncodeBool(isPublic);
				doEncodeBool(isStatic);
			case EParent(e):
				doEncodeExprType(EParent);
				doEncode(e);
			case EBlock(el):
				doEncodeExprType(EBlock);
				doEncodeInt(el.length);
				for (e in el)
					doEncode(e);
			case EField(e, f, s):
				doEncodeExprType(EField);
				doEncode(e);
				doEncodeString(f);
				doEncodeBool(s);
			case EBinop(op, e1, e2):
				doEncodeExprType(EBinop);
				doEncodeOp(op);
				doEncode(e1);
				doEncode(e2);
			case EUnop(op, prefix, e):
				doEncodeExprType(EUnop);
				doEncodeOp(op);
				doEncodeBool(prefix);
				doEncode(e);
			case ECall(e, el):
				doEncodeExprType(ECall);
				doEncode(e);
				doEncodeInt(el.length);
				for (e in el)
					doEncode(e);
			case EIf(cond, e1, e2):
				doEncodeExprType(EIf);
				doEncode(cond);
				doEncode(e1);
				if (e2 == null)
					bout.addByte(255);
				else
					doEncode(e2);
			case EWhile(cond, e):
				doEncodeExprType(EWhile);
				doEncode(cond);
				doEncode(e);
			case EDoWhile(cond, e):
				doEncodeExprType(EDoWhile);
				doEncode(cond);
				doEncode(e);
			case EFor(v, it, e, ithv):
				doEncodeExprType(EFor);
				doEncodeString(v);
				doEncode(it);
				doEncode(e);
				doEncodeString(ithv == null ? "" : ithv);
			case EBreak:
				doEncodeExprType(EBreak);
			case EContinue:
				doEncodeExprType(EContinue);
			case EFunction(params, e, name, ret, isPublic, isStatic, isOverride):
				doEncodeExprType(EFunction);
				doEncodeInt(params.length);
				for (p in params)
					doEncodeArg(p);
				doEncode(e);
				doEncodeString(name == null ? "" : name);
				doEncodeCTypeOpt(ret);
				doEncodeBool(isPublic);
				doEncodeBool(isStatic);
				doEncodeBool(isOverride);
			case EReturn(e):
				doEncodeExprType(EReturn);
				if (e == null)
					bout.addByte(255);
				else
					doEncode(e);
			case EArray(e, index):
				doEncodeExprType(EArray);
				doEncode(e);
				doEncode(index);
			case EArrayDecl(el):
				doEncodeExprType(EArrayDecl);
				doEncodeInt(el.length);
				for (e in el)
					doEncode(e);
			case ENew(cl, params):
				doEncodeExprType(ENew);
				doEncodeString(cl);
				doEncodeInt(params.length);
				for (e in params)
					doEncode(e);
			case EThrow(e):
				doEncodeExprType(EThrow);
				doEncode(e);
			case ETry(e, v, t, ecatch):
				doEncodeExprType(ETry);
				doEncode(e);
				doEncodeString(v);
				doEncodeCTypeOpt(t);
				doEncode(ecatch);
			case EObject(fl):
				doEncodeExprType(EObject);
				doEncodeInt(fl.length);
				for (f in fl) {
					doEncodeString(f.name);
					doEncode(f.e);
				}
			case ETernary(cond, e1, e2):
				doEncodeExprType(ETernary);
				doEncode(cond);
				doEncode(e1);
				doEncode(e2);
			case ESwitch(e, cases, def):
				doEncodeExprType(ESwitch);
				doEncode(e);
				for (c in cases) {
					if (c.values.length == 0)
						throw "assert";
					for (v in c.values)
						doEncode(v);
					bout.addByte(255);
					doEncode(c.expr);
					// An unguarded case has ifExpr == null; doEncode(null) threw
					// "field access on null" before it even reached the writer.
					if (c.ifExpr == null)
						bout.addByte(255);
					else
						doEncode(c.ifExpr);
				}
				bout.addByte(255);
				if (def == null)
					bout.addByte(255)
				else
					doEncode(def);
			case EMeta(name, args, e):
				doEncodeExprType(EMeta);
				doEncodeString(name);
				doEncodeInt(args == null ? 0 : args.length + 1);
				if (args != null)
					for (e in args)
						doEncode(e);
				doEncode(e);
			case ECheckType(e, t):
				doEncodeExprType(ECheckType);
				doEncode(e);
				doEncodeCType(t);
			case EEnum(name, fields):
				doEncodeExprType(EEnum);
				doEncodeString(name);
				doEncodeInt(fields.length);
				for (f in fields)
					switch (f) {
						case ESimple(name):
							bout.addByte(0);
							doEncodeString(name);
						case EConstructor(name, args):
							bout.addByte(1);
							doEncodeString(name);
							doEncodeInt(args.length);
							for (a in args)
								doEncodeArg(a);
					}
			case EDirectValue(value):
				doEncodeExprType(EDirectValue);
				doEncodeString(Serializer.run(value));
			case EImport(v, as):
				doEncodeExprType(EImport);
				doEncodeString(v);
				// An unaliased import stores as == null and the string table has no
				// null entry, so encode ""; a real import alias can never be empty.
				doEncodeString(as == null ? "" : as);
			case EUsing(name):
				doEncodeExprType(EUsing);
				doEncodeString(name);
			case EClass(name, fields, extend, interfaces):
				doEncodeExprType(EClass);
				doEncodeString(name);
				doEncodeInt(fields.length);
				for (e in fields)
					doEncode(e);
				doEncodeString(extend == null ? "" : extend);
				doEncodeInt(interfaces.length);
				for (i in interfaces)
					doEncodeString(i);
		}
		// bout.addString("__||__");
	}

	function doDecodeBool(): Bool {
		return bin.get(pin++) != 0;
	}

	function doDecode(): Expr {
	#if hscriptPos
	if (bin.get(pin) == 255) {
		pin++;
		return null;
	}
	var origin = doDecodeString();
	var line = doDecodeInt();
	return {
		e: _doDecode(),
		pmin: 0,
		pmax: 0,
		origin: origin,
		line: line
	};
	} function _doDecode(): ExprDef {
	#end
		var type: BytesExpr = bin.get(pin++);
		return switch (type) {
			case EConst:
				EConst(doDecodeConst());
			case EIdent:
				EIdent(doDecodeString());
			case EVar:
				var v = doDecodeString();
				var t = doDecodeCTypeOpt();
				var e = doDecode();
				var c = doDecodeBool();
				var isPublic = doDecodeBool();
				var isStatic = doDecodeBool();
				EVar(v, t, e, c, isPublic, isStatic);
			case EParent:
				EParent(doDecode());
			case EBlock:
				var a = new Array();
				var len = doDecodeInt();
				for (i in 0...len)
					a.push(doDecode());
				EBlock(a);
			case EField:
				var e = doDecode();
				var name = doDecodeString();
				var s = doDecodeBool();
				EField(e, name, s);
			case EBinop:
				var op = doDecodeOp();
				var e1 = doDecode();
				EBinop(op, e1, doDecode());
			case EUnop:
				var op = doDecodeOp();
				var prefix = doDecodeBool();
				EUnop(op, prefix, doDecode());
			case ECall:
				var e = doDecode();
				var params = new Array();
				for (i in 0...doDecodeInt())
					params.push(doDecode());
				ECall(e, params);
			case EIf:
				var cond = doDecode();
				var e1 = doDecode();
				EIf(cond, e1, doDecode());
			case EWhile:
				var cond = doDecode();
				EWhile(cond, doDecode());
			case EDoWhile:
				var cond = doDecode();
				EDoWhile(cond, doDecode());
			case EFor:
				var v = doDecodeString();
				var it = doDecode();
				var e = doDecode();
				var ithv = doDecodeString();
				EFor(v, it, e, ithv == "" ? null : ithv);
			case EBreak:
				EBreak;
			case EContinue:
				EContinue;
			case EFunction:
				var params = new Array<Argument>();
				for (i in 0...doDecodeInt())
					params.push(doDecodeArg());
				var e = doDecode();
				var name = doDecodeString();
				var ret = doDecodeCTypeOpt();
				var isPublic = doDecodeBool();
				var isStatic = doDecodeBool();
				var isOverride = doDecodeBool();
				EFunction(params, e, (name == "") ? null : name, ret, isPublic, isStatic, isOverride);
			case EReturn:
				EReturn(doDecode());
			case EArray:
				var e = doDecode();
				EArray(e, doDecode());
			case EArrayDecl:
				var el = new Array();
				var len = doDecodeInt();
				for (i in 0...len)
					el.push(doDecode());
				EArrayDecl(el);
			case ENew:
				var cl = doDecodeString();
				var el = new Array();
				for (i in 0...doDecodeInt())
					el.push(doDecode());
				ENew(cl, el);
			case EThrow:
				EThrow(doDecode());
			case ETry:
				var e = doDecode();
				var v = doDecodeString();
				var t = doDecodeCTypeOpt();
				ETry(e, v, t, doDecode());
			case EObject:
				var fl: Array<ObjectDecl> = [];
				var len = doDecodeInt();
				for (i in 0...len) {
					var name = doDecodeString();
					var e = doDecode();
					fl.push({name: name, e: e});
				}
				EObject(fl);
			case ETernary:
				var cond = doDecode();
				var e1 = doDecode();
				var e2 = doDecode();
				ETernary(cond, e1, e2);
			case ESwitch:
				var e = doDecode();
				var cases: Array<SwitchCase> = [];
				while (true) {
					var v = doDecode();
					if (v == null)
						break;
					var values = [v];
					while (true) {
						v = doDecode();
						if (v == null)
							break;
						values.push(v);
					}
					var expr = doDecode();
					var ifExpr = doDecode();
					cases.push({values: values, expr: expr, ifExpr: ifExpr});
				}
				var def = doDecode();
				ESwitch(e, cases, def);
			case EMeta:
				var name = doDecodeString();
				var count = doDecodeInt();
				var args = count == 0 ? null : [for (i in 0...count - 1) doDecode()];
				EMeta(name, args, doDecode());
			case ECheckType:
				ECheckType(doDecode(), doDecodeCType());
			case EEnum:
				var name = doDecodeString();
				var fields: Array<EnumType> = [];
				for (i in 0...doDecodeInt()) {
					switch (bin.get(pin++)) {
						case 0:
							var name = doDecodeString();
							fields.push(ESimple(name));
						case 1:
							var name = doDecodeString();
							var args: Array<Argument> = [];
							for (i in 0...doDecodeInt())
								args.push(doDecodeArg());
							fields.push(EConstructor(name, args));
						default:
							throw "Invalid code " + bin.get(pin - 1);
					}
				}
				EEnum(name, fields);
			case EDirectValue:
				var value = doDecodeString();
				EDirectValue(Unserializer.run(value));
			case EImport:
				var v = doDecodeString();
				var as = doDecodeString();
				EImport(v, as == "" ? null : as);
			case EUsing:
				var name = doDecodeString();
				EUsing(name);
			case EClass:
				var name = doDecodeString();
				var fields = new Array();
				var len = doDecodeInt();
				for (i in 0...len)
					fields.push(doDecode());
				var extend = doDecodeString();
				var interfaces = new Array<String>();
				var ilen = doDecodeInt();
				for (i in 0...ilen)
					interfaces.push(doDecodeString());
				EClass(name, fields, extend == "" ? null : extend, interfaces);
			case 255:
				null;
				// default:
				//	throw "Invalid code " + bin.get(pin - 1);
		}
	}

	public static function encode(e: Expr): haxe.io.Bytes {
		var b = new Bytes();
		b.bout.addByte(FORMAT_VERSION);
		b.doEncode(e);
		return b.bout.getBytes();
	}

	public static function decode(bytes: haxe.io.Bytes): Expr {
		if (bytes == null || bytes.length == 0)
			throw "Empty hscript bytes stream";
		var b = new Bytes(bytes);
		var version = bytes.get(0);
		if (version != FORMAT_VERSION)
			throw "Unsupported hscript bytes format version " + version
				+ " (this build writes/reads version " + FORMAT_VERSION + ")";
		b.pin = 1;
		return b.doDecode();
	}
}
