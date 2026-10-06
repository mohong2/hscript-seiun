/*
 * hscript-seiun functional test-suite (MIT).
 * See LICENSE and NOTICE for details.
 */
package script;

/**
 * Second-level subclass: the @:deprecated members are inherited from the
 * grandparent, so the macro must walk the whole superclass chain to find them.
 */
class TestDeprecatedLeaf extends TestDeprecatedSub {
	public function new() {
		super();
	}

	public override function oldMethod():Int return 420;

	public override function bareOld():Int return 900;
}
