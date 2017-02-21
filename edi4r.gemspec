# coding: utf-8
$:.push File.expand_path("../lib", __FILE__)
# $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = 'edi4r'
  spec.version       = 1
  spec.authors       = ['markjeee', 'procommerz']
  spec.email         = 'denis@mobiquest.ru'
  spec.description   = 'EDI TOOLKIT for RUBY'
  spec.summary       = 'EDI TOOLKIT for RUBY'
  spec.homepage      = ''
  spec.license       = 'MIT'

  spec.files = Dir['bin/**/*', 'lib/**/*']
  spec.require_paths = ['bin', 'lib']

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
end