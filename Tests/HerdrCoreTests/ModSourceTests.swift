import Foundation
import JavaScriptCore
import Testing
@testable import HerdrCore

/// Runs wrapped module source in JavaScriptCore with a tiny import table.
private func run(_ source: String, modules: [String: String] = [:]) -> JSValue? {
    let ctx = JSContext()!
    var failure: String?
    ctx.exceptionHandler = { _, e in failure = e?.toString() }
    ctx.evaluateScript("globalThis.__modules = {};")
    for (name, body) in modules { ctx.evaluateScript("__modules[\(ModSource.quote(name))] = \(body);") }
    let fn = ctx.evaluateScript(ModSource.wrap(source, url: "test.js"))
    let importer = ctx.evaluateScript("(spec) => __modules[spec]")!
    let result = fn?.call(withArguments: [JSValue(newObjectIn: ctx)!, importer])
    #expect(failure == nil, "\(failure ?? "")")
    return result
}

@Test func herdrModImportsAndDefaultExportRun() {
    let ex = run("""
    import { View, div } from "gpui-kit";
    import { v_flex as col, h_flex } from "gpui-base";
    import * as kit from "gpui-kit";
    export const SIZE = 3;
    export default class Panel extends View {
      render() { return [div(), col(), h_flex(), kit.div(), SIZE].join(","); }
    }
    """, modules: [
        "gpui-kit": "{ View: class {}, div: () => 'div' }",
        "gpui-base": "{ v_flex: () => 'v', h_flex: () => 'h' }",
    ])
    let panel = ex?.objectForKeyedSubscript("default")
    #expect(panel?.construct(withArguments: []).invokeMethod("render", withArguments: []).toString() == "div,v,h,div,3")
    #expect(ex?.objectForKeyedSubscript("SIZE").toInt32() == 3)
}

@Test func exportListsAndFunctions() {
    let ex = run("""
    function a() { return 1; }
    export function b() { return 2; }
    const c = 3;
    export { a, c as d };
    """)
    #expect(ex?.objectForKeyedSubscript("a").call(withArguments: []).toInt32() == 1)
    #expect(ex?.objectForKeyedSubscript("b").call(withArguments: []).toInt32() == 2)
    #expect(ex?.objectForKeyedSubscript("d").toInt32() == 3)
}

@Test func importsInsideStringsAreLeftAlone() {
    let ex = run("""
    export const text = "you can import { x } from \\"y\\" in a mod";
    """)
    #expect(ex?.objectForKeyedSubscript("text").toString() == #"you can import { x } from "y" in a mod"#)
}
