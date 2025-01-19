//
//  AccountExtensions.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 19.01.25.
//

import Foundation

extension Account {
    
    public override var description: String {
        
        let dateString = setDateString(date:self.startAt)
        let lastFeedUpdate = setDateString(date:self.timestampFeed)
        let lastReplyTreesUpdate = setDateString(date:self.timestampReplyTrees)
        let lastSentimentUpdate = setDateString(date:self.timestampSentiment)
        let lastStatisticsUpdate = setDateString(date:self.timestampStatistics)
        
        var r = ""
        r = r + "Account name: \(self.displayName ?? "No name")\n"
        r = r + "  Handle:                    \(self.handle ?? "No handle")\n"
        r = r + "  DID:                       \(self.did ?? "No DID")\n"
        r = r + "  Is active:                 \(self.isActive)\n"
        r = r + "  Scraping starts at         \(dateString)\n"
        r = r + "  Followers Count:           \(self.followersCount)\n"
        r = r + "  Follows Count:             \(self.followsCount)\n"
        r = r + "  Number of posts:           \(self.postsCount)\n"
        r = r + "  Force feed updates:        \(self.forceFeedUpdate)\n"
        r = r + "  Last feed update:          \(lastFeedUpdate)\n"
        r = r + "  Force reply tree updates:  \(self.forceReplyTreeUpdate)\n"
        r = r + "  Last reply trees update:   \(lastReplyTreesUpdate)\n"
        r = r + "  Force sentiment updates:   \(self.forceSentimentUpdate)\n"
        r = r + "  Last sentiment update:     \(lastSentimentUpdate)\n"
        r = r + "  Force statistics updates:  \(self.forceStatistics)\n"
        r = r + "  Last statistics update:    \(lastStatisticsUpdate)\n"
        return r
    }
}
