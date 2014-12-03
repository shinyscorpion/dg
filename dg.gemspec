$:.push File.expand_path("../lib", __FILE__)

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "dg"
  s.version     = '0.4'
  s.authors     = ["Michael Malet"]
  s.email       = ["michael@nervd.com"]
  s.homepage    = "https://github.com/shinyscorpion/dg"
  s.license     = "MIT"
  s.summary     = "Provides integration between Docker and GoCD."
  s.description = File.read('README.md')

  s.files       = `git ls-files -z`.split("\x0")
  s.executables = `git ls-files -z -- bin/*`.split("\x0").map{ |f| File.basename(f) }
end
