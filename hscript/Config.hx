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
 * Compile-time / runtime configuration for hscript-seiun.
 *
 * From hscript-improved (FNF-CNE-Devs, MIT):
 * - `ALLOWED_CUSTOM_CLASSES`   : packages whose classes get the `_HSX` shadow-class
 *   build macro (`CUSTOM_CLASSES` define must be set for the macro to do anything).
 * - `ALLOWED_ABSTRACT_AND_ENUM`: packages whose abstracts/enums get the `_HSC`
 *   shadow-class build macro (used by `UsingHandler`).
 * - `DISALLOW_*`               : module names that must be skipped by the macros.
 *
 * The defaults mirror SeiunEngine's own script package layout.
 */
class Config {
	/** Package prefixes where `import` of custom classes is allowed (macro-applied). */
	public static final ALLOWED_CUSTOM_CLASSES:Array<String> = [
		#if !DOCUMENTATION
		"flixel",
		"openfl",
		"script",
		"states",
		"substates",
		"backend",
		"options",
		"editors",
		"mohong",
		#if MODCHARTING_FEATURES
		"modchart",
		#end
		#end
	];

	/** Package prefixes where abstract types and enums are resolved (macro-applied). */
	public static final ALLOWED_ABSTRACT_AND_ENUM:Array<String> = [
		#if !DOCUMENTATION
		"flixel",
		"openfl",
		"haxe.xml",
		"haxe.CallStack",
		"script",
		"states",
		"substates",
		"backend",
		#end
	];

	/** Specific module names that are disallowed for custom class shadowing. */
	public static final DISALLOW_CUSTOM_CLASSES:Array<String> = [
		// Add any problematic modules here
	];

	/** Specific module names disallowed for abstract/enum shadowing. */
	public static final DISALLOW_ABSTRACT_AND_ENUM:Array<String> = [
		// Add any problematic modules here
	];
}
