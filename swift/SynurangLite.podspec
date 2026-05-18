Pod::Spec.new do |s|
  s.name             = 'SynurangLite'
  s.version          = '0.8.9'
  s.summary          = 'Synurang FFI client (lite path) for Swift — zero dependencies.'
  s.description      = <<-DESC
SynurangLite is the zero-dependency Swift runtime for Synurang FFI plugins.
It ships:
  - ProtoLite: a tiny protobuf wire encoder/decoder
  - PluginHost: an actor that loads a `.dylib` / static-linked C ABI plugin
  - PluginStream / BidiStream: typed streaming wrappers
Generated code from `protoc-gen-synurang-ffi --lang=swift --mode=lite`
imports this pod and produces struct-based messages + actor-based service stubs.
                       DESC
  s.homepage         = 'https://github.com/ivere27/synurang'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Synurang Authors' => 'noreply@ivere27.github.io' }
  s.source           = { :git => 'https://github.com/ivere27/synurang.git', :tag => "v#{s.version}" }

  s.ios.deployment_target     = '13.0'
  s.osx.deployment_target     = '10.15'
  s.tvos.deployment_target    = '13.0'
  s.watchos.deployment_target = '6.0'

  s.swift_versions = ['5.9']

  s.source_files = 'Sources/SynurangLite/**/*.swift'

  s.frameworks = 'Foundation'
end
