Pod::Spec.new do |s|
  s.name             = 'synurang'
  s.version          = '0.1.7'
  s.summary          = 'Flutter FFI + gRPC bridge for bidirectional Go/Dart communication'
  s.description      = <<-DESC
Flutter FFI + gRPC bridge for bidirectional Go/Dart communication.
                       DESC
  s.homepage         = 'https://github.com/ivere27/synurang'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Synurang Authors' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
