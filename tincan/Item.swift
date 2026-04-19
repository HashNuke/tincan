//
//  Item.swift
//  tincan
//
//  Created by Akash Manohar John on 19/04/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
