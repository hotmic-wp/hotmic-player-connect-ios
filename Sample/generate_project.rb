# Run from any directory: ruby Sample/generate_project.rb
# Uses the existing xcodeproj gem; no global tool installation is required.
require 'xcodeproj'
Dir.chdir(__dir__) do
  project = Xcodeproj::Project.new('HotMicPlayerCoreDemo.xcodeproj')
  app = project.new_target(:application, 'HotMicPlayerCoreDemo', :ios, '17.0')
  tests = project.new_target(:unit_test_bundle, 'HotMicPlayerCoreTests', :ios, '17.0')
  demo = project.main_group.new_group('Demo', 'HotMicPlayerCoreDemo')
  Dir['HotMicPlayerCoreDemo/*.swift'].sort.each { |f| app.source_build_phase.add_file_reference(demo.new_file(File.basename(f))) }
  test_group = project.main_group.new_group('Tests', '../Tests/HotMicPlayerCoreTests')
  Dir['../Tests/HotMicPlayerCoreTests/*.swift'].sort.each { |f| tests.source_build_phase.add_file_reference(test_group.new_file(File.basename(f))) }
  player = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  player.repositoryURL = 'https://github.com/hotmic-wp/hotmic-player-sdk'
  player.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '0.4.1' }
  core = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  core.repositoryURL = 'https://github.com/hotmic-wp/hotmic-core-ios'
  core.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '1.0.2' }
  local = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  local.relative_path = '..'
  project.root_object.package_references.concat([player, core, local])
  [[app, player, 'HotMicPlayer'], [app, player, 'HotMicPlayerUI'], [app, core, 'HotMicCore'], [app, local, 'HotMicPlayerCore'],
   [tests, local, 'HotMicPlayerCore'], [tests, player, 'HotMicPlayer'], [tests, core, 'HotMicCore']].each do |target, package, name|
    dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dep.package = package; dep.product_name = name
    target.package_product_dependencies << dep
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dep
    target.frameworks_build_phase.files << build_file
  end
  [app, tests].each do |target|
    target.build_configurations.each do |config|
      config.build_settings.merge!({
        'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
        'PRODUCT_BUNDLE_IDENTIFIER' => "com.hotmic.playercore.#{target.name}",
        'TARGETED_DEVICE_FAMILY' => '1,2', 'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
        'SWIFT_EMIT_LOC_STRINGS' => 'NO'
      })
    end
  end
  app.build_configurations.each do |config|
    config.build_settings.merge!({
      'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
      'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES',
      'INFOPLIST_FILE' => 'HotMicPlayerCoreDemo/Info.plist',
      'TARGETED_DEVICE_FAMILY' => '1',
      'INFOPLIST_KEY_UISupportedInterfaceOrientations' => 'UIInterfaceOrientationPortrait'
    })
  end
  project.save
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(app)
  scheme.add_test_target(tests)
  scheme.set_launch_target(app)
  scheme.save_as(project.path, 'HotMicPlayerCoreDemo', true)
end
