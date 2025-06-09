platform :ios, '17.0'
use_frameworks!

target 'eWonicApp' do
  pod 'MicrosoftCognitiveServicesSpeech-iOS', '~> 1.43.0'

  target 'eWonicAppTests' do
    inherit! :search_paths
  end

  target 'eWonicAppUITests' do
    inherit! :search_paths
  end
end

# ────────────────────────────────────────────────
# Post-install hook: set deployment target, disable
# signing for Azure, strip its _CodeSignature folder
# ────────────────────────────────────────────────
post_install do |installer|
  # 0. Disable sandboxing for every CocoaPods script phase
  installer.generated_projects.each do |project|
    project.targets.each do |t|
      t.build_configurations.each do |c|
        c.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
      end
    end
  end

  # 1. Force all pods to iOS 17
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    end
  end

  # 2. Azure Speech: stop re-signing and strip CodeSignature
  azure = installer.pods_project.targets.find { |t| t.name == 'MicrosoftCognitiveServicesSpeech-iOS' }
  if azure
    azure.build_configurations.each do |c|
      c.build_settings['CODE_SIGNING_ALLOWED']  = 'NO'
      c.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
    end

    xcframework = Dir.glob('Pods/MicrosoftCognitiveServicesSpeech-iOS/**/*.xcframework').first
    if xcframework
      puts '␡  Removing Azure _CodeSignature to avoid sandbox rsync errors'
      system("find #{xcframework} -name _CodeSignature -type d -exec rm -rf {} +")
    end
  end
end
