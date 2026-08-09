/*
 * hscript-seiun functional test-suite (MIT).
 * See LICENSE and NOTICE for details.
 */
package;

import crowplexus.hscript.Bytes;
import crowplexus.hscript.Config;
import crowplexus.hscript.CustomClassHandler;
import crowplexus.hscript.DynamicClass;
import crowplexus.hscript.Expr;
import crowplexus.hscript.Interp;
import crowplexus.hscript.InterpIterator;
import crowplexus.hscript.Parser;
import crowplexus.hscript.Printer;
import crowplexus.hscript.Tools;
import crowplexus.iris.Iris;
import crowplexus.iris.utils.UsingEntry;

/**
 * Functional test-suite for hscript-seiun.
 * Run with:
 *   haxe -cp . -cp test -D hscriptPos -D CUSTOM_CLASSES \
 *        --macro crowplexus.hscript.macros.UsingHandler.init() \
 *        --macro crowplexus.hscript.macros.ClassExtendMacro.init() \
 *        -main TestMain --interp
 */
class TestMain {
	static var passed:Int = 0;
	static var failed:Int = 0;

	static function check(cond:Bool, name:String) {
		if (cond) {
			passed++;
			trace('PASS: $name');
		} else {
			failed++;
			trace('FAIL: $name');
		}
	}

	static function eq(a:Dynamic, b:Dynamic, name:String) {
		check(a == b, '$name (got ${Std.string(a)}, want ${Std.string(b)})');
	}

	static function run(code:String, ?setup:Interp->Void):Interp {
		var parser = new Parser();
		parser.allowTypes = true;
		parser.allowJSON = true;
		parser.allowMetadata = true;
		var ast = parser.parseString(code, "test.hx");
		var interp = new Interp();
		if (setup != null)
			setup(interp);
		interp.execute(ast);
		return interp;
	}

	static function runPrepro(code:String, values:Map<String, Dynamic>):Interp {
		var parser = new Parser();
		parser.allowTypes = true;
		for (k in values.keys())
			parser.preprocessorValues.set(k, values.get(k));
		var ast = parser.parseString(code, "test.hx");
		var interp = new Interp();
		interp.execute(ast);
		return interp;
	}

	static function main() {
		touchAll();
		testIrisFeatures();
		testScriptClass();
		testScriptInheritance();
		testStaticShared();
		testErrorHandler();
		testImportFailedCallback();
		testBlocklist();
		testScriptObject();
		testRedirects();
		testUsing();
		testCustomClassExtend();
		testBytesRoundtrip();
		testPrinter();
		testKeyValueFor();
		testPreprocessor();

		trace('== RESULT: $passed passed, $failed failed ==');
		if (failed > 0)
			Sys.exit(1);
	}

	static function touchAll() {
		// force every module to be compiled/type-checked
		check(Bytes != null && Config != null
			&& CustomClassHandler != null && DynamicClass != null && Expr != null
			&& Interp != null && InterpIterator != null && Parser != null
			&& Printer != null && Tools != null && Iris != null,
			"all modules load");
	}

