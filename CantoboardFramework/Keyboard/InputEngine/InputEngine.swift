//
//  InputEngine.swift
//  KeyboardKit
//
//  Created by Alex Man on 1/21/21.
//

import Foundation

class Composition {
    var text: String
    var caretIndex: Int
    
    init(text: String, caretIndex: Int) {
        self.text = text
        self.caretIndex = caretIndex
    }
}

class InputCandidate {
    let text: String
    let rimeIndex: Int?
    
    convenience init(_ text: String) {
        self.init(text: text, rimeIndex: nil)
    }
    
    init(text: String, rimeIndex: Int?) {
        self.text = text
        self.rimeIndex = rimeIndex
    }
}

protocol InputEngine {
    // These funcs return true if the engine state changed.
    func processChar(_ char: Character) -> Bool
    func processBackspace() -> Bool
    func moveCaret(offset: Int) -> Bool

    func clearInput()
    
    var composition: Composition? { get }
}
