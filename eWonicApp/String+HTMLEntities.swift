//
//  String+HTMLEntities.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 5/18/25.
//

import Foundation

extension String {
  /// Unescapes the five entities Google’s v2 API returns in `translatedText`
  func htmlUnescaped() -> String {
    var s = self
    let map = ["&amp;":"&", "&lt;":"<", "&gt;":">", "&#39;":"'", "&quot;":"\""]
    map.forEach { s = s.replacingOccurrences(of:$0.key, with:$0.value) }
    return s
  }
}
