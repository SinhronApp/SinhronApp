//
//  Atomic.swift
//  Broadcast Extension — Sinhron ScreenShare (ADR-061), from the LiveKit
//  Flutter example (Apache-2.0); unchanged apart from this header.
//
//  Created by Maksym Shcheglov.
//  https://www.onswiftwings.com/posts/atomic-property-wrapper/
//

import Foundation

@propertyWrapper
struct Atomic<Value> {

    private var value: Value
    private let lock = NSLock()

    init(wrappedValue value: Value) {
        self.value = value
    }

    var wrappedValue: Value {
        get { load() }
        set { store(newValue: newValue) }
    }

    func load() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    mutating func store(newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
