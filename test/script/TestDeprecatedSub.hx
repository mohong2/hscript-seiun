/*
 * hscript-seiun functional test-suite (MIT).
 * See LICENSE and NOTICE for details.
 */
package script;

/** Subclass that overrides @:deprecated members (deprecation probe). */
class TestDeprecatedSub extends TestDeprecatedBase {
	public function new() {
		super();
	}

	public override function oldMethod():Int return 42;

	public override function bareOld():Int return 90;
}
