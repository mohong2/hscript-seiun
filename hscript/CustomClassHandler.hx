/*
 * hscript-seiun — SeiunEngine's merged HaxeScript runtime (MIT).
 *
 * Derivative work merged from these MIT-licensed projects:
 *   hscript (Haxe Foundation), hscript-iris (crowplexus, Ne_Eo),
 *   hscript-improved (FNF-CNE-Devs), hscript-plus (Dlean Jeans).
 * See LICENSE and NOTICE for details.
 */
package hscript;

using StringTools;

/**
 * Runtime handler for script-defined classes (`class Foo { ... }`).
 *
 * Ported from hscript-improved (FNF-CNE-Devs, MIT) and extended with
 * hscript-plus (Dlean Jeans, MIT) style script-to-script inheritance
 * (`class Bar extends Foo {}`
 * where `Foo` is another script class).
 *
 * `new Foo(...)` in scripts resolves `Foo` (via `Interp.customClasses`) to an
 * instance of this class and calls `hnew(args)`.
 */
class CustomClassHandler implements IHScriptCustomConstructor implements IHScriptCustomBehaviour {
	public static var staticHandler = new StaticHandler();

	public var ogInterp:Interp;
	public var name:String;
	public var fields:Array<Expr>;
	public var extend:String;
	public var interfaces:Array<String>;
	/** Static members evaluated once at class declaration (Haxe semantics). */
	public var staticFields:Map<String, Dynamic> = new Map();

	public function new(ogInterp:Interp, name:String, fields:Array<Expr>, ?extend:String, ?interfaces:Array<String>) {
		this.ogInterp = ogInterp;
		this.name = name;
		this.fields = fields;
		this.extend = extend;
		this.interfaces = interfaces == null ? [] : interfaces;
	}

	public function hget(name:String):Dynamic {
		if (staticFields.exists(name)) {
			// read the live static (it is shared with the declaring script's
			// Interp) instead of the snapshot taken at class-declaration time,
			// so `ClassName.field` sees writes made from constructors/methods
			if (ogInterp.staticVariables.exists(name))
				return ogInterp.staticVariables.get(name);
			return staticFields.get(name);
		}
		return Reflect.field(this, name);
	}

	public function hset(name:String, val:Dynamic):Dynamic {
		staticFields.set(name, val);
		if (ogInterp.staticVariables.exists(name))
			ogInterp.staticVariables.set(name, val);
		return val;
	}

	public function hnew(args:Array<Dynamic>):Dynamic {
		return buildInstance(args, false);
	}

	function buildInstance(args:Array<Dynamic>, skipConstructor:Bool):Dynamic {
		var interp = new Interp();
		interp.errorHandler = ogInterp.errorHandler;
		interp.importFailedCallback = ogInterp.importFailedCallback;
		interp.allowStaticVariables = ogInterp.allowStaticVariables;
		interp.allowPublicVariables = ogInterp.allowPublicVariables;
		interp.importEnabled = ogInterp.importEnabled;

		// script-to-script inheritance: walk up the chain of script classes
		// (`class C extends B extends A`). chain[0] is this class, the last entry
		// is the topmost ancestor, which either has no `extend` (TemplateClass
		// stand-in) or extends a real Haxe class / generated `_HSX` shadow class.
		var chain:Array<CustomClassHandler> = [this];
		var cursor:CustomClassHandler = this;
		while (true) {
			var parent:CustomClassHandler = cursor.extend == null ? null : cursor.ogInterp.customClasses.get(cursor.extend);
			if (parent == null)
				break;
			chain.push(parent);
			cursor = parent;
		}
		var top = chain[chain.length - 1];

		var baseClass:Class<Dynamic> = null;
		if (top.extend == null) {
			baseClass = TemplateClass;
		} else {
			// 1) macro shadow class (CUSTOM_CLASSES)  2) plain Haxe class
			baseClass = Type.resolveClass('${top.extend}_HSX');
			if (baseClass == null && Type.resolveClass(top.extend) != null)
				baseClass = Type.resolveClass(top.extend);
		}

		if (baseClass == null)
			ogInterp.error(EInvalidClass(top.extend));

		// TemplateClass is the zero-argument stand-in base for script classes without
		// a Haxe base: forwarding the script's args to Type.createInstance throws on
		// the eval target ("Something went wrong") before the script's own `new` runs
		// below. Real Haxe base classes still need their constructor args.
		var _class:Dynamic = Type.createInstance(baseClass, (baseClass == TemplateClass) ? [] : args);

		// capture the defining script's locals/variables so class methods can
		// access the same globals (FlxG, PlayState.instance, ...) and closures
		// NOTE: `LocalVar` (@:structInit) can't be referenced by name outside
		// Interp.hx (Haxe limitation), so use an equivalent anonymous struct.
		var capturedLocals:Map<String, {r:Dynamic, const:Bool}> = [];
		for (k => e in ogInterp.locals)
			if (e != null)
				capturedLocals.set(k, {r: e.r, const: e.const});

		var disallowCopy:Array<String> = baseClass != null ? Type.getInstanceFields(baseClass) : [];

		for (key => value in capturedLocals)
			if (!disallowCopy.contains(key))
				interp.locals.set(key, {r: value.r, const: value.const});
		for (key => value in ogInterp.variables)
			if (!disallowCopy.contains(key))
				interp.variables.set(key, value);
		for (key => value in ogInterp.imports)
			interp.imports.set(key, value);
		for (key => value in ogInterp.publicVariables)
			interp.publicVariables.set(key, value);
		// share by reference: `static var` / nested script classes are truly
		// shared across every instance of this script's classes
		interp.staticVariables = ogInterp.staticVariables;
		interp.customClasses = ogInterp.customClasses;

		// Evaluate ancestor fields first (Haxe initialises base fields before
		// derived ones) on this single instance, snapshotting the function table
		// after each level. `super` is then a scope over those snapshots, so
		// `super.method()` runs the ancestor implementation with `this` bound to
		// THIS instance and `super.new(...)` initialises this instance too, instead
		// of building a throw-away shadow parent instance + Interp for every `new`.
		var superScope:ScriptSuper = null;
		var level = chain.length - 1;
		while (level >= 1) {
			for (expr in chain[level].fields)
				@:privateAccess interp.exprReturn(expr);
			superScope = new ScriptSuper(interp, snapshotFunctions(interp), superScope);
			level--;
		}

		// evaluate this class's own fields
		for (expr in fields) {
			@:privateAccess interp.exprReturn(expr);
		}

		// `super` inside methods: the script-parent scope chain, or the static
		// handler used by `_HSX` shadow classes for `super.method()` calls
		interp.variables.set("super", superScope != null ? superScope : staticHandler);

		_class.__interp = interp;
		interp.scriptObject = _class;

		if (!skipConstructor) {
			var newFunc = interp.variables.get("new");
			if (newFunc != null)
				Reflect.callMethod(_class, newFunc, args);
		}

		return _class;
	}

