platform :osx, '13.0'

target 'YMPlayer' do
  use_frameworks!
  pod 'VLCKit', '~> 3.6'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
