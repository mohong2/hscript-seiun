/*
 * hscript-seiun functional test-suite (MIT).
 * See LICENSE and NOTICE for details.
 */
package script;

/**
 * Deprecation probe base class for the CUSTOM_CLASSES shadow-class macro.
 *
 * Own deprecated FUNCTION and deprecated PROPERTY members are both covered:
 * the macro used to generate an override wrapper + a _HX_SUPER__ forwarder
 * calling super.<name>(...), and those macro-positioned call sites were
 * reported as WDeprecated against hscript/macros/ClassExtendMacro.hx.
 *
 * The property uses (get, set) with a non-deprecated backing field so the
 * accessors themselves never touch the deprecated member (Haxe 4.2.5 would
 * otherwise warn about the setter body, which is not what this probe tests).
 */
class TestDeprecatedBase {
	public function new() {}

	@:deprecated("Use freshMethod instead of oldMethod")
	public function oldMethod():Int return 1;

	@:deprecated
	public function bareOld():Int return 9;

	@:deprecated("Use freshValue instead of oldValue")
	public var oldValue(get, set):Int;
	var _oldValue:Int = 5;
	function get_oldValue():Int return _oldValue;
	function set_oldValue(v:Int):Int {
		_oldValue = v;
		return _oldValue;
	}

	public function freshMethod():Int return 2;
}
