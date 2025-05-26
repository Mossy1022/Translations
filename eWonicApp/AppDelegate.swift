//
//  AppDelegate.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 5/18/25.
//

import UIKit
import ObjectiveC.runtime

@main
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        print(Bundle.main.infoDictionary?.keys.sorted() ?? [])
        
        self.printAllTranslationClasses()

        return true
    }
    
    func printAllTranslationClasses() {
      var count: UInt32 = 0

      // Allocate and cast to UnsafeMutablePointer<AnyClass>
      guard let classListRaw = objc_copyClassList(&count) else { return }
      let classList = UnsafeBufferPointer(start: classListRaw, count: Int(count))

      for cls in classList {
        let name = NSStringFromClass(cls)
        if name.lowercased().contains("translate") {
          print("🔍 Class: \(name)")
        }
      }

      // Cast to UnsafeMutableRawPointer before freeing
      free(UnsafeMutableRawPointer(mutating: classListRaw))
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

