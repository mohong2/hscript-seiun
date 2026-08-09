/*
 * hscript-seiun — SeiunEngine's merged HaxeScript runtime (MIT).
 *
 * Derivative work merged from these MIT-licensed projects:
 *   hscript (Haxe Foundation), hscript-iris (crowplexus, Ne_Eo),
 *   hscript-improved (FNF-CNE-Devs), hscript-plus (Dlean Jeans).
 * See LICENSE and NOTICE for details.
 */
package crowplexus.hscript;

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
		if (staticFields.exists(name))
			return staticFields.get(name);
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

		// script-to-script inheritance: the parent is another script class
		var scriptParent:CustomClassHandler = extend == null ? null : ogInterp.customClasses.get(extend);

		var _class:Dynamic;
		var baseClass:Class<Dynamic> = null;

		if (extend == null) {
			baseClass = TemplateClass;
		} else {
			// 1) macro shadow class (CUSTOM_CLASSES)  2) plain Haxe class  3) script class
			baseClass = Type.resolveClass('${extend}_HSX');
			if (baseClass == null && Type.resolveClass(extend) != null)
				baseClass = Type.resolveClass(extend);
		}

		if (baseClass == null && scriptParent == null)
			ogInterp.error(EInvalidClass(extend));

		if (scriptParent != null) {
			// hscript-plus style: Dynamic instance with a `super` chain.
			// The parent instance is built without running its constructor;
			// the constructor runs once on the child (inherited or overridden).
			var parentInstance:Dynamic = scriptParent.buildInstance(args, true);
			_class = DynamicClass.create(name, parentInstance);

			// Re-evaluate parent fields inside the child interp so inherited
			// methods see the child as `this` when called on a child instance.
			for (expr in scriptParent.fields) {
				@:privateAccess interp.exprReturn(expr);
			}
		} else {
			_class = Type.createInstance(baseClass, args);
		}

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

		// evaluate this class's own fields
		for (expr in fields) {
			@:privateAccess interp.exprReturn(expr);
		}

		// `super` inside methods: script parent instance (chain) or the static
		// handler used by `_HSX` shadow classes for `super.method()` calls
		interp.variables.set("super", scriptParent != null ? DynamicClass.getSuperOf(_class) : staticHandler);

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
