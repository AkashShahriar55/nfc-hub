#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint nfc_hub.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'nfc_hub'
  s.version          = '0.1.6'
  s.summary          = 'Flutter CCID Plugin.'
  s.description      = <<-DESC
A Flutter plugin for CCID support on iOS and macOS.
                       DESC
  s.homepage         = 'http://nfc.im'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'nfcim' => 'info@nfc.im' }
  s.source           = { :path => '.' }
  s.source_files     = 'nfc_hub/Sources/nfc_hub/**/*.swift'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
end
