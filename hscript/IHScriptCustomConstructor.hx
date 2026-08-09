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
 * Implemented by script-defined classes (`CustomClassHandler`) so that
 * `new Foo(...)` in scripts is routed through `hnew` (hscript-improved
 * behavior, FNF-CNE-Devs, MIT).
 */
interface IHScriptCustomConstructor {
	public function hnew(args:Array<Dynamic>):Dynamic;
}
