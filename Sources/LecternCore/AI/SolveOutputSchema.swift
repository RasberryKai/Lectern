import Foundation

extension AIOutputSchema {
    // Closed objects with every key required work across the strict providers. Each field
    // shape has one payload, and each input kind exposes only the controls it can use.
    static let solveDefinitions = ##"""
    {"solveDraft":{"type":"object","additionalProperties":false,"required":["skill","reason","variation","sample"],"properties":{"skill":{"type":"string"},"reason":{"type":"string"},"variation":{"type":"string"},"sample":{"$ref":"#/$defs/case"}}},\##(solveCaseDefinitions)}
    """##

    private static let solveCaseDefinitions = ##"""
    "case":{"type":"object","additionalProperties":false,"required":["prompt","fields","explanation","variance"],"properties":{
    "prompt":{"type":"string"},"fields":{"type":"array","items":{"$ref":"#/$defs/field"}},"explanation":{"type":"string"},"variance":{"anyOf":[{"type":"null"},{"type":"object","additionalProperties":false,"required":["outcomes","weights"],"properties":{"outcomes":{"type":"array","items":{"type":"integer"}},"weights":{"type":"array","items":{"type":"integer"}}}}]}}},
    "field":{"anyOf":[
    {"type":"object","additionalProperties":false,"required":["prompt","input"],"properties":{"prompt":{"type":"string"},"input":{"$ref":"#/$defs/input"}}},
    {"type":"object","additionalProperties":false,"required":["prompt","choice"],"properties":{"prompt":{"type":"string"},"choice":{"$ref":"#/$defs/choice"}}},
    {"type":"object","additionalProperties":false,"required":["prompt","order"],"properties":{"prompt":{"type":"string"},"order":{"$ref":"#/$defs/order"}}},
    {"type":"object","additionalProperties":false,"required":["prompt","grid"],"properties":{"prompt":{"type":"string"},"grid":{"$ref":"#/$defs/grid"}}}
    ]},
    "input":{"anyOf":[
    {"type":"object","additionalProperties":false,"required":["kind","answers","formats","unit","tolerance","decimalPlaces"],"properties":{"kind":{"type":"string","enum":["number"]},"answers":{"$ref":"#/$defs/strings"},"formats":{"type":"array","items":{"type":"string","enum":["decimalPoint","decimalComma","fraction","percent"]}},"unit":{"type":["string","null"]},"tolerance":{"type":["number","null"]},"decimalPlaces":{"type":["integer","null"]}}},
    {"type":"object","additionalProperties":false,"required":["kind","answers","formats"],"properties":{"kind":{"type":"string","enum":["date"]},"answers":{"$ref":"#/$defs/strings"},"formats":{"type":"array","items":{"type":"string","enum":["isoDate","dayMonthYear","monthDayYear"]}}}},
    {"type":"object","additionalProperties":false,"required":["kind","answers","language","ignoreCase","articles","allowTypo","tonesMatter"],"properties":{"kind":{"type":"string","enum":["term"]},"answers":{"$ref":"#/$defs/strings"},"language":{"type":["string","null"]},"ignoreCase":{"type":"boolean"},"articles":{"$ref":"#/$defs/strings"},"allowTypo":{"type":"boolean"},"tonesMatter":{"type":["boolean","null"]}}},
    {"type":"object","additionalProperties":false,"required":["kind","answers"],"properties":{"kind":{"type":"string","enum":["option"]},"answers":{"$ref":"#/$defs/strings"}}}
    ]},
    "choice":{"type":"object","additionalProperties":false,"required":["options","correct","multiple","noneReason","shuffle"],"properties":{
    "options":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["label","reason"],"properties":{"label":{"type":"string"},"reason":{"type":"string"}}}},
    "correct":{"$ref":"#/$defs/strings"},"multiple":{"type":"boolean"},"noneReason":{"type":["string","null"]},"shuffle":{"type":"boolean"}}},
    "order":{"type":"object","additionalProperties":false,"required":["items","sequences"],"properties":{"items":{"$ref":"#/$defs/strings"},"sequences":{"type":"array","items":{"$ref":"#/$defs/strings"}}}},
    "grid":{"type":"object","additionalProperties":false,"required":["columns","rows","rowLabels","options","rowOrderMatters","shuffle"],"properties":{
    "columns":{"$ref":"#/$defs/strings"},"rows":{"type":"array","items":{"type":"array","items":{"$ref":"#/$defs/input"}}},"rowLabels":{"anyOf":[{"type":"null"},{"$ref":"#/$defs/strings"}]},"options":{"$ref":"#/$defs/strings"},"rowOrderMatters":{"type":"boolean"},"shuffle":{"type":"boolean"}}},
    "strings":{"type":"array","items":{"type":"string"}}
    """##

    static let solveVariants = ##"""
    {"type":"object","additionalProperties":false,"required":["cases"],"properties":{"cases":{"type":"array","items":{"$ref":"#/$defs/case"}}},"$defs":{\##(solveCaseDefinitions)}}
    """##

    static let verifiedSolveVariants = """
    {"type":"object","additionalProperties":false,"required":["cases"],"properties":{"cases":{"type":"array","items":{
    "type":"object","additionalProperties":false,"required":["index","explanation","fields"],"properties":{
    "index":{"type":"integer"},"explanation":{"type":"string"},"fields":{"type":"array","items":{
    "type":"object","additionalProperties":false,"required":["answers","rows","optionReasons","noneReason"],"properties":{
    "answers":{"type":"array","items":{"type":"string"}},"rows":{"type":"array","items":{"type":"array","items":{"type":"string"}}},"optionReasons":{"type":"array","items":{"type":"string"}},"noneReason":{"type":"string"}}}}
    }}}}}
    """
}