	public function toString():String {
		return name;
	}

	/**
	 * Function-valued members currently visible in `interp` (variables +
	 * publicVariables). Used to snapshot one inheritance level's implementation
	 * before a derived level is evaluated over it.
	 */
	public static function snapshotFunctions(interp:Interp):Map<String, Dynamic> {
		var out = new Map<String, Dynamic>();
		for (name => value in interp.variables)
			if (Reflect.isFunction(value))
				out.set(name, value);
		for (name => value in interp.publicVariables)
			if (!out.exists(name) && Reflect.isFunction(value))
				out.set(name, value);
		return out;
	}
}

/**
 * Base class for script classes that don't extend anything.
 * All field access is routed through `hget`/`hset` → `__interp.variables`.
 */
class TemplateClass implements IHScriptCustomBehaviour {
	public var __interp:Interp;

	// explicit constructor so `Type.createInstance(TemplateClass, [])` always works
	public function new() {}

	public function hset(name:String, val:Dynamic):Dynamic {
		if (this.__interp.variables.exists("set_" + name))
			return this.__interp.variables.get("set_" + name)(val);
		// keep the depth-0 local in sync: method bodies read instance fields
		// through `Interp.locals` first, so updating only `variables` would make
		// `obj.field = x` invisible to later method calls.
		var local:Dynamic = this.__interp.locals.get(name);
		if (local != null)
			local.r = val;
		if (this.__interp.variables.exists(name)) {
			this.__interp.variables.set(name, val);
			return val;
		}
		if (this.__interp.publicVariables.exists(name)) {
			this.__interp.publicVariables.set(name, val);
			return val;
		}
		if (this.__interp.staticVariables.exists(name)) {
			this.__interp.staticVariables.set(name, val);
			return val;
		}
		Reflect.setProperty(this, name, val);
		return Reflect.field(this, name);
	}

	public function hget(name:String):Dynamic {
		if (this.__interp.variables.exists("get_" + name))
			return this.__interp.variables.get("get_" + name)();
		if (this.__interp.variables.exists(name))
			return this.__interp.variables.get(name);
		if (this.__interp.publicVariables.exists(name))
			return this.__interp.publicVariables.get(name);
		if (this.__interp.staticVariables.exists(name))
			return this.__interp.staticVariables.get(name);
		return Reflect.getProperty(this, name);
	}
}

/** Placeholder used for `super` in `_HSX` shadow classes. */
class StaticHandler {
	public function new() {}
}

/**
 * `super` view over one script-class inheritance level.
 *
 * `methods` is the function table captured in the *child* Interp right after
 * the ancestor level was evaluated, so calling one of them runs the ancestor
 * implementation with `this` bound to the child instance - the same behaviour
 * Haxe gives `super.method()`. Non-function members fall through to the child's
 * own state, because `super.x` and `this.x` are the same storage.
 */
class ScriptSuper implements IHScriptCustomBehaviour {
	var interp:Interp;
	var methods:Map<String, Dynamic>;
	var parent:ScriptSuper;

	public function new(interp:Interp, methods:Map<String, Dynamic>, parent:ScriptSuper) {
		this.interp = interp;
		this.methods = methods;
		this.parent = parent;
	}

	public function hget(name:String):Dynamic {
		if (name == "new")
			// never fall back to the child's own `new`: that would recurse forever
			return findMethod("new");
		if (methods.exists(name))
			return methods.get(name);
		if (name == "super")
			return parent;
		// members inherited from a Haxe / `_HSX` base class: the generated
		// `_HX_SUPER__<name>` forwarder runs the base implementation on `this`
		var scriptObject:Dynamic = interp.scriptObject;
		if (scriptObject != null) {
			var forwarder:Dynamic = Reflect.field(scriptObject, "_HX_SUPER__" + name);
			if (forwarder != null)
				return forwarder;
		}
		return interp.resolve(name);
	}

	/** Finds a method in this level then up the ancestor chain (never in the child). */
	public function findMethod(name:String):Dynamic {
		if (methods.exists(name))
			return methods.get(name);
		return parent == null ? null : parent.findMethod(name);
	}

	public function hset(name:String, val:Dynamic):Dynamic {
		var local:Dynamic = interp.locals.get(name);
		if (local != null)
			local.r = val;
		interp.setVar(name, val);
		return val;
	}
}
