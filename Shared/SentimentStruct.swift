//
//  SentimentStruct.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 21.01.25.
//

import Foundation

public enum SentimentAnalysisTool : Decodable, CaseIterable {
    case NLTagger
    
    enum CodingKeys : String, CodingKey {
        case NLTagger = "NLTagger"
    }
    
    // Computed property to get the string value
    var stringValue: String {
        switch self {
            case .NLTagger:
                return CodingKeys.NLTagger.rawValue
        }
    }
}
