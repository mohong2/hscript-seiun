/*
 * hscript-seiun functional test-suite (MIT).
 * See LICENSE and NOTICE for details.
 */
package script;

/**
 * Test base class for the CUSTOM_CLASSES shadow-class macro
 * (package `script` is in crowplexus.hscript.Config.ALLOWED_CUSTOM_CLASSES).
 */
class TestBaseClass {
	public var baseValue:Int = 100;
	public function new(?v:Int = 100) { baseValue = v; }
	public function double(n:Int):Int return n * 2;
	public function greet():String return "base";
}
