//
//  Requests.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 19.01.25.
//

import Foundation

public func getBlueSkyToken() -> String? {
    
    let credentials = retrieveCredentials(forService: "kgz.bluex.preferences")
    if credentials == nil {
        print("Cannot retrieve credentials")
        exit(-1)
    }
    
    let sourceDID : String? = resolveDID(handle: credentials!.username)

    let apiKeyURL = "https://bsky.social/xrpc/com.atproto.server.createSession"
    let group = DispatchGroup()
    let tokenPayload: [String: Any] = [
        "identifier": sourceDID!,
        "password": credentials!.password
    ]
    
    guard let tokenData = try? JSONSerialization.data(withJSONObject: tokenPayload) else {
        print("Error creating JSON payload")
        return nil
    }
    
    var tokenRequest = URLRequest(url: URL(string: apiKeyURL)!)
    tokenRequest.httpMethod = "POST"
    tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    tokenRequest.httpBody = tokenData
    
    var returnValue : String? = nil
    
    group.enter()
    let tokenTask = URLSession.shared.dataTask(with: tokenRequest) { data, response, error in
        if let error = error {
            print("Error getting token: \(error)")
            group.leave()
        }
        
        if data == nil {
            print("No data received")
            group.leave()
        }
        
        do {
            // Check for error response
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data!) {
                print("Error: \(errorResponse.error)")
                if let message = errorResponse.message {
                    print("Message: \(message)")
                }
                group.leave()
            }
            
            // Decode the token response
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data!)
            returnValue = tokenResponse.accessJwt
            group.leave()
        } catch {
            print("Error decoding token response: \(error)")
            group.leave()
        }
    }
    tokenTask.resume()
    group.wait()
    return returnValue
}