	static function testIrisFeatures() {
		var interp = run('
			final greeting:String = "hello";
			function add(a:Int, b:Int):Int return a + b;
			var result = add(2, 3);
			var nilCoalesce = null ?? 42;
			var arr = [1, 2, 3];
			var total = 0;
			for (v in arr) total += v;
			var sum2 = add(4, 5);
		');
		eq(interp.variables.get("result"), 5, "iris: function + typed args");
		eq(interp.variables.get("nilCoalesce"), 42, "iris: null coalescing");
		eq(interp.variables.get("total"), 6, "iris: for loop");
		eq(interp.variables.get("sum2"), 9, "iris: second call");

		// final cannot be reassigned (warning, no crash)
		var warned = false;
		var interp2 = run('final x = 1; x = 2;', function(i:Interp) {
			Iris.logLevel = function(level, v, ?pos) { warned = true; };
		});
		check(warned, "iris: final reassign warns");
		eq(interp2.variables.get("x"), 1, "iris: final stays 1");

		// import with alias
		var interp3 = run('import haxe.ds.StringMap as SM; var v = SM;');
		check(interp3.variables.get("v") != null, "iris: import alias resolves");

		// typedef redirect
		var interp4 = run('typedef MyMath = Math; var v = MyMath;');
		eq(interp4.variables.get("v"), Math, "iris: typedef redirect");

		// enum
		var interp5 = run('
			enum Color { Red; Green; Blue; }
			var c = Color.Red;
		');
		check(interp5.variables.get("c") != null, "iris: enum value");
	}

	static function testScriptClass() {
		var interp = run('
			class Counter {
				var count:Int = 0;
				public function new() { count = 10; }
				public function add(n:Int):Int { count += n; return count; }
				public function get():Int return count;
			}
			var c = new Counter();
			var r1 = c.add(5);
			var r2 = c.get();
			var direct = c.count;
		');
		eq(interp.variables.get("r1"), 15, "class: method adds");
		eq(interp.variables.get("r2"), 15, "class: state persists");
		eq(interp.variables.get("direct"), 15, "class: field read");
	}

	static function testScriptInheritance() {
		var interp = run('
			class Animal {
				var name:String = "animal";
				function speak():String return name;
			}
			class Dog extends Animal {
				function speak():String return "woof-" + name;
			}
			var d = new Dog();
			var s = d.speak();
			var n = d.name;
			var parentSpeak = d.super.speak();
			d.name = "rex";
			var s2 = d.speak();
		');
		eq(interp.variables.get("s"), "woof-animal", "inherit: override method");
		eq(interp.variables.get("n"), "animal", "inherit: inherited field");
		eq(interp.variables.get("parentSpeak"), "animal", "inherit: super chain call");
		eq(interp.variables.get("s2"), "woof-rex", "inherit: field set propagates");
	}

	static function testStaticShared() {
		var interp = run('
			class Counter2 {
				static var instances = 0;
				function new() { instances++; }
				function count():Int return instances;
			}
			var a = new Counter2();
			var b = new Counter2();
			var c1 = a.count();
			var c2 = b.count();
		');
		eq(interp.variables.get("c1"), 2, "static: shared across instances");
		eq(interp.variables.get("c2"), 2, "static: shared across instances (2)");
	}

	static function testErrorHandler() {
		var captured:String = null;
		run('var x = 1 / 0; var y = null.foo;', function(i:Interp) {
			i.errorHandler = function(e) captured = Std.string(e);
		});
		check(captured != null, "errorHandler: captured runtime error (got " + Std.string(captured) + ")");
	}

	static function testImportFailedCallback() {
		var called = false;
		var interp = run('import foo.Bar; var v = Bar;', function(i:Interp) {
			i.importFailedCallback = function(cl:Array<String>):Bool {
				called = cl.join(".") == "foo.Bar";
				if (called)
					i.variables.set("Bar", "LOADED");
				return called;
			};
		});
		check(called, "importFailedCallback: invoked");
		eq(interp.variables.get("v"), "LOADED", "importFailedCallback: fallback variable");
	}

	static function testBlocklist() {
		var captured:String = null;
		run('import haxe.ds.StringMap;', function(i:Interp) {
			i.importBlocklist.push("haxe.ds.StringMap");
			i.errorHandler = function(e) captured = Std.string(e);
		});
		check(captured != null && captured.indexOf("blacklisted") >= 0,
			"blocklist: rejected (got " + Std.string(captured) + ")");

		// blocklist through Iris (hscript-seiun)
		Iris.blocklistImports.push("haxe.ds.IntMap");
		var captured2:String = null;
		run('import haxe.ds.IntMap;', function(i:Interp) {
			i.errorHandler = function(e) captured2 = Std.string(e);
		});
		check(captured2 != null && captured2.indexOf("blacklisted") >= 0,
			"blocklist: Iris.blocklistImports rejected (got " + Std.string(captured2) + ")");
	}

	static function testScriptObject() {
		var obj:Dynamic = {};
		var interp = run('this.foo = 42; var id = this;', function(i:Interp) {
			i.scriptObject = obj;
		});
		eq(obj.foo, 42, "scriptObject: field set");
		eq(interp.variables.get("id"), obj, "scriptObject: this resolves");
	}

	static function testRedirects() {
		var interp = run('var x = 5;', function(i:Interp) {
			Interp.setRedirects.set("Int", function(o, f, v) return v * 2);
		});
		check(interp.variables.get("x") == 5, "redirects: set redirect present");
		Interp.setRedirects = [];
		var interp2 = run('var s = "abc"; var len = s.len;', function(i:Interp) {
			Interp.getRedirects.set("String", function(o, f) return f == "len" ? 3 : null);
		});
		eq(interp2.variables.get("len"), 3, "redirects: get redirect");
		Interp.getRedirects = [];
	}

	static function testUsing() {
		// NOTE: `using StringTools` needs static-method reflection, which is
		// unavailable on the neko --interp target (upstream iris behavior); it
		// works on cpp/real targets. Here we verify the `using` mechanism with
		// a runtime-registered UsingEntry instead.
		Iris.registeredUsingEntries.push(new UsingEntry("TestUsing", function(o:Dynamic, f:String, args:Array<Dynamic>):Dynamic {
			if (f == "doubleIt")
				return Std.string(o) + Std.string(o);
			return null;
		}));
		var interp = run('
			using TestUsing;
			var doubled = "ab".doubleIt();
		');
		eq(interp.variables.get("doubled"), "abab", "using: registered entry");
	}

	static function testCustomClassExtend() {
		#if CUSTOM_CLASSES
		// force the test base class to be compiled so the _HSX shadow exists
		var _:Class<script.TestBaseClass> = script.TestBaseClass;
		var interp = run('
			class MyThing extends script.TestBaseClass {
				public function new() {}
				function greet():String return "child-" + baseValue;
			}
			var t = new MyThing();
			var a = t.baseValue;
			var b = t.double(21);
			var g = t.greet();
			t.baseValue = 250;
			var a2 = t.baseValue;
		');
		eq(interp.variables.get("a"), 100, "macro-class: inherited field");
		eq(interp.variables.get("b"), 42, "macro-class: inherited method");
		eq(interp.variables.get("g"), "child-100", "macro-class: overridden method");
		eq(interp.variables.get("a2"), 250, "macro-class: field set");
		#else
		trace('SKIP: testCustomClassExtend (need -D CUSTOM_CLASSES)');
		#end
	}

	static function testBytesRoundtrip() {
		var parser = new Parser();
		parser.allowTypes = true;
		var ast = parser.parseString('class Foo { var x = 1; function f() return x; } var y = 2;', "test.hx");
		var bytes = Bytes.encode(ast);
		var ast2 = Bytes.decode(bytes);
		var interp = new Interp();
		interp.execute(ast2);
		eq(interp.variables.get("y"), 2, "bytes: plain var survives");
		var interp2 = new Interp();
		interp2.execute(ast2);
		interp2.execute(parser.parseString('var o = new Foo(); var r = o.f();', "test.hx"));
		eq(interp2.variables.get("r"), 1, "bytes: class survives roundtrip");
	}

	static function testPrinter() {
		var parser = new Parser();
		parser.allowTypes = true;
		var ast = parser.parseString('class Foo { public function new() {} function f() return 1; }', "test.hx");
		var str = new Printer().exprToString(ast);
		check(str.indexOf("class Foo") >= 0, "printer: class header (got ${Std.string(str)})");
	}

	static function testKeyValueFor() {
		var interp = run('
			var map = ["a" => 1, "b" => 2, "c" => 3];
			var total = 0;
			var keys = "";
			for (k => v in map) { total += v; keys += k; }
		');
		eq(interp.variables.get("total"), 6, "keyvalue-for: sums values");
		var keys:String = interp.variables.get("keys");
		var arr = keys.split("");
		arr.sort(function(a, b) return a < b ? -1 : 1);
		eq(arr.join(""), "abc", "keyvalue-for: collects all keys (got " + keys + ")");
	}

	static function testPreprocessor() {
		var parser = new Parser();
		parser.allowTypes = true;
		parser.preprocessorValues.set("android", true);
		parser.preprocessorValues.set("debug", false); // presence = defined, like Haxe #if
		var ast = parser.parseString('
			#if android
			var plat = "android";
			#elseif ios
			var plat = "ios";
			#else
			var plat = "other";
			#end
			#if !ios
			var notIos = true;
			#end
			#if windows || linux
			var desktop = true;
			#end
			#if !android
			var notAndroid = true;
			#end
		', "pp.hx");
		var interp = new Interp();
		interp.execute(ast);
		eq(interp.variables.get("plat"), "android", "preprocessor: #if android (elseif/else)");
		eq(interp.variables.get("notIos"), true, "preprocessor: #if !ios");
		eq(interp.variables.get("desktop"), null, "preprocessor: #if windows || linux is false");
		eq(interp.variables.get("notAndroid"), null, "preprocessor: #if !android is false");

		// the historical misspelled alias still works
		var parser2 = new Parser();
		parser2.preprocesorValues.set("ios", true);
		var ast2 = parser2.parseString('#if ios\nvar v = 1;\n#end', "pp2.hx");
		var interp2 = new Interp();
		interp2.execute(ast2);
		eq(interp2.variables.get("v"), 1, "preprocessor: misspelled alias sets values");

		// true branch must win over later elseif/else branches
		var interp3 = runPrepro('
			#if android
			var branch = "a";
			#elseif ios
			var branch = "b";
			#elseif windows
			var branch = "c";
			#else
			var branch = "d";
			#end
		', ["android" => true]);
		eq(interp3.variables.get("branch"), "a", "preprocessor: true branch beats elseif chain");

		// first false, second elseif matches
		var parser4 = new Parser();
		parser4.allowTypes = true;
		parser4.preprocessorValues.set("ios", true);
		var ast4 = parser4.parseString('
			#if android
			var branch = "a";
			#elseif ios
			var branch = "b";
			#else
			var branch = "c";
			#end
		', "pp4.hx");
		var interp4 = new Interp();
		interp4.execute(ast4);
		eq(interp4.variables.get("branch"), "b", "preprocessor: elseif matches after false");

		// nested #if inside both active and skipped regions
		var interp5 = runPrepro('
			#if android
			var outer = "android";
			#if debug
			var inner = "debug";
			#else
			var inner = "release";
			#end
			#else
			#if ios
			var skipped = "ios";
			#end
			var outer = "other";
			#end
		', ["android" => true]);
		eq(interp5.variables.get("outer"), "android", "preprocessor: nested active region");
		eq(interp5.variables.get("inner"), "release", "preprocessor: nested else");
		eq(interp5.variables.get("skipped"), null, "preprocessor: skipped region drops nested #if");
	}
}
