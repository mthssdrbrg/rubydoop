# encoding: utf-8

require 'zlib'

require_relative '../spec_helper'


module JavaJar
  include_package 'java.util.jar'
end

module JavaLang
  include_package 'java.lang'
end

describe 'Packaging and running a project' do
  def isolated_run(dir, cmd)
    Dir.chdir(dir) do
      Bundler.clean_system("rvm $RUBY_VERSION@rubydoop-test_project do #{cmd}")
    end
  end

  let :test_project_dir do
    File.expand_path('../test_project', __FILE__)
  end

  before :all do
    isolated_run(test_project_dir, 'bundle exec rake clean package')
  end

  around do |example|
    Dir.chdir(test_project_dir) do
      example.run
    end
  end

  context 'Packaging the project as a JAR file that' do
    let :jar do
      Java::JavaUtilJar::JarFile.new(Java::JavaIo::File.new(File.expand_path("build/test_project-#{Time.now.strftime('%Y%m%d')}.jar")))
    end

    let :jar_entries do
      jar.entries.to_a.map(&:name)
    end

    it 'includes the project files' do
      jar_entries.should include('test_project.rb')
      jar_entries.should include('word_count.rb')
      jar_entries.should include('uniques.rb')
    end

    it 'includes gem dependencies' do
      jar_entries.grep(%r'^gems/paint-[^/]+/lib').should_not be_empty
    end

    if JRUBY_VERSION =~ /^1\.(?:6|7\.[0-4]$)/
      it 'includes gems that are built into future jruby releases' do
        jar_entries.grep(%r'^gems/json-[^/]+/lib').should_not be_empty
        jar_entries.grep(%r'^gems/jruby-openssl-[^/]+/lib').should_not be_empty
      end
    else
      it 'ignores default gems' do
        jar_entries.grep(%r'^gems/json-[^/]+/lib').should be_empty
        jar_entries.grep(%r'^gems/jruby-openssl-[^/]+/lib').should be_empty
      end
    end

    it 'includes the Rubydoop gem' do
      jar_entries.should include("gems/rubydoop-#{Rubydoop::VERSION}/lib/rubydoop.rb")
      jar_entries.should include("gems/rubydoop-#{Rubydoop::VERSION}/lib/rubydoop/dsl.rb")
    end

    it 'includes a script that sets up a load path that includes all bundled gems' do
      file_io = jar.get_input_stream(jar.get_jar_entry('setup_load_path.rb')).to_io
      script_contents = file_io.read
      script_contents.should include(%($LOAD_PATH << 'gems/rubydoop-#{Rubydoop::VERSION}/lib'))
      script_contents.should match(%r"'gems/paint-[^/]+/lib'")
      if JRUBY_VERSION =~ /^1\.(?:6|7\.[0-4]$)/
        script_contents.should match(%r"'gems/json-[^/]+/lib")
        script_contents.should match(%r"'gems/jruby-openssl-[^/]+/lib")
      end
    end

    it 'includes jruby-complete.jar' do
      jar_entries.should include("lib/jruby-complete-#{JRUBY_VERSION}.jar")
    end

    it 'includes extra JAR dependencies' do
      jar_entries.should include('lib/test_project_ext.jar')
    end

    it 'includes the Rubydoop runner and support classes' do
      jar_entries.should include('rubydoop/RubydoopJobRunner.class')
      jar_entries.should include('rubydoop/MapperProxy.class')
      jar_entries.should include('rubydoop/ReducerProxy.class')
      jar_entries.should include('rubydoop/CombinerProxy.class')
      jar_entries.should include('rubydoop/InstanceContainer.class')
    end

    it 'has the RubydoopJobRunner as its main class' do
      jar.manifest.main_attributes.get(Java::JavaUtilJar::Attributes::Name::MAIN_CLASS).should == 'rubydoop.RubydoopJobRunner'
    end
  end

  context 'Running the project' do
    before :all do
      isolated_run(test_project_dir, "#{HADOOP_HOME}/bin/hadoop jar build/test_project-#{Time.now.strftime('%Y%m%d')}.jar -conf conf/hadoop-local.xml test_project data/input data/output 2>&1 | tee data/log")
    end

    let :log do
      File.read('data/log')
    end

    context 'the word count job' do
      let :words do
        Hash[File.readlines('data/output/word_count/part-r-00000').map { |line| k, v = line.split(/\s/); [k, v.to_i] }]
      end

      it 'runs the mapper and reducer and writes the output in the specified directory' do
        words['anything'].should == 21
      end

      it 'runs the combiner' do
        log.should match(/Combine input records=[^0]/)
        words['alice'].should == 385 * 2
      end

      %w(mapper reducer combiner).each do |type|
        it "runs the #{type} setup method" do
          log.should match(/#{type.upcase}_SETUP_COUNT=1$/)
        end

        it "runs the #{type} cleanup method" do
          log.should match(/#{type.upcase}_CLEANUP_COUNT=1$/)
        end
      end
    end

    context 'the uniques job' do
      let :uniques do
        Hash[File.readlines('data/output/uniques/part-r-00000').map { |line| k, v = line.split(/\s/); [k, v.to_i] }]
      end

      it 'runs the mapper and reducer with secondary sorting through the use of a custom partitioner and grouping comparator' do
        uniques['a'].should == 185
        uniques['e'].should == 128
      end
    end
  end
end
