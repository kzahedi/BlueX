import Foundation

// A post accumulates annotations over time: one or more "nltagger" baseline passes
// and one or more "llm" passes (re-annotation appends a new one whenever the model or
// prompt changes). SwiftData relationship arrays are unordered, so positional access
// (.first / .last) can return a stale annotation. These accessors are the single source
// of truth for "the annotation that currently represents this post": the most recent
// one of each stage, by createdAt.
extension Post {
    var currentLLMAnnotation: Annotation? {
        annotations
            .filter { $0.stage == "llm" }
            .max { $0.createdAt < $1.createdAt }
    }

    var currentSpeechClass: String? {
        currentLLMAnnotation?.speechClass
    }

    var nlTaggerAnnotation: Annotation? {
        annotations
            .filter { $0.stage == "nltagger" }
            .max { $0.createdAt < $1.createdAt }
    }

    var hasLLMAnnotation: Bool {
        annotations.contains { $0.stage == "llm" }
    }

    var hasNLTaggerAnnotation: Bool {
        annotations.contains { $0.stage == "nltagger" }
    }
}
