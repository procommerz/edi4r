# coding: utf-8
$:.push File.expand_path("../lib", __FILE__)
# $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = 'EDI4R'
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

  # Add dependency
#   spec.add_dependency('rails', '>= 4.0.0')
#   spec.add_dependency('builder',  '~> 3.1')
#   spec.add_dependency('nokogiri',  '~> 1.4')
#   spec.add_dependency('httparty',  '~> 0.12')
#   spec.add_dependency('airbrake')

end