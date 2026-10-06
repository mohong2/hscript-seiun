/*
 * hscript-seiun functional test-suite (MIT).
 * See LICENSE and NOTICE for details.
 *
 * Compile-only probe for the ClassExtendMacro deprecation-warning fix.
 */
class DeprecationProbe {
	static function main() {
		var base:Class<script.TestDeprecatedBase> = script.TestDeprecatedBase;
		var sub:Class<script.TestDeprecatedSub> = script.TestDeprecatedSub;
		var leaf:Class<script.TestDeprecatedLeaf> = script.TestDeprecatedLeaf;
		trace("shadow classes: " + Type.getClassName(base) + ", " + Type.getClassName(sub) + ", " + Type.getClassName(leaf));
	}
}
