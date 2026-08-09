/*
 * hscript-seiun — SeiunEngine's merged HaxeScript runtime (MIT).
 *
 * Derivative work merged from these MIT-licensed projects:
 *   hscript (Haxe Foundation), hscript-iris (crowplexus, Ne_Eo),
 *   hscript-improved (FNF-CNE-Devs), hscript-plus (Dlean Jeans).
 * See LICENSE and NOTICE for details.
 */
package hscript;

/**
 * Helpers for script-to-script class inheritance (hscript-plus style, MIT).
 *
 * When a script class `class Bar extends Foo {}` is instantiated, the instance
 * is a plain Dynamic object carrying:
 *   - `__sname__`: the script class name (marker / debug info)
 *   - `super`    : the parent instance (prototype-chain equivalent)
 *   - `__interp` : the Interp that holds the evaluated fields/methods
 */
class DynamicClass {
	public static function create(name:String, ?superObj:Dynamic):Dynamic {
		return {__sname__: name, super: superObj};
	}

	public static inline function isDynamicObject(o:Dynamic):Bool {
		return o != null && Type.typeof(o) == TObject && Reflect.hasField(o, "__sname__") && Reflect.hasField(o, "super");
	}

	public static inline function getSuperOf(o:Dynamic):Dynamic {
		return o == null ? null : Reflect.field(o, "super");
	}

	/**
	 * Resolve a field, walking the `super` chain (prototype-style).
	 * Script-class fields live in the instance's `__interp.variables`, so those
	 * are checked before walking up the chain.
	 */
	public static function getField(o:Dynamic, f:String):Dynamic {
		if (o == null)
			return null;

		var v:Dynamic = Reflect.field(o, f);
		if (v != null)
			return v;

		var ip:Dynamic = Reflect.field(o, "__interp");
		if (ip != null) {
			if (ip.variables != null && ip.variables.exists(f))
				return ip.variables.get(f);
			if (ip.publicVariables != null && ip.publicVariables.exists(f))
				return ip.publicVariables.get(f);
			if (ip.staticVariables != null && ip.staticVariables.exists(f))
				return ip.staticVariables.get(f);
		}

		var sup:Dynamic = Reflect.field(o, "super");
		if (sup != null)
			return getField(sup, f);

		return null;
	}

	/**
	 * Assign a field on a script-class instance. If the field already exists in
	 * the instance's interp variables it is updated there (so methods see the
	 * change); otherwise a plain own-field is created.
	 */
	public static function setField(o:Dynamic, f:String, v:Dynamic):Dynamic {
		if (o == null)
			return v;

		var ip:Dynamic = Reflect.field(o, "__interp");
		if (ip != null) {
			var l:Dynamic = ip.locals != null ? ip.locals.get(f) : null;
			if (ip.variables != null && ip.variables.exists(f)) {
				if (l != null) l.r = v;
				ip.variables.set(f, v);
				return v;
			}
			if (ip.publicVariables != null && ip.publicVariables.exists(f)) {
				if (l != null) l.r = v;
				ip.publicVariables.set(f, v);
				return v;
			}
			if (ip.staticVariables != null && ip.staticVariables.exists(f)) {
				if (l != null) l.r = v;
				ip.staticVariables.set(f, v);
				return v;
			}
		}

		Reflect.setField(o, f, v);
		return v;
	}
}
