# Reproduce the checked-in project with an already-installed xcodeproj gem.
require 'xcodeproj'
Dir.chdir(__dir__) do
  project = Xcodeproj::Project.new('HotMicExamples.xcodeproj')
  player = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  player.repositoryURL = 'https://github.com/hotmic-wp/hotmic-player-sdk'
  player.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '1.0.0-rc.1' }
  core = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  core.repositoryURL = 'https://github.com/hotmic-wp/hotmic-core-ios'
  core.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '1.0.2' }
  local = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  local.relative_path = '..'
  project.root_object.package_references.concat([player, core, local])
  apps = ['Streams', 'StreamsAndEngagement'].map do |name|
    target = project.new_target(:application, name, :ios, '17.0')
    [name, 'Shared'].each do |folder|
      group = project.main_group.new_group("#{name} #{folder}", folder)
      Dir["#{folder}/*.swift"].sort.each do |f|
        target.source_build_phase.add_file_reference(group.new_file(File.basename(f)))
      end
    end
    target
  end
  tests = project.new_target(:unit_test_bundle, 'HotMicPlayerConnectTests', :ios, '17.0')
  group = project.main_group.new_group('Tests', '../Tests/HotMicPlayerConnectTests')
  Dir['../Tests/HotMicPlayerConnectTests/*.swift'].sort.each { |f| tests.source_build_phase.add_file_reference(group.new_file(File.basename(f))) }
  (apps + [tests]).each do |target|
    dependencies = [[local, 'HotMicPlayerConnect'], [local, 'HotMicPlayerConnectTesting'], [player, 'HotMicPlayer'], [core, 'HotMicCore']]
    dependencies << [player, 'HotMicPlayerUI'] if target.name == 'StreamsAndEngagement'
    dependencies.each do |package, name|
      dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
      dep.package = package; dep.product_name = name
      target.package_product_dependencies << dep
      build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
      build_file.product_ref = dep
      target.frameworks_build_phase.files << build_file
    end
    target.build_configurations.each do |config|
      config.build_settings.merge!({
        'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
        'PRODUCT_BUNDLE_IDENTIFIER' => "com.hotmic.playerconnect.#{target.name}",
        'TARGETED_DEVICE_FAMILY' => '1', 'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
        'SWIFT_EMIT_LOC_STRINGS' => 'NO', 'SWIFT_STRICT_CONCURRENCY' => 'complete'
      })
      if apps.include?(target)
        config.build_settings.merge!({
          'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
          'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES',
          'INFOPLIST_KEY_UISupportedInterfaceOrientations' => 'UIInterfaceOrientationPortrait'
        })
      end
    end
  end
  project.save
  apps.each do |app|
    scheme = Xcodeproj::XCScheme.new
    scheme.add_build_target(app)
    scheme.set_launch_target(app)
    scheme.save_as(project.path, app.name, true)
  end
  checks = Xcodeproj::XCScheme.new
  apps.each { |app| checks.add_build_target(app) }
  checks.add_test_target(tests)
  checks.save_as(project.path, 'ReleaseChecks', true)
end
