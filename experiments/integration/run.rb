#!/usr/bin/env ruby
#
# Experiments with compiler integration
#

# stdlib
require 'yaml'
require 'set'
require 'fileutils'

# load libraries
begin
  require 'lib/experiments'
rescue LoadError => e
  $:.unshift File.join(File.dirname(__FILE__),"..")
  require 'lib/experiments'
end
require_configuration 'integration'

# configuration
config = OpenStruct.new
config.srcdir        = $benchsrc
config.builddir      = $builddir
config.workdir       = $workdir
config.benchmarks    = $benchmarks
config.build_log     = File.join(config.builddir, 'build.log')
config.report        = File.join(config.workdir, 'report.yml')
config.do_update     = true
config.nice_pasim    = nil # positive integer

class BenchTool < WcetTool
  def initialize(pml, options)
    super(pml,options)
    @testcnt = 0
  end
  def add_timing_info(name, dict, tool = "aiT")
    origin = [name,tool].compact.join("/")
    entry = pml.timing.by_origin(origin)
    assert("No unique timing entry for origin #{origin}") { entry.length == 1 }
    entry = entry.first
    dict.each { |k,v|
      entry[k] = v
    }
  end
  def run_analysis
    options.flow_fact_selection = "all"
    prepare_pml

    ait_unknown_loops = Set.new
    ait_problem_name("plain")
    wcet_analysis([])
    add_timing_info("plain", "tracefacts" => 0, "flowfacts" => 0)

    File.readlines(options.ait_report_file).each do |line|
      # this is no useful metric for comparison (it does not determine whether WCET can be calculated)
      if line =~ /Loop '(.*?)': unknown loop bound/
        ait_unknown_loops.add($1)
      end
    end
    options.report_append['aiT-unknown-loops'] = ait_unknown_loops.size

    # run trace analysis
    trace_analysis
    add_timing_info("trace", {"tracefacts" => -1, "flowfacts" => 0}, nil)
    tracefacts = pml.flowfacts.filter(pml, "minimal", "trace", "machinecode")
    pml.flowfacts.add_copies(tracefacts,"tf")

    # wcet analysis using all trace facts
    ait_problem_name("tf")
    wcet_analysis(["tf"])
    add_timing_info("tf", "tracefacts" => tracefacts.length, "flowfacts" => tracefacts.length)
    unless pml.timing.by_origin("tf/aiT").first.cycles > 0
      die("Failed to calculate WCET for #{options.input}")
    end

    # find minimal set of trace facts needed to complete aiT analysis
    plain_tf = minimize_trace_facts([], tracefacts, "plain_tf")
    ait_problem_name("plaintf")
    wcet_analysis(["plain_tf"])
    add_timing_info("plaintf", "tracefacts" => plain_tf.length, "flowfacts" => plain_tf.length)

    # wcet analysis using llvm facts
    transform_down(["llvm.bc"],"llvm")
    llvm_ff = pml.flowfacts.by_origin("llvm")
    ait_problem_name("llvm")
    wcet_analysis(["llvm"])
    add_timing_info("llvm", "tracefacts" => 0, "flowfacts" => llvm_ff.length)

    # wcet analysus using minimal trace facts + llvm trace facts
    llvm_tf = minimize_trace_facts(["llvm"], tracefacts, "llvm_tf")
    ait_problem_name("llvmtf")
    wcet_analysis(["llvm","llvm_tf"])
    add_timing_info("llvmtf", "tracefacts" => llvm_tf.length, "flowfacts" => llvm_tf.length + llvm_ff.length)

    report(["tracefacts","flowfacts"])
    pml
  end

  def ait_problem_name(name)
    outdir = options.outdir
    mod = File.basename(options.binary_file, ".elf")
    basename = if name != "" then "#{mod}.#{name}" else mod end
    options.timing_output = name
    options.ais_file = File.join(outdir, "#{basename}.ais")
    options.apx_file = File.join(outdir, "#{basename}.apx")
    options.ait_result_file = File.join(outdir, "#{basename}.ait.xml")
    options.ait_report_file = File.join(outdir, "#{basename}.ait.txt")
  end

  def minimize_trace_facts(srcs, tracefacts, output)
    flowfacts = pml.flowfacts.by_origin(srcs)
    info("minimize trace facts: using #{flowfacts.size} static flow facts and #{tracefacts.size} trace facts")
    keep, queue = [], tracefacts.dup
    print_stats, options.stats = options.stats, false
    while ! queue.empty?
      test = queue.pop
      set = keep + queue
      pml.try do
        name = "#{@testcnt}.min"
        pml.flowfacts.add_copies(flowfacts+keep+queue,name)
        ait_problem_name(name)
        wcet_analysis([name])
        unless pml.timing.by_origin("#{name}/aiT").first.cycles > 0
          keep.push(test)
        end
        @testcnt += 1
      end
    end
    options.stats = print_stats
    pml.flowfacts.add_copies(keep, output)
    keep
  end

  def BenchTool.run(options, console_opts)
    redirect_output(console_opts) do
      pml = BenchTool.new(PMLDoc.from_files(options.input), options).run_in_outdir
      pml.dump_to_file(options.output) if options.output
    end
  end
end

# remove old files unless updating
FileUtils.remove_entry_secure(config.build_log) if File.exist?(config.build_log) && ! config.do_update
FileUtils.mkdir_p(config.builddir)

# options
config.options = default_options(:nice_pasim => config.nice_pasim)
config.options.enable_sweet = false
config.options.enable_wca   = false
config.options.trace_analysis = true
config.options.use_trace_facts = true

# run benchmarks
build_and_run(config, BenchTool)

# summarize
keys = %w{benchmark build  aiT-unknown-loops analysis source analysis-entry cycles tracefacts flowfacts}
print_csv(config.report, :keys => keys, :outfile => File.join(config.workdir,'report.csv'))
print_table(config.report, keys)
