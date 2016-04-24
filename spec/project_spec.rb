# encoding: UTF-8

require File.expand_path('../spec_helper', __FILE__)

module ProjectSpecs
  describe Xcodeproj::Project do
    #-------------------------------------------------------------------------#

    describe 'In general' do
      it 'return the objects by UUID hash' do
        @project.objects_by_uuid.should.not.be.nil
      end

      it 'returns the root object' do
        @project.root_object.class.should == PBXProject
      end
    end

    #-------------------------------------------------------------------------#

    describe 'Initialization from scratch' do
      it 'expands the provided path' do
        project = Xcodeproj::Project.new('foo.xcodeproj')
        project.path.should == Pathname.new('./foo.xcodeproj').expand_path
      end

      it 'initializes to the last known archive version' do
        @project.archive_version.should == Xcodeproj::Constants::LAST_KNOWN_ARCHIVE_VERSION.to_s
      end

      it 'initializes to the classes to the empty hash' do
        @project.classes.should == {}
      end

      it 'initializes to the default archive version' do
        @project.object_version.should == Xcodeproj::Constants::DEFAULT_OBJECT_VERSION.to_s
      end

      it 'sets itself as the owner of the root object' do
        @project.root_object.referrers.should == [@project]
      end

      it 'includes the root object in the objects by UUID hash' do
        uuid = @project.root_object.uuid
        @project.objects_by_uuid[uuid].should.not.be.nil
      end

      it 'initializes the root object main group' do
        @project.root_object.main_group.class.should == PBXGroup
      end

      it 'initializes the root object products group' do
        product_ref_group = @project.root_object.product_ref_group
        product_ref_group.class.should == PBXGroup
        @project.root_object.main_group.children.should.include?(product_ref_group)
      end

      it 'initializes the root object configuration list' do
        list = @project.root_object.build_configuration_list
        list.class.should == XCConfigurationList
        list.default_configuration_name.should == 'Release'
        list.default_configuration_is_visible.should == '0'

        configurations = list.build_configurations
        configurations.map(&:name).sort.should == %w(Debug Release)
        list.build_settings('Debug')['ONLY_ACTIVE_ARCH'].should == 'YES'
        list.build_settings('Release')['VALIDATE_PRODUCT'].should == 'YES'
      end

      it 'adds the frameworks group' do
        @project['Frameworks'].class.should == PBXGroup
      end

      it 'allows providing an optional object version parameter' do
        object_version = Xcodeproj::Constants::LAST_KNOWN_OBJECT_VERSION
        @project = Xcodeproj::Project.new('foo.xcodeproj', false, object_version)
        @project.object_version.should == object_version.to_s
      end
    end

    #-------------------------------------------------------------------------#

    describe 'Initialization from a file' do
      before do
        @dir = Pathname(fixture_path('Sample Project'))
        @path = @dir + 'Cocoa Application.xcodeproj'
        @project = Xcodeproj::Project.open(@path)
      end

      it 'sets itself as the owner of the root object' do
        # The root object might be referenced by other objects like
        # the PBXContainerItemProxy
        @project.root_object.referrers.should.include?(@project)
      end

      # It implicitly checks that all the attributes for the known ISAs.
      # Therefore, If a new isa or attribute is found it should added to the
      # sample project.
      #
      it 'can be loaded from a plist' do
        @project.root_object.should.not.nil?
        @project.main_group.should.not.nil?
        @project['Cocoa Application'].should.not.be.nil
      end

      # This ensures that there is no loss (or modification) of information by
      # going to the object tree and serializing it back to a plist.
      #
      it 'can regenerate the EXACT plist that initialized it' do
        plist = Plist.read_from_path(@path + 'project.pbxproj')
        generated = @project.to_hash
        diff = Xcodeproj::Differ.diff(generated, plist)
        diff.should.be.nil
      end

      it "doesn't add default attributes to objects generated from a plist" do
        uuid = 'UUID'
        expected = { 'isa' => 'PBXFileReference', 'sourceTree' => 'SOURCE_ROOT' }
        objects_by_uuid_plist = {}
        objects_by_uuid_plist[uuid] = expected
        obj = @project.new_from_plist(uuid, objects_by_uuid_plist)
        attrb = PBXFileReference.simple_attributes.find { |a| a.name == :include_in_index }
        attrb.default_value.should == '1'
        obj.to_hash.should == expected
      end

      it 'recognizes merge conflicts' do
        @path = @dir + 'ProjectInMergeConflict/ProjectInMergeConflict.xcodeproj'
        lambda do
          Xcodeproj::Project.open(@path)
        end.should.raise(Xcodeproj::Informative)
      end

      it 'can load projects in Xcode 6.3 format' do
        @path = @dir + '6.3-format.xcodeproj'
        @project = Xcodeproj::Project.open(@path)
        @project.object_version.should == Xcodeproj::Constants::LAST_KNOWN_OBJECT_VERSION.to_s
      end

      it 'can load projects that have circular target dependencies' do
        @path = @dir + 'Circular.xcodeproj'
        @project = Xcodeproj::Project.open(@path)
        target_a, target_b = *@project.targets
        target_a.dependencies.first.target.should == target_b
        target_b.dependencies.first.target.should == target_a
      end
    end

    #-------------------------------------------------------------------------#

    describe '#Save' do
      extend SpecHelper::TemporaryDirectory

      before do
        @dir = Pathname(fixture_path('Sample Project'))
        @path = @dir + 'Cocoa Application.xcodeproj'
        @project = Xcodeproj::Project.open(@path)
        @tmp_path = temporary_directory + 'Pods.xcodeproj'
      end

      it 'saves the project to the default path' do
        @project.save(@tmp_path)
        new_instance = Xcodeproj::Project.open(@path)
        new_instance.should.eql @project
      end

      it 'saves the project to the given path' do
        @project.save(@tmp_path)
        new_instance = Xcodeproj::Project.open(@tmp_path)
        new_instance.should.eql @project
      end

      it 'can save a project after removing a subproject' do
        # UUID's related to ReferencedProject.xcodeproj (subproject)
        uuids_to_remove = [
          'E5FBB3451635ED35009E96B0', # The Xcode subproject file reference that should trigger the removal.

          '5138059B16499F4C001D82AD', # PBXContainerItemProxy links to E5FBB3451635ED35009E96B0
          '5138059C16499F4C001D82AD', # PBXTargetDependency links to 5138059B16499F4C001D82AD
          'E5FBB3461635ED35009E96B0', # PBXGroup for products links to E5FBB34C1635ED36009E96B0, E5FBB34E1635ED36009E96B0, E5FBB3501635ED36009E96B0

          'E5FBB34B1635ED36009E96B0', # PBXContainerItemProxy links to E5FBB3451635ED35009E96B0
          'E5FBB34C1635ED36009E96B0', # PBXReferenceProxy links to E5FBB34B1635ED36009E96B0

          'E5FBB34D1635ED36009E96B0', # PBXContainerItemProxy links to E5FBB3451635ED35009E96B0
          'E5FBB34E1635ED36009E96B0', # PBXReferenceProxy links to E5FBB34D1635ED36009E96B0

          'E5FBB34F1635ED36009E96B0', # PBXContainerItemProxy links to E5FBB3451635ED35009E96B0
          'E5FBB3501635ED36009E96B0', # PBXReferenceProxy links to E5FBB34F1635ED36009E96B0
        ]

        subproject_file_reference = @project.objects_by_uuid['E5FBB3451635ED35009E96B0']
        subproject_file_reference.remove_from_project
        @project.save(@tmp_path)

        new_instance = Xcodeproj::Project.open(@tmp_path)
        new_instance.objects.count.should > 0 # make sure we still have a valid project
        new_instance.root_object.project_references.should.be.empty # this contains the Products group of the external project
        removed_objects = new_instance.objects.select { |o| uuids_to_remove.include?(o.uuid) }
        removed_objects.count.should == 0
      end

      it 'can open a project and save it without altering any information' do
        plist = Plist.read_from_path(@path + 'project.pbxproj')
        @project.save(@tmp_path)
        project_file = (temporary_directory + 'Pods.xcodeproj/project.pbxproj')
        Plist.read_from_path(project_file).should == plist
      end

      it 'escapes non ASCII characters in the project' do
        Plist::FFI::DevToolsCore.stubs(:load_xcode_frameworks).returns(nil)

        file_ref = @project.new_file('わくわく')
        file_ref.name = 'わくわく'
        file_ref = @project.new_file('Cédric')
        file_ref.name = 'Cédric'
        @project.save(@tmp_path)
        contents = File.read(@tmp_path + 'project.pbxproj')
        contents.should.not.include('わくわく')
        contents.should.include('&#12431;&#12367;&#12431;&#12367;')
        contents.should.not.include('Cédric')
        contents.should.include('C&#233;dric')
      end
    end

    #-------------------------------------------------------------------------#

    describe 'Object creation' do
      it 'creates a new object' do
        @project.new(PBXFileReference).class.should == PBXFileReference
      end

      it "doesn't add an object to the objects tree until an object references it" do
        obj = @project.new(PBXFileReference)
        obj.path = 'some/file.m'
        @project.objects_by_uuid[obj.uuid].should.nil?
      end

      it 'adds an object to the objects tree once an object references it' do
        obj = @project.new(PBXFileReference)
        @project.main_group << obj
        @project.objects_by_uuid[obj.uuid].should == obj
      end

      it 'initializes new objects (not created form a plist) with the default values' do
        obj = @project.new(PBXFileReference)
        expected = {
          'isa'            => 'PBXFileReference',
          'sourceTree'     => 'SOURCE_ROOT',
          'includeInIndex' => '1',
        }
        obj.to_hash.should == expected
      end

      it 'generates new UUIDs' do
        @project.generate_uuid.length.should == 24
      end

      it 'generates a given number of unique UUIDs' do
        before_count = @project.generated_uuids.count.should
        @project.generate_available_uuid_list(100)
        # Checking against 75 instead of 100 to prevent this test for failing
        # for bad luck. Not sure what is the statical likelihood of 25
        # collision out of 100.
        @project.generated_uuids.count.should >= (before_count + 75)
      end

      it 'keeps track of the known UUIDs even if objects are not in the objects hash' do
        obj = @project.new(PBXFileReference)
        @project.uuids.should.not.include?(obj.uuid)
        @project.generated_uuids.should.include?(obj.uuid)
      end
    end

    #-------------------------------------------------------------------------#

    describe 'Helpers' do
      it 'returns all the objects referred in the project' do
        expected = [
          'ConfigurationList',
          'Debug',
          'Frameworks',
          'Main Group',
          'Products',
          'Project',
          'Release',
        ]
        @project.objects.map(&:display_name).sort.should == expected
      end

      it 'returns the UUIDs of all the objects referred in the project' do
        @project.uuids.count.should > 1
        @project.uuids.first.length.should == 24
      end

      it 'lists the objects with a given class' do
        expected = ['Frameworks', 'Main Group', 'Products']
        @project.list_by_class(PBXGroup).map(&:display_name).sort.should == expected
      end

      it 'returns the main group' do
        @project.main_group.class.should == PBXGroup
        @project.main_group.referrers.should.include?(@project.root_object)
      end

      it 'returns the groups of the main group' do
        expected = %w(Products Frameworks)
        @project.groups.map(&:display_name).should == expected
      end

      it 'returns the group with the given path' do
        g = @project.new_group('Pods').new_group('libPusher')
        @project ['Pods/libPusher'].should == g
      end

      it 'returns all the files of the project' do
        f = @project.products_group.new_product_ref_for_target('Pods', :static_library)
        @project.files.should.include?(f)
      end

      it 'finds file references by absolute path' do
        file_path = 'Classes/Test.h'
        @project.reference_for_path(@project.path.dirname + file_path).should.be.nil
        file = @project.new_file(file_path)
        @project.reference_for_path(@project.path.dirname + file_path).should == file
      end

      it 'does not find references by relative path' do
        should.raise ArgumentError do
          @project.reference_for_path(@project.path.basename)
        end.message.should.match /must be absolute/
      end

      it 'returns the targets' do
        target = @project.new_target(:static_library, 'Pods', :ios)
        @project.targets.should.include?(target)
      end

      it 'returns the native targets' do
        native_target = @project.new_target(:static_library, 'Pods', :ios)
        @project.new_aggregate_target('Trees')
        @project.targets << @project.new(PBXLegacyTarget)
        native_targets = @project.native_targets
        native_targets.should.include?(native_target)
        native_targets.count.should == 1
      end

      it 'returns the products group' do
        g = @project.products_group
        g.class.should == PBXGroup
        g.referrers.should.include?(@project.main_group)
      end

      it 'returns the products' do
        file = @project.new_target(:static_library, 'Pods', :ios).product_reference
        @project.products.should.include?(file)
      end

      it 'returns the frameworks group' do
        g = @project.frameworks_group
        g.class.should == PBXGroup
        g.referrers.should.include?(@project.main_group)
        g.name.should == 'Frameworks'
      end

      it 'returns the build configuration list' do
        @project.build_configuration_list.build_configurations.map(&:name).sort.should == %w(Debug Release)
      end

      it 'returns the build configurations' do
        @project.build_configurations.map(&:name).sort.should == %w(Debug Release)
      end

      it 'returns the build settings' do
        @project.build_settings('Debug').class.should == Hash
      end

      it 'returns the top-level project configurations and build settings' do
        list = @project.root_object.build_configuration_list
        list.default_configuration_name.should == 'Release'
        list.default_configuration_is_visible.should == '0'
        list.build_settings('Debug')['ONLY_ACTIVE_ARCH'].should == 'YES'
        list.build_settings('Release')['VALIDATE_PRODUCT'].should == 'YES'
      end

      it 'returns a succinct diff representation of the project' do
        before_proj = @project.to_tree_hash
        @project.new_group('Pods')
        after_proj = @project.to_tree_hash
        diff = Xcodeproj::Differ.project_diff(before_proj, after_proj)

        diff.should == {
          'rootObject' => { 'mainGroup' => { 'children' => {
            'project_2' => [
              { 'displayName' => 'Pods', 'isa' => 'PBXGroup', 'sourceTree' => '<group>', 'name' => 'Pods', 'children' => [] },
            ],
          } } } }
      end

      it 'returns a pretty print representation' do
        pretty_print = @project.pretty_print
        pretty_print['Build Configurations'] = []
        pretty_print.should == {
          'File References' => [
            { 'Products' => [] },
            { 'Frameworks' => [] },
          ],
          'Targets' => [],
          'Build Configurations' => [],
        }
      end
    end

    #-------------------------------------------------------------------------#

    describe 'Deterministic UUID generation' do
      it 'does not have duplicate UUIDS' do
        @project.predictabilize_uuids
        @project.uuids.size.should == @project.uuids.uniq.size
      end

      describe 'two projects created with the same steps' do
        create_project = ->(i) do
          project = Xcodeproj::Project.new("path#{i}.xcodeproj")
          project.add_build_configuration('Config', :debug)
          project.predictabilize_uuids
          project
        end

        it 'have the same UUIDS' do
          create_project[0].uuids.sort.should == create_project[1].uuids.sort
        end

        it 'always has the same root object UUID, even for different paths' do
          project = Xcodeproj::Project.new('path1.xcodeproj')
          project.add_build_configuration('Config', :debug)
          project.predictabilize_uuids
          project.root_object.uuid.should == 'D41D8CD98F00B204E9800998ECF8427E'

          project = Xcodeproj::Project.new('path2.xcodeproj')
          project.add_build_configuration('Config', :release)
          project.predictabilize_uuids
          project.root_object.uuid.should == 'D41D8CD98F00B204E9800998ECF8427E'
        end

        Pathname.glob("#{fixture_path}/**/*.xcodeproj").each do |path|
          next if path.to_s.include?('ProjectInMergeConflict/')
          open_project = ->() do
            Xcodeproj::Project.open(path).tap(&:predictabilize_uuids)
          end
          describe path.basename do
            it 'has predictable UUIDs' do
              open_project[].should.eql open_project[]
            end

            it 'does not have duplicate UUIDS' do
              open_project[].uuids.size.should == open_project[].uuids.uniq.size
            end
          end
        end
      end
    end

    #-------------------------------------------------------------------------#

    describe 'Helpers for creating new objects' do
      it 'adds a new group' do
        group = @project.new_group('NewGroup')
        group.isa.should == 'PBXGroup'
        group.name.should == 'NewGroup'
        @project.objects_by_uuid[group.uuid].should.not.be.nil
        @project.main_group.children.should.include group
      end

      it 'adds a new file' do
        file = @project.new_file('Classes/Test.h')
        file.isa.should == 'PBXFileReference'
        file.display_name.should == 'Test.h'
        @project.objects_by_uuid[file.uuid].should.not.be.nil
        @project.main_group.children.should.include file
      end

      it 'creates a new target' do
        target = @project.new_target(:static_library, 'Pods', :ios, '6.0')
        target.name.should == 'Pods'
        target.product_type.should == 'com.apple.product-type.library.static'
      end

      it 'creates a new resources bundle' do
        target = @project.new_resources_bundle('Pods', :ios)
        target.name.should == 'Pods'
        target.product_type.should == 'com.apple.product-type.bundle'
      end

      it 'creates a new aggregate target' do
        native_target = @project.new_target(:static_library, 'BananaLib', :ios, '6.0')
        aggregate_target = @project.new_aggregate_target('Pods', [native_target])
        aggregate_target.name.should == 'Pods'
        aggregate_target.dependencies.first.target.should == native_target
      end

      #----------------------------------------#

      describe '#add_build_configuration' do
        it 'adds a new build configuration' do
          @project.add_build_configuration('App Store', :release)
          @project.build_configurations.map(&:name).sort.should == ['App Store', 'Debug', 'Release']
        end

        it "doesn't duplicate build configurations with existing names" do
          @project.add_build_configuration('App Store', :release)
          @project.add_build_configuration('App Store', :release)
          @project.build_configurations.map(&:name).grep('App Store').size.should == 1
        end

        it 'always returns the build configuration' do
          result = @project.add_build_configuration('App Store', :release)
          result.class.should == XCBuildConfiguration
          result = @project.add_build_configuration('App Store', :release)
          result.class.should == XCBuildConfiguration
        end
      end

      it 'can be sorted' do
        @project.new_group('Test')
        @project['Test'].new_group('B')
        @project['Test'].new_group('A')
        @project.new_target(:static_library, 'B', :ios)
        @project.new_target(:static_library, 'A', :ios)
        @project.add_build_configuration('B', :release)
        @project.add_build_configuration('A', :release)
        @project.sort
        @project.main_group['Test'].children.map(&:name).should == %w(A B)
        @project.targets.map(&:name).should == %w(A B)
        @project.build_configurations.map(&:name).should == %w(A B Debug Release)
      end
    end

    #-------------------------------------------------------------------------#

    describe 'Project schemes' do
      it 'return project name as scheme if there are no shared schemes' do
        schemes = Xcodeproj::Project.schemes(fixture_path('SharedSchemes/Pods/Pods.xcodeproj'))
        schemes[0].should == 'Pods'
      end

      it "return all project's shared schemes" do
        schemes = Xcodeproj::Project.schemes(fixture_path('SharedSchemes/SharedSchemes.xcodeproj'))
        schemes.sort.should == %w(SharedSchemes SharedSchemesForTest)
      end

      describe '#recreate_user_schemes' do
        it 'can recreate the user schemes' do
          sut = Xcodeproj::Project.new(SpecHelper.temporary_directory + 'Pods.xcodeproj')
          sut.new_target(:application, 'Xcode', :ios)
          sut.recreate_user_schemes
          schemes_dir = sut.path + "xcuserdata/#{ENV['USER']}.xcuserdatad/xcschemes"
          schemes_dir.children.map { |f| f.basename.to_s }.sort.should == ['Xcode.xcscheme', 'xcschememanagement.plist']
          manifest = schemes_dir + 'xcschememanagement.plist'
          plist = Plist.read_from_path(manifest.to_s)
          plist['SchemeUserState']['Xcode.xcscheme']['isShown'].should == true
        end

        it 'can hide the recreated user schemes' do
          sut = Xcodeproj::Project.new(SpecHelper.temporary_directory + 'Pods.xcodeproj')
          sut.new_target(:application, 'Xcode', :ios)
          sut.recreate_user_schemes(false)
          manifest = sut.path + "xcuserdata/#{ENV['USER']}.xcuserdatad/xcschemes/xcschememanagement.plist"
          plist = Plist.read_from_path(manifest.to_s)
          plist['SchemeUserState']['Xcode.xcscheme']['isShown'].should == false
        end
      end
    end

    #-------------------------------------------------------------------------#

    describe 'Xcode equivalency' do
      extend SpecHelper::TemporaryDirectory

      def setup_fixture(name)
        Pathname.new(fixture_path("Sample Project/#{name}"))
      end

      def setup_temporary(name)
        dir = File.join(SpecHelper.temporary_directory, name)
        FileUtils.mkdir_p(dir)
        Pathname.new(dir)
      end

      def touch_project(name)
        fixture = setup_fixture(name)
        temporary = setup_temporary(name)

        project = Xcodeproj::Project.open(fixture)
        project.save(temporary)

        (fixture + 'project.pbxproj').read.should == (temporary + 'project.pbxproj').read
      end

      it 'touches the project at the given path' do
        touch_project('Cocoa Application.xcodeproj')
      end

      it 'retains emoji when touching a project' do
        touch_project('Emoji.xcodeproj')
      end
    end

    #-------------------------------------------------------------------------#

    describe 'Extension target relationships' do
      before do
        dir = Pathname(fixture_path('Sample Project'))
        path = dir + 'Extensions/Extensions.xcodeproj'
        @project = Xcodeproj::Project.open(path)
      end

      def target_for_target_name(name)
        @project.native_targets.find do |target|
          target.name == name
        end
      end

      it 'identifies host of watch extension' do
        watch_extension = target_for_target_name('Extensions WatchKit 1 Extension')
        @project.host_targets_for_app_extension_target(watch_extension).map(&:name).should == ['Extensions']
      end

      it 'identifies host of app extension' do
        today_extension = target_for_target_name('Today')
        @project.host_targets_for_app_extension_target(today_extension).map(&:name).should == ['Extensions']
      end

      it 'rejects identifying the host of targets that are not app extensions' do
        watch_app = target_for_target_name('Extensions WatchKit 1 App')
        should.raise ArgumentError do
          @project.host_targets_for_app_extension_target(watch_app)
        end.message.should.equal "#{watch_app} is not an app extension"
      end

      it 'identifies list of app extensions given a host target' do
        main_app_target = target_for_target_name('Extensions')
        app_extension_bundle_ids = @project.app_extensions_for_native_target(main_app_target).map(&:name)
        app_extension_bundle_ids.should == ['Extensions WatchKit 1 Extension',
                                            'Today']
      end

      it 'returns an empty list app extensions given an app extension target' do
        watch_extension = target_for_target_name('Extensions WatchKit 1 Extension')
        app_extension_bundle_ids = @project.app_extensions_for_native_target(watch_extension).map(&:name)
        app_extension_bundle_ids.should == []
      end
    end

    #-------------------------------------------------------------------------#
  end
end
