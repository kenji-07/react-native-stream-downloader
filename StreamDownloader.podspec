require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name = 'StreamDownloader'
  s.version = package['version']
  s.summary = package['description']
  s.description = 'Independent clean-room implementation of the documented offline downloader API. Local registration requires no vendor key.'
  s.homepage = package['homepage']
  s.license = { :type => package['license'], :file => 'LICENSE' }
  s.author = 'react-native-stream-downloader contributors'
  # npm consumers autolink this pod from node_modules. Git source metadata
  # also resolves the corresponding release tag for CocoaPods tooling.
  s.source = { :git => package['repository']['url'].sub(/^git\+/, ''), :tag => "v#{s.version}" }
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
  s.source_files = 'ios/**/*.{h,m,swift}'
  s.frameworks = 'AVFoundation', 'Security'
  s.libraries = 'sqlite3'
  s.dependency 'React-Core'
  s.dependency 'react-native-video', '>= 6.15.0', '< 7.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
